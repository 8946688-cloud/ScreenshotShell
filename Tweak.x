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
// 生命周期级防重复标记
// --------------------------------------------------------
static const void *kShellAppliedKey = &kShellAppliedKey;
static const void *kShellImageKey = &kShellImageKey;
static const void *kShellBusyKey = &kShellBusyKey;

static BOOL HostShellApplied(id host) {
    if (!host) return NO;
    return [objc_getAssociatedObject(host, kShellAppliedKey) boolValue];
}

static void SetHostShellApplied(id host, BOOL applied) {
    if (!host) return;
    objc_setAssociatedObject(host, kShellAppliedKey, @(applied), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL HostShellBusy(id host) {
    if (!host) return NO;
    return [objc_getAssociatedObject(host, kShellBusyKey) boolValue];
}

static void SetHostShellBusy(id host, BOOL busy) {
    if (!host) return;
    objc_setAssociatedObject(host, kShellBusyKey, @(busy), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIImage *HostShelledImage(id host) {
    if (!host) return nil;
    id obj = objc_getAssociatedObject(host, kShellImageKey);
    return [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
}

static void SetHostShelledImage(id host, UIImage *image) {
    if (!host || !image) return;
    objc_setAssociatedObject(host, kShellImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host, kShellAppliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// --------------------------------------------------------
// 核心：图像合成
// --------------------------------------------------------
static UIImage *applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    // 如果这个 UIImage 自己已经被标记过，直接返回，避免同一对象重复处理
    if ([objc_getAssociatedObject(rawScreenshot, kShellAppliedKey) boolValue]) {
        return rawScreenshot;
    }

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
    if (finalImage) {
        objc_setAssociatedObject(finalImage, kShellAppliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return finalImage;
    }

    return rendered ?: rawScreenshot;
}

static UIImage *ShellImageIfNeeded(UIImage *image) {
    if (!image) return nil;
    return applyShellToScreenshot(image) ?: image;
}

static UIImage *ShellImageForHost(id host, UIImage *image) {
    if (!image) return nil;
    if (!isTweakEnabled()) return image;

    // 已经套过壳：优先复用 host 缓存
    if (HostShellApplied(host)) {
        UIImage *cached = HostShelledImage(host);
        if (cached) return cached;
    }

    // 防重入
    if (HostShellBusy(host)) {
        return image;
    }

    SetHostShellBusy(host, YES);

    UIImage *shelled = ShellImageIfNeeded(image);
    if (shelled) {
        SetHostShelledImage(host, shelled);
    }

    SetHostShellBusy(host, NO);
    return shelled ?: image;
}

static id WrapImageBlockWithHost(id host, id block) {
    if (!block) return nil;

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            origBlock(ShellImageForHost(host, (UIImage *)image) ?: image);
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
    if (!image || !isTweakEnabled()) {
        %orig(image);
        return;
    }

    // 先看这张截图是否已经有最终壳图缓存
    UIImage *cached = HostShelledImage(self);
    if (cached) {
        %orig(cached);
        return;
    }

    UIImage *shelled = ShellImageForHost(self, image);
    %orig(shelled ?: image);
}

- (void)requestImageInTransition:(_Bool)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    id wrapped = WrapImageBlockWithHost(self, block);
    %orig(transition, wrapped);
}

%end

%hook SSSScreenshotImageProvider

- (id)requestCGImageBackedUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    return ShellImageForHost(shot ?: self, (UIImage *)image) ?: image;
}

- (id)requestUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    return ShellImageForHost(shot ?: self, (UIImage *)image) ?: image;
}

- (void)requestCGImageBackedUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    id wrapped = WrapImageBlockWithHost(shot ?: self, ui);
    %orig(wrapped);
}

- (void)requestUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    id wrapped = WrapImageBlockWithHost(shot ?: self, ui);
    %orig(wrapped);
}

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    return ShellImageForHost(shot ?: self, (UIImage *)image) ?: image;
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    return ShellImageForHost(shot ?: self, (UIImage *)image) ?: image;
}

- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    id wrapped = WrapImageBlockWithHost(shot ?: self, block);
    %orig(wrapped);
}

- (void)requestOutputImageForSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    id wrapped = WrapImageBlockWithHost(shot ?: self, block);
    %orig(wrapped);
}

- (void)requestOutputImageInTransition:(_Bool)transition forSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    SSSScreenshot *shot = nil;
    @try { shot = [self screenshot]; } @catch (__unused NSException *e) {}
    id wrapped = WrapImageBlockWithHost(shot ?: self, block);
    %orig(transition, wrapped);
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
