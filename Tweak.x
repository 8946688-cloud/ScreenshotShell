#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// --------------------------------------------------------
// 私有头文件声明
// --------------------------------------------------------
@interface SSEnvironmentDescription : NSObject
- (void)setImageSurface:(id)surface;
@end

@interface SSSScreenshot : NSObject
@property (retain, nonatomic) UIImage *backingImage;
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@property (readonly, nonatomic) NSData *imageModificationData;
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block;
- (BOOL)hasUnsavedImageEdits;
- (BOOL)hasEverBeenEditedForMode:(long long)mode;
@end

// --------------------------------------------------------
// 路径与配置
// --------------------------------------------------------
static NSString *GetPrefDir(void) {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.screenshotshell.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static NSString *GetPlistPath(void) {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.screenshotshell.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static BOOL isTweakEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    return prefs ? [prefs[@"Enabled"] boolValue] : NO;
}

// --------------------------------------------------------
// 核心：读取并精确合成图像
// --------------------------------------------------------
static UIImage *ApplyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    UIImage *shellImage = [UIImage imageWithContentsOfFile:[GetPrefDir() stringByAppendingPathComponent:@"shell.png"]];
    if (!shellImage) return rawScreenshot;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];
    if (templateW <= 0 || templateH <= 0) return rawScreenshot;

    CGFloat ltx = [cfg[@"left_top_x"] doubleValue];
    CGFloat lty = [cfg[@"left_top_y"] doubleValue];
    CGFloat rtx = [cfg[@"right_top_x"] doubleValue];
    CGFloat lby = [cfg[@"left_bottom_y"] doubleValue];

    CGFloat holeW = rtx - ltx;
    CGFloat holeH = lby - lty;
    if (holeW <= 0 || holeH <= 0) return rawScreenshot;

    CGSize outSize = CGSizeMake(templateW, templateH);

    // 重点：以 1.0 为比例绘图，保证 config 中的像素坐标一一对应
    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    
    // 1. 先把原截图精准拉伸铺到洞里
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];
    
    // 2. 再把壳盖上去
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    // 【极其关键】：把合成好的 CGImage 按原截图的 scale (如 3.0) 重新打包
    // 否则会导致 iOS 截图编辑器坐标系错乱，图片无法正确显示或套准！
    return [UIImage imageWithCGImage:rendered.CGImage
                               scale:rawScreenshot.scale
                         orientation:rawScreenshot.imageOrientation];
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

// 1. 欺骗系统：不管画没画，都强行要求系统走“保存修改后图片”的流程
- (BOOL)hasUnsavedImageEdits {
    if (isTweakEnabled()) return YES;
    return %orig;
}

- (BOOL)hasEverBeenEditedForMode:(long long)mode {
    if (isTweakEnabled()) return YES;
    return %orig;
}

// 2. 最早介入：UI 小窗口获取图片时直接给套好的，顺便把最终模型替换掉
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    __weak typeof(self) weakSelf = self;
    void (^wrappedBlock)(id) = ^(id image) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && [image isKindOfClass:[UIImage class]]) {
            // 防二次套娃标记
            NSNumber *hasShelled = objc_getAssociatedObject(strongSelf, @selector(hasShelled));
            if (![hasShelled boolValue]) {
                UIImage *shelled = ApplyShellToScreenshot((UIImage *)image);
                if (shelled && shelled != image) {
                    [strongSelf setBackingImage:shelled]; // 替换底层原图
                    objc_setAssociatedObject(strongSelf, @selector(hasShelled), @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    origBlock(shelled); // 交给小窗口预览
                    return;
                }
            }
        }
        origBlock(image);
    };

    %orig(transition, wrappedBlock);
}

// 3. 模型获取图片时拦截（防漏洞兜底）
- (UIImage *)backingImage {
    UIImage *orig = %orig;
    if (!orig || !isTweakEnabled()) return orig;

    NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
    if ([hasShelled boolValue]) {
        return orig;
    }

    UIImage *shelled = ApplyShellToScreenshot(orig);
    if (shelled && shelled != orig) {
        [self setBackingImage:shelled];
        objc_setAssociatedObject(self, @selector(hasShelled), @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return shelled;
    }

    return orig;
}

// 4. 关键：系统保存数据时的拦截
- (NSData *)imageModificationData {
    NSData *orig = %orig;
    if (!isTweakEnabled()) return orig;

    // 如果 orig 存在，说明用户真的画了一笔，此时系统已经把画过的界面生成了 PNG
    // 因为在 requestImageInTransition 里用户就是对着套好壳的图画的，所以直接返回 orig 即可
    if (orig) return orig;

    // 如果 orig 为空，说明用户没动笔，但我们强行让 hasUnsavedImageEdits = YES 了
    // 这时系统来要数据，我们必须把套好壳的图片强行转成 PNG 交给它保存
    UIImage *shelledImage = [self backingImage]; 
    if (shelledImage) {
        return UIImagePNGRepresentation(shelledImage);
    }

    return nil;
}

%end

%end // ScreenshotCoreHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"] ||
        [bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(ScreenshotCoreHook);
    }
}
