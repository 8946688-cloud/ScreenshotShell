#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
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
// 截图生命周期标记：只允许整条链路套壳一次
// --------------------------------------------------------
static const void *kShellAppliedKey = &kShellAppliedKey;
static const void *kShellBusyKey = &kShellBusyKey;

static BOOL ScreenshotShellApplied(id screenshot) {
    if (!screenshot) return NO;
    return [objc_getAssociatedObject(screenshot, kShellAppliedKey) boolValue];
}

static void SetScreenshotShellApplied(id screenshot, BOOL applied) {
    if (!screenshot) return;
    objc_setAssociatedObject(screenshot, kShellAppliedKey, @(applied), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ScreenshotShellBusy(id screenshot) {
    if (!screenshot) return NO;
    return [objc_getAssociatedObject(screenshot, kShellBusyKey) boolValue];
}

static void SetScreenshotShellBusy(id screenshot, BOOL busy) {
    if (!screenshot) return;
    objc_setAssociatedObject(screenshot, kShellBusyKey, @(busy), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// --------------------------------------------------------
// 核心：合成图片
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

// --------------------------------------------------------
// 缓存与复用
// --------------------------------------------------------
static UIImage *GetProviderCachedShelledImage(id provider) {
    if (!provider) return nil;

    UIImage *cached = nil;
    @try {
        if ([provider respondsToSelector:@selector(cachedOutputImage)]) {
            cached = [provider cachedOutputImage];
            if (cached) return cached;
        }
        if ([provider respondsToSelector:@selector(cachedCGImageBackedUneditedImageForUI)]) {
            cached = [provider cachedCGImageBackedUneditedImageForUI];
            if (cached) return cached;
        }
    } @catch (__unused NSException *e) {
    }
    return nil;
}

static void SetProviderShelledCache(id provider, UIImage *image) {
    if (!provider || !image) return;

    @try {
        if ([provider respondsToSelector:@selector(setCachedCGImageBackedUneditedImageForUI:)]) {
            [provider setCachedCGImageBackedUneditedImageForUI:image];
        }
        if ([provider respondsToSelector:@selector(setCachedOutputImage:)]) {
            [provider setCachedOutputImage:image];
        }
        if ([provider respondsToSelector:@selector(setHasOriginalUneditedImage:)]) {
            [provider setHasOriginalUneditedImage:YES];
        }
        if ([provider respondsToSelector:@selector(setHasChangedBackingImage:)]) {
            [provider setHasChangedBackingImage:NO];
        }
    } @catch (__unused NSException *e) {
    }
}

static UIImage *ShelledImageForScreenshot(id screenshot, id provider, UIImage *image) {
    if (!image) return nil;
    if (!isTweakEnabled()) return image;

    // 已经在这张截图生命周期里套过壳，直接复用缓存，不再重画
    if (ScreenshotShellApplied(screenshot)) {
        UIImage *cached = GetProviderCachedShelledImage(provider);
        if (cached) return cached;

        @try {
            if (screenshot && [screenshot respondsToSelector:@selector(backingImage)]) {
                UIImage *backing = [screenshot backingImage];
                if (backing) return backing;
            }
        } @catch (__unused NSException *e) {
        }

        return image;
    }

    // 防止同一个调用链里重入
    if (ScreenshotShellBusy(screenshot)) {
        return image;
    }

    SetScreenshotShellBusy(screenshot, YES);

    UIImage *shelled = applyShellToScreenshot(image);
    if (shelled) {
        SetScreenshotShellApplied(screenshot, YES);
        if (provider) {
            SetProviderShelledCache(provider, shelled);
        }

        // 关键：把最终结果写回截图对象本身，后续 UI / 保存都复用它
        @try {
            if (screenshot && [screenshot respondsToSelector:@selector(setBackingImage:)]) {
                [screenshot setBackingImage:shelled];
            }
        } @catch (__unused NSException *e) {
        }
    }

    SetScreenshotShellBusy(screenshot, NO);
    return shelled ?: image;
}

static UIImage *ShelledImageFromProvider(id provider, UIImage *image) {
    id screenshot = nil;
    @try {
        if ([provider respondsToSelector:@selector(screenshot)]) {
            screenshot = [provider screenshot];
        }
    } @catch (__unused NSException *e) {
    }
    return ShelledImageForScreenshot(screenshot, provider, image);
}

static UIImage *ShelledImageFromScreenshot(id screenshot, UIImage *image) {
    id provider = nil;
    @try {
        if ([screenshot respondsToSelector:@selector(imageProvider)]) {
            provider = [screenshot imageProvider];
        }
    } @catch (__unused NSException *e) {
    }
    return ShelledImageForScreenshot(screenshot, provider, image);
}

static id WrapImageBlockForProvider(id provider, id block) {
    if (!block) return nil;

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShelledImageFromProvider(provider, [image isKindOfClass:[UIImage class]] ? (UIImage *)image : nil) ?: image);
    };
    return [wrappedBlock copy];
}

static id WrapImageBlockForScreenshot(id screenshot, id block) {
    if (!block) return nil;

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShelledImageFromScreenshot(screenshot, [image isKindOfClass:[UIImage class]] ? (UIImage *)image : nil) ?: image);
    };
    return [wrappedBlock copy];
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

// --------------------------------------------------------
// 1) 模型层：这是最关键的写回点
// --------------------------------------------------------
%hook SSSScreenshot

- (void)setBackingImage:(UIImage *)image {
    if (!image || !isTweakEnabled()) {
        %orig(image);
        return;
    }

    // 如果这张截图生命周期里已经套过壳，后面再来的 backingImage 直接复用已处理结果
    if (ScreenshotShellApplied(self)) {
        UIImage *cached = [self backingImage];
        %orig(cached ?: image);
        return;
    }

    UIImage *shelled = ShelledImageFromScreenshot(self, image);
    %orig(shelled ?: image);
}

- (void)requestImageInTransition:(_Bool)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    id wrappedBlock = WrapImageBlockForScreenshot(self, block);
    %orig(transition, wrappedBlock);
}

%end

// --------------------------------------------------------
// 2) 首屏展示 / 编辑流 / 保存流
//    这里保留，但只允许“首次命中时合成一次”
// --------------------------------------------------------
%hook SSSScreenshotImageProvider

- (id)requestCGImageBackedUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShelledImageFromProvider(self, (UIImage *)image) ?: image;
}

- (id)requestUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShelledImageFromProvider(self, (UIImage *)image) ?: image;
}

- (void)requestCGImageBackedUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }
    id wrapped = WrapImageBlockForProvider(self, ui);
    %orig(wrapped);
}

- (void)requestUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }
    id wrapped = WrapImageBlockForProvider(self, ui);
    %orig(wrapped);
}

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShelledImageFromProvider(self, (UIImage *)image) ?: image;
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if (![image isKindOfClass:[UIImage class]]) return image;
    return ShelledImageFromProvider(self, (UIImage *)image) ?: image;
}

- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    id wrapped = WrapImageBlockForProvider(self, block);
    %orig(wrapped);
}

- (void)requestOutputImageForSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    id wrapped = WrapImageBlockForProvider(self, block);
    %orig(wrapped);
}

- (void)requestOutputImageInTransition:(_Bool)transition forSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }
    id wrapped = WrapImageBlockForProvider(self, block);
    %orig(transition, wrapped);
}

%end

// --------------------------------------------------------
// 3) 这里不要再套壳了
//    PHAsset 层已经太晚，极容易把已处理图片再处理一次
//    只保留原样透传，避免壳中壳
// --------------------------------------------------------
%hook PHAssetCreationRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    return %orig(image);
}

+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    return %orig(fileURL);
}

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    %orig(type, data, options);
}

- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    %orig(type, fileURL, options);
}

%end

%hook PHAssetChangeRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    return %orig(image);
}

+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    return %orig(fileURL);
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
