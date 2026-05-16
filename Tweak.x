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
// 防重复套壳标记
// --------------------------------------------------------
static const void *kShellAppliedKey = &kShellAppliedKey;

static BOOL ImageAlreadyShelled(UIImage *image) {
    if (!image) return NO;
    NSNumber *flag = objc_getAssociatedObject(image, kShellAppliedKey);
    return [flag boolValue];
}

static UIImage *MarkImageShelled(UIImage *image) {
    if (image) {
        objc_setAssociatedObject(image, kShellAppliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return image;
}

// --------------------------------------------------------
// 核心：精准合成图像（绝对保持配置文件的壳图尺寸）
// --------------------------------------------------------
static UIImage *applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    if (ImageAlreadyShelled(rawScreenshot)) return rawScreenshot; // 拦截重复套壳

    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

    // 【关键修复】：完全依据配置表的宽高创建画布，不让系统比例缩放影响壳图
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

    // scale 固定写 1.0，保证合成的像素点 1:1，绝对不变形
    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, outSize.width, outSize.height));
    }

    // 1. 原图填洞
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];

    // 2. 盖上外壳
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    // 强制按 1.0 比例导出，防止 UI 渲染拉伸
    UIImage *finalImage = [UIImage imageWithCGImage:rendered.CGImage
                                              scale:1.0
                                        orientation:UIImageOrientationUp];
    return MarkImageShelled(finalImage);
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

// 1. 【修复：不画一笔直接存】：强制告诉系统存在编辑
- (BOOL)hasUnsavedImageEdits {
    if (isTweakEnabled()) return YES;
    return %orig;
}
- (BOOL)hasEverBeenEditedForMode:(long long)mode {
    if (isTweakEnabled()) return YES;
    return %orig;
}

// 2. 【修复：小窗口显示壳图】：将系统内存里的原图偷换为带壳图
- (UIImage *)backingImage {
    UIImage *orig = %orig;
    if (!orig || !isTweakEnabled()) return orig;
    
    UIImage *shelled = applyShellToScreenshot(orig);
    return shelled ?: orig;
}

- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = applyShellToScreenshot(image);
        if (shelled) {
            %orig(shelled);
            return;
        }
    }
    %orig(image);
}

// 3. 【拦截 UI 过渡动画】，保证小窗口缩略图弹出瞬间就是带壳的
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            UIImage *shelled = applyShellToScreenshot((UIImage *)image);
            origBlock(shelled ?: image);
        } else {
            origBlock(image);
        }
    };

    %orig(transition, wrappedBlock);
}

// 4. 【核心灵魂逻辑：最终保存】
- (NSData *)imageModificationData {
    NSData *orig = %orig;
    if (!isTweakEnabled()) return orig;

    // 场景 A：用户点进去画画了。
    // 因为 UI 界面已经是套壳图了，所以用户画画后，系统给的 orig 本身就包含了“壳图 + 画的线条”。
    // 此时我们绝对不再套一次壳，直接返回 orig，彻底杜绝“套娃”！
    if (orig) {
        return orig;
    }

    // 场景 B：用户没画画直接滑走/点存图。
    // 因为前面我们强行把 hasUnsavedImageEdits 设为 YES，所以系统会来要数据。
    // 我们手动获取已经套好壳的图，转成 PNG 数据丢给系统相册保存。
    UIImage *shelledImage = [self backingImage];
    if (shelledImage) {
        return UIImagePNGRepresentation(shelledImage);
    }

    return orig;
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
