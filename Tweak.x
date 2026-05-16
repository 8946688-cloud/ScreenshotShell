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
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block;
@end

@interface SSSScreenshotImageProvider : NSObject
@property (nonatomic, weak) SSSScreenshot *screenshot;
- (id)requestOutputImageForSavingBlocking;
- (id)requestOutputImageForUIBlocking;
- (void)requestOutputImageForSaving:(id)block;
- (void)requestOutputImageForUI:(id)block;
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

// 防重复套壳标记 (用于常规拦截)
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
// 核心：精准合成图像 + 终极特征防套娃
// --------------------------------------------------------
static UIImage *applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    // 软拦截：检查关联对象
    if (ImageAlreadyShelled(rawScreenshot)) return rawScreenshot;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];
    if (templateW <= 0 || templateH <= 0) return rawScreenshot;

    // ==========================================
    // 终极杀招：物理特征防套娃 (彻底解决相册底层的壳中壳)
    // 苹果原生的截图 scale 是 2.0 或 3.0，而我们合成的图强制为 1.0。
    // 如果一张图的 scale 已经是 1.0，并且宽度等于模板宽度，说明100%是我们的图！
    // ==========================================
    if (rawScreenshot.scale == 1.0 && fabs(rawScreenshot.size.width - templateW) < 1.0 && fabs(rawScreenshot.size.height - templateH) < 1.0) {
        return rawScreenshot;
    }

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

    // 强制使用比例 1.0 进行渲染，彻底摆脱屏幕比例的干扰
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

    // 强制按 1.0 比例导出，尺寸永远是固定的 templateW/templateH
    UIImage *finalImage = [UIImage imageWithCGImage:rendered.CGImage
                                              scale:1.0
                                        orientation:UIImageOrientationUp];
    return MarkImageShelled(finalImage);
}


// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

// --- 解决小窗口显示原图的问题 ---
%hook SSSScreenshot

// 拦截小窗口过渡动画，确保出现瞬间就是带壳的
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

// 同步替换底层原图
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

- (UIImage *)backingImage {
    UIImage *orig = %orig;
    if (orig && isTweakEnabled()) {
        return applyShellToScreenshot(orig) ?: orig;
    }
    return orig;
}

%end


// --- 解决编辑界面的数据提供器 ---
%hook SSSScreenshotImageProvider

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if ([image isKindOfClass:[UIImage class]]) {
        return applyShellToScreenshot((UIImage *)image) ?: image;
    }
    return image;
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;
    if ([image isKindOfClass:[UIImage class]]) {
        return applyShellToScreenshot((UIImage *)image) ?: image;
    }
    return image;
}

- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }
    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            origBlock(applyShellToScreenshot((UIImage *)image) ?: image);
        } else {
            origBlock(image);
        }
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
        if ([image isKindOfClass:[UIImage class]]) {
            origBlock(applyShellToScreenshot((UIImage *)image) ?: image);
        } else {
            origBlock(image);
        }
    };
    %orig(wrappedBlock);
}
%end


// --- 解决不编辑就无法保存的问题 (你完美的相册兜底方案) ---
%hook PHAssetCreationRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = applyShellToScreenshot(image);
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
                UIImage *shelled = applyShellToScreenshot(rawImage);
                if (shelled) {
                    NSData *png = UIImagePNGRepresentation(shelled);
                    if (png) {
                        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                        tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                        if ([png writeToFile:tempPath atomically:YES]) {
                            return %orig([NSURL fileURLWithPath:tempPath]);
                        }
                    }
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
            UIImage *shelled = applyShellToScreenshot(rawImage);
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
                UIImage *shelled = applyShellToScreenshot(rawImage);
                if (shelled) {
                    NSData *png = UIImagePNGRepresentation(shelled);
                    if (png) {
                        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                        tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                        if ([png writeToFile:tempPath atomically:YES]) {
                            %orig(type, [NSURL fileURLWithPath:tempPath], options);
                            return;
                        }
                    }
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
        UIImage *shelled = applyShellToScreenshot(image);
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
                UIImage *shelled = applyShellToScreenshot(rawImage);
                if (shelled) {
                    NSData *png = UIImagePNGRepresentation(shelled);
                    if (png) {
                        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                        tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                        if ([png writeToFile:tempPath atomically:YES]) {
                            return %orig([NSURL fileURLWithPath:tempPath]);
                        }
                    }
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
