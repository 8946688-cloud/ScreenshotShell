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
// 我们需要用到的底层状态方法
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
// 读取素材
// --------------------------------------------------------
static UIImage *LoadShellImage(void) {
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    return [UIImage imageWithContentsOfFile:shellPath];
}

static NSDictionary *LoadConfig(void) {
    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    return (NSDictionary *)json;
}

// --------------------------------------------------------
// 核心绘图逻辑 (纯函数，不再包含标记逻辑)
// --------------------------------------------------------
static UIImage *ApplyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    UIImage *shellImage = LoadShellImage();
    if (!shellImage) return rawScreenshot;

    NSDictionary *cfg = LoadConfig();
    if (!cfg) return rawScreenshot;

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

    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, outSize.width, outSize.height));
    }

    // 1. 铺截图
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];
    // 2. 盖外壳
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    return [UIImage imageWithCGImage:rendered.CGImage scale:1.0 orientation:UIImageOrientationUp];
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

// 【修复 Bug 1】：强制告诉系统“这张图我改过”，逼它走后续的渲染保存流程
- (BOOL)hasUnsavedImageEdits {
    if (isTweakEnabled()) {
        return YES;
    }
    return %orig;
}

- (BOOL)hasEverBeenEditedForMode:(long long)mode {
    if (isTweakEnabled()) {
        return YES;
    }
    return %orig;
}

// 【修复 Bug 2】：在模型实例 (self) 上打标记，防套娃
- (UIImage *)backingImage {
    UIImage *orig = %orig;
    if (!orig || !isTweakEnabled()) return orig;

    // 检查这个截图任务是否已经套过壳
    NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
    if ([hasShelled boolValue]) {
        return orig; 
    }

    // 执行套壳
    UIImage *shelled = ApplyShellToScreenshot(orig);
    if (shelled && shelled != orig) {
        // 关键：将套好壳的图片塞回模型，并打上永久标记
        [self setBackingImage:shelled];
        objc_setAssociatedObject(self, @selector(hasShelled), @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return shelled;
    }

    return orig;
}

// 拦截 UI 预览时获取的图片，同步打上标记
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
    if ([hasShelled boolValue]) {
        %orig(transition, block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    // 使用 weakSelf 防止 Block 循环引用
    __weak typeof(self) weakSelf = self;
    void (^wrappedBlock)(id) = ^(id image) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && [image isKindOfClass:[UIImage class]]) {
            UIImage *shelled = ApplyShellToScreenshot((UIImage *)image);
            if (shelled && shelled != image) {
                [strongSelf setBackingImage:shelled];
                objc_setAssociatedObject(strongSelf, @selector(hasShelled), @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                origBlock(shelled);
            } else {
                origBlock(image);
            }
        } else {
            origBlock(image);
        }
    };

    %orig(transition, wrappedBlock);
}

// 注意：彻底删除了 imageModificationData 的 Hook。
// 因为 backingImage 已经是套好壳的图片，原生系统会自己把它转成 NSData 并保存，多拦截一次必定会导致画中画！

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
