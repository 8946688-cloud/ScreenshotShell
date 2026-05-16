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
static const void *kShellAppliedKey = &kShellAppliedKey;
static const void *kShellBusyKey = &kShellBusyKey;
static const void *kShellImageKey = &kShellImageKey;

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
// 逻辑：在壳图外框的几个固定点，检查当前图与 shell.png 是否几乎一致
// 这样比“对象标记”稳得多，因为编辑/保存后 UIImage 往往会变成新实例
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

    // 尺寸差太大，肯定不是同一代图
    if (fabs(imagePx.width - templateW) > 4.0 || fabs(imagePx.height - templateH) > 4.0) {
        return NO;
    }
    if (fabs(shellPx.width - templateW) > 4.0 || fabs(shellPx.height - templateH) > 4.0) {
        return NO;
    }

    // 取 4 个角和上边/下边几个点，只要这些点和 shell 一致，大概率已经套过壳
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

    // 内容级防重入：如果它已经像壳图了，就直接返回
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

    // 先铺原图，再盖壳图
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

static UIImage *ShellImageIfNeeded(UIImage *image) {
    if (!image) return nil;
    return applyShellToScreenshot(image) ?: image;
}

static id WrapImageBlock(id block) {
    if (!block) return nil;
    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            origBlock(ShellImageIfNeeded((UIImage *)image));
        } else {
            origBlock(image);
        }
    };
    return [wrappedBlock copy];
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

- (void)setBackingImage:(UIImage *)image {
    if (!isTweakEnabled() || !image) {
        %orig(image);
        return;
    }
    UIImage *shelledImage = ShellImageIfNeeded(image);
    %orig(shelledImage);
}

- (void)requestImageInTransition:(_Bool)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    id wrapped = WrapImageBlock(block);
    %orig(transition, wrapped);
}

%end

%hook SSSScreenshotImageProvider

- (id)requestCGImageBackedUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShellImageIfNeeded((UIImage *)image);
}

- (id)requestUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShellImageIfNeeded((UIImage *)image);
}

- (void)requestCGImageBackedUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }
    %orig(WrapImageBlock(ui));
}

- (void)requestUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }
    %orig(WrapImageBlock(ui));
}

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShellImageIfNeeded((UIImage *)image);
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShellImageIfNeeded((UIImage *)image);
}

- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    %orig(WrapImageBlock(block));
}

- (void)requestOutputImageForSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    %orig(WrapImageBlock(block));
}

- (void)requestOutputImageInTransition:(_Bool)transition forSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }
    %orig(transition, WrapImageBlock(block));
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
