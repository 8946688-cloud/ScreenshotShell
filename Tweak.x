#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ========================================================
// Minimal private class declarations
// ========================================================

@class SSSScreenshotImageProvider;

@interface SSSScreenshot : NSObject
- (void)setBackingImage:(UIImage *)image;
- (UIImage *)backingImage;
- (SSSScreenshotImageProvider *)imageProvider;
- (void)requestImageInTransition:(_Bool)transition withBlock:(id /* block */)block;
@end

@interface SSSScreenshotImageProvider : NSObject
- (SSSScreenshot *)screenshot;
- (void)setScreenshot:(SSSScreenshot *)screenshot;

- (id)requestCGImageBackedUneditedImageForUIBlocking;
- (id)requestUneditedImageForUIBlocking;
- (void)requestCGImageBackedUneditedImageForUI:(id /* block */)ui;
- (void)requestUneditedImageForUI:(id /* block */)ui;

- (id)requestOutputImageForUIBlocking;
- (id)requestOutputImageForSavingBlocking;
- (void)requestOutputImageForUI:(id /* block */)block;
- (void)requestOutputImageForSaving:(id /* block */)block;
- (void)requestOutputImageInTransition:(_Bool)transition forSaving:(id /* block */)block;
@end

@interface SSSScreenshotView : UIView
- (id)screenshot;
- (void)setScreenshot:(id)screenshot;
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
// 关联对象 key
// --------------------------------------------------------
static const void *kShellImageKey = &kShellImageKey;
static const void *kShellBusyKey = &kShellBusyKey;

// --------------------------------------------------------
// 像素采样工具
// --------------------------------------------------------
static BOOL SamplePixelRGBA(UIImage *image, CGPoint point, uint8_t outRGBA[4]) {
    if (!image || !outRGBA) return NO;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return NO;

    CGFloat scale = image.scale > 0 ? image.scale : 1.0;
    NSInteger x = (NSInteger)lrint(point.x * scale);
    NSInteger y = (NSInteger)lrint(point.y * scale);

    if (x < 0 || y < 0 || (size_t)x >= width || (size_t)y >= height) return NO;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NO;

    uint8_t pixel[4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(pixel,
                                             1,
                                             1,
                                             8,
                                             4,
                                             cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;

    CGContextTranslateCTM(ctx, -(CGFloat)x, -(CGFloat)y);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(ctx);

    outRGBA[0] = pixel[0];
    outRGBA[1] = pixel[1];
    outRGBA[2] = pixel[2];
    outRGBA[3] = pixel[3];
    return YES;
}

static BOOL RGBAAlmostEqual(const uint8_t a[4], const uint8_t b[4], int tolerance) {
    for (int i = 0; i < 4; i++) {
        if (abs((int)a[i] - (int)b[i]) > tolerance) {
            return NO;
        }
    }
    return YES;
}

// --------------------------------------------------------
// 判断图片是否已经是“壳图”
// --------------------------------------------------------
static BOOL ImageAlreadyContainsShell(UIImage *image, UIImage *shellImage, NSDictionary *cfg) {
    if (!image || !shellImage || !cfg) return NO;

    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];
    if (templateW <= 0 || templateH <= 0) return NO;

    CGFloat ltx = [cfg[@"left_top_x"] doubleValue];
    CGFloat lty = [cfg[@"left_top_y"] doubleValue];
    CGFloat rtx = [cfg[@"right_top_x"] doubleValue];
    CGFloat lby = [cfg[@"left_bottom_y"] doubleValue];

    if (rtx <= ltx || lby <= lty) return NO;

    CGSize imagePx = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    CGSize shellPx = CGSizeMake(shellImage.size.width * shellImage.scale, shellImage.size.height * shellImage.scale);

    if (fabs(imagePx.width - templateW) > 4.0 || fabs(imagePx.height - templateH) > 4.0) {
        return NO;
    }
    if (fabs(shellPx.width - templateW) > 4.0 || fabs(shellPx.height - templateH) > 4.0) {
        return NO;
    }

    CGPoint pts[] = {
        CGPointMake(3, 3),
        CGPointMake(templateW - 4, 3),
        CGPointMake(3, templateH - 4),
        CGPointMake(templateW - 4, templateH - 4),
        CGPointMake(templateW * 0.5, 3),
        CGPointMake(templateW * 0.5, templateH - 4),
    };

    for (int i = 0; i < (int)(sizeof(pts) / sizeof(pts[0])); i++) {
        uint8_t imgRGBA[4] = {0};
        uint8_t shellRGBA[4] = {0};

        if (!SamplePixelRGBA(image, pts[i], imgRGBA)) return NO;
        if (!SamplePixelRGBA(shellImage, pts[i], shellRGBA)) return NO;

        if (!RGBAAlmostEqual(imgRGBA, shellRGBA, 8)) {
            return NO;
        }
    }

    return YES;
}

// --------------------------------------------------------
// 核心：合成图像
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

    if (ImageAlreadyContainsShell(rawScreenshot, shellImage, cfg)) {
        return rawScreenshot;
    }

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

    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    UIImage *finalImage = [UIImage imageWithCGImage:rendered.CGImage
                                              scale:1.0
                                        orientation:UIImageOrientationUp];
    return finalImage ?: rendered ?: rawScreenshot;
}

static UIImage *ShellImageForScreenshot(SSSScreenshot *screenshot, UIImage *image) {
    if (!image) return nil;
    if (!isTweakEnabled()) return image;

    if (screenshot) {
        UIImage *cached = objc_getAssociatedObject(screenshot, kShellImageKey);
        if ([cached isKindOfClass:[UIImage class]]) {
            return cached;
        }
    }

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return image;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return image;

    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return image;

    if (ImageAlreadyContainsShell(image, shellImage, cfg)) {
        if (screenshot) {
            objc_setAssociatedObject(screenshot, kShellImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return image;
    }

    UIImage *rendered = applyShellToScreenshot(image);
    if (!rendered) return image;

    if (screenshot) {
        objc_setAssociatedObject(screenshot, kShellImageKey, rendered, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return rendered;
}

static id WrapImageBlockForScreenshot(SSSScreenshot *screenshot, id block) {
    if (!block) return nil;

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            origBlock(ShellImageForScreenshot(screenshot, (UIImage *)image));
        } else {
            origBlock(image);
        }
    };
    return [wrappedBlock copy];
}

static void EnsureScreenshotCachedShell(id screenshotObj) {
    if (!screenshotObj || !isTweakEnabled()) return;
    if (![screenshotObj respondsToSelector:@selector(backingImage)] ||
        ![screenshotObj respondsToSelector:@selector(setBackingImage:)]) {
        return;
    }

    NSNumber *busy = objc_getAssociatedObject(screenshotObj, kShellBusyKey);
    if (busy.boolValue) return;

    objc_setAssociatedObject(screenshotObj, kShellBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *image = [screenshotObj backingImage];
    if ([image isKindOfClass:[UIImage class]]) {
        UIImage *shell = ShellImageForScreenshot(screenshotObj, image);
        if (shell && shell != image) {
            [screenshotObj setBackingImage:shell];
        }
    }

    objc_setAssociatedObject(screenshotObj, kShellBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

- (void)setBackingImage:(UIImage *)image {
    objc_setAssociatedObject(self, kShellImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!isTweakEnabled() || ![image isKindOfClass:[UIImage class]]) {
        %orig(image);
        return;
    }

    UIImage *shell = ShellImageForScreenshot(self, image);
    %orig(shell ?: image);
}

- (UIImage *)backingImage {
    UIImage *image = %orig;
    if (!isTweakEnabled() || ![image isKindOfClass:[UIImage class]]) {
        return image;
    }

    UIImage *cached = objc_getAssociatedObject(self, kShellImageKey);
    if ([cached isKindOfClass:[UIImage class]]) {
        return cached;
    }

    return ShellImageForScreenshot(self, image);
}

- (void)requestImageInTransition:(_Bool)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    id wrapped = WrapImageBlockForScreenshot(self, block);
    %orig(transition, wrapped);
}

%end

%hook SSSScreenshotView

- (void)setScreenshot:(id)screenshot {
    if (isTweakEnabled()) {
        EnsureScreenshotCachedShell(screenshot);
    }
    %orig(screenshot);
}

%end

%hook SSSScreenshotImageProvider

- (id)requestCGImageBackedUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = [self screenshot];
    return ShellImageForScreenshot(shot, (UIImage *)image);
}

- (id)requestUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = [self screenshot];
    return ShellImageForScreenshot(shot, (UIImage *)image);
}

- (void)requestCGImageBackedUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }
    SSSScreenshot *shot = [self screenshot];
    %orig(WrapImageBlockForScreenshot(shot, ui));
}

- (void)requestUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }
    SSSScreenshot *shot = [self screenshot];
    %orig(WrapImageBlockForScreenshot(shot, ui));
}

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = [self screenshot];
    return ShellImageForScreenshot(shot, (UIImage *)image);
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = [self screenshot];
    return ShellImageForScreenshot(shot, (UIImage *)image);
}

- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    SSSScreenshot *shot = [self screenshot];
    %orig(WrapImageBlockForScreenshot(shot, block));
}

- (void)requestOutputImageForSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    SSSScreenshot *shot = [self screenshot];
    %orig(WrapImageBlockForScreenshot(shot, block));
}

- (void)requestOutputImageInTransition:(_Bool)transition forSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }
    SSSScreenshot *shot = [self screenshot];
    %orig(transition, WrapImageBlockForScreenshot(shot, block));
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
