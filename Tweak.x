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
// 防重复套壳标记
// --------------------------------------------------------
static const void *kShellAppliedKey = &kShellAppliedKey;

static BOOL IsShelledImage(id obj) {
    if (!obj) return NO;
    return [objc_getAssociatedObject(obj, kShellAppliedKey) boolValue];
}

static void MarkShelledImage(id obj) {
    if (!obj) return;
    objc_setAssociatedObject(obj, kShellAppliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// --------------------------------------------------------
// 工具：图像处理 / 临时文件
// --------------------------------------------------------
static UIImage *applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    // 已经是我们处理过的图，直接返回，避免同一条链路里重复套壳
    if (IsShelledImage(rawScreenshot)) {
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
        MarkShelledImage(finalImage);
        return finalImage;
    }

    return rendered ?: rawScreenshot;
}

static UIImage *ShellImageIfNeeded(UIImage *image) {
    if (!image) return nil;
    UIImage *result = applyShellToScreenshot(image);
    return result ?: image;
}

static NSURL *WritePNGToTemporaryURLFromImage(UIImage *image) {
    if (!image) return nil;

    UIImage *finalImage = ShellImageIfNeeded(image);
    NSData *png = UIImagePNGRepresentation(finalImage);
    if (!png) return nil;

    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    tempPath = [tempPath stringByAppendingPathExtension:@"png"];
    if (![png writeToFile:tempPath atomically:YES]) return nil;

    return [NSURL fileURLWithPath:tempPath];
}

static id ShellObjectIfNeeded(id obj) {
    if (![obj isKindOfClass:[UIImage class]]) return obj;
    return ShellImageIfNeeded((UIImage *)obj) ?: obj;
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

// 模型层拦截：截图对象刚拿到 backingImage 时就先处理
%hook SSSScreenshot

- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = ShellImageIfNeeded(image);
        %orig(shelled ?: image);
        return;
    }
    %orig(image);
}

// 过渡图入口，某些版本首次预览会走这里
- (void)requestImageInTransition:(_Bool)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShellObjectIfNeeded(image));
    };

    %orig(transition, wrappedBlock);
}

%end

// 界面 UI / 首次展示 / 编辑流拦截
%hook SSSScreenshotImageProvider

- (id)requestCGImageBackedUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    return ShellObjectIfNeeded(image);
}

- (id)requestUneditedImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    return ShellObjectIfNeeded(image);
}

- (void)requestCGImageBackedUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }

    void (^origBlock)(id) = [ui copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShellObjectIfNeeded(image));
    };

    %orig(wrappedBlock);
}

- (void)requestUneditedImageForUI:(id)ui {
    if (!ui || !isTweakEnabled()) {
        %orig(ui);
        return;
    }

    void (^origBlock)(id) = [ui copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShellObjectIfNeeded(image));
    };

    %orig(wrappedBlock);
}

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    return ShellObjectIfNeeded(image);
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    return ShellObjectIfNeeded(image);
}

- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShellObjectIfNeeded(image));
    };

    %orig(wrappedBlock);
}

- (void)requestOutputImageForSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShellObjectIfNeeded(image));
    };

    %orig(wrappedBlock);
}

// 过渡输出，编辑/保存时兜底
- (void)requestOutputImageInTransition:(_Bool)transition forSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        origBlock(ShellObjectIfNeeded(image));
    };

    %orig(transition, wrappedBlock);
}

%end

// 相册保存最底层拦截
%hook PHAssetCreationRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = ShellImageIfNeeded(image);
        if (shelled) {
            return %orig(shelled);
        }
    }
    return %orig(image);
}

+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    if (fileURL && isTweakEnabled()) {
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data) {
            UIImage *rawImage = [UIImage imageWithData:data];
            if (rawImage) {
                NSURL *tempURL = WritePNGToTemporaryURLFromImage(rawImage);
                if (tempURL) {
                    return %orig(tempURL);
                }
            }
        }
    }
    return %orig(fileURL);
}

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    if (type == 1 && data && isTweakEnabled()) {
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = ShellImageIfNeeded(rawImage);
            if (shelled) {
                NSData *png = UIImagePNGRepresentation(shelled);
                if (png) {
                    %orig(type, png, options);
                    return;
                }
            }
        }
    }
    %orig(type, data, options);
}

- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    if (type == 1 && fileURL && isTweakEnabled()) {
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data) {
            UIImage *rawImage = [UIImage imageWithData:data];
            if (rawImage) {
                NSURL *tempURL = WritePNGToTemporaryURLFromImage(rawImage);
                if (tempURL) {
                    %orig(type, tempURL, options);
                    return;
                }
            }
        }
    }
    %orig(type, fileURL, options);
}

%end

%hook PHAssetChangeRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = ShellImageIfNeeded(image);
        if (shelled) {
            return %orig(shelled);
        }
    }
    return %orig(image);
}

+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    if (fileURL && isTweakEnabled()) {
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data) {
            UIImage *rawImage = [UIImage imageWithData:data];
            if (rawImage) {
                NSURL *tempURL = WritePNGToTemporaryURLFromImage(rawImage);
                if (tempURL) {
                    return %orig(tempURL);
                }
            }
        }
    }
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
