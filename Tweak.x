#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

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
// 核心：精准合成图像（完美修复 Scale 错乱问题）
// --------------------------------------------------------
static UIImage *applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];
    if (templateW <= 0 || templateH <= 0) return rawScreenshot;

    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot;

    CGFloat ltx = [cfg[@"left_top_x"] doubleValue];
    CGFloat lty = [cfg[@"left_top_y"] doubleValue];
    CGFloat rtx = [cfg[@"right_top_x"] doubleValue];
    CGFloat lby = [cfg[@"left_bottom_y"] doubleValue];

    CGFloat holeW = rtx - ltx;
    CGFloat holeH = lby - lty;
    if (holeW <= 0 || holeH <= 0) return rawScreenshot;

    CGSize outSize = CGSizeMake(templateW, templateH);

    // 必须用 1.0 比例绘制，保证严格贴合物理像素 config 坐标
    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, outSize.width, outSize.height));
    }

    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    // 【极其关键】必须按原截图的 scale (例如 3.0) 重新包装 CGImage！
    // 这样 UI 界面才不会把图片放大三倍导致错位！
    return [UIImage imageWithCGImage:rendered.CGImage
                               scale:rawScreenshot.scale
                         orientation:rawScreenshot.imageOrientation];
}

// --------------------------------------------------------
// Hook 注入 (最纯粹的模型层拦截)
// --------------------------------------------------------
@interface SSSScreenshot : NSObject
- (UIImage *)backingImage;
- (void)setBackingImage:(UIImage *)img;
@end

%group ScreenshotCoreHook

%hook SSSScreenshot

// 1. 核心图片获取：套壳、存入模型、打下防套娃标记
- (UIImage *)backingImage {
    UIImage *orig = %orig;
    if (!orig || !isTweakEnabled()) return orig;

    // 检查这个截图任务 (模型实例本身) 是否已经套过壳
    NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
    if ([hasShelled boolValue]) {
        return orig; // 绝不套娃！
    }

    UIImage *shelled = applyShellToScreenshot(orig);
    if (shelled && shelled != orig) {
        // 将套好壳的图片写回系统底层
        [self setBackingImage:shelled];
        // 给当前截图任务打上“已处理”标记
        objc_setAssociatedObject(self, @selector(hasShelled), @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return shelled;
    }

    return orig;
}

// 2. 保证小窗口飞出来的一瞬间，就是套好壳的
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block {
    if (isTweakEnabled()) {
        // 提前主动调用一次，触发上面的套壳逻辑
        [self backingImage]; 
    }
    %orig(transition, block);
}

// 3. 欺骗系统，强制让它走“保存已修改图片”的通道
- (BOOL)hasUnsavedImageEdits {
    if (isTweakEnabled()) return YES;
    return %orig;
}

- (BOOL)hasEverBeenEditedForMode:(long long)mode {
    if (isTweakEnabled()) return YES;
    return %orig;
}

// 4. 接管最终的图像保存数据 (彻底解决不画一笔存不了的问题)
- (NSData *)imageModificationData {
    NSData *orig = %orig;
    if (!isTweakEnabled()) return orig;

    // 场景 A：用户点进去画画了。
    // UI 画布已经是套好壳的，用户在上面画的笔画会被系统完美融合在 orig 里。
    // 直接返回 orig，绝对不套第二次！
    if (orig) {
        return orig;
    }

    // 场景 B：用户没画画直接点保存，或者等小窗口滑走。
    // 因为我们骗了系统 (hasUnsavedImageEdits = YES)，系统来索要修改后的数据。
    // 我们手动把套好壳的 backingImage 转成 PNG 丢给系统，相册直接保存！
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
