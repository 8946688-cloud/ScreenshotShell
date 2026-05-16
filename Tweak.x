#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

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
// 终极绝杀：物理级防套娃检测 (读取左上角第一颗像素的暗号)
// --------------------------------------------------------
static BOOL IsImageAlreadyShelled(UIImage *image) {
    if (!image) return NO;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;

    // 截取图片最左上角 1x1 的像素点
    CGImageRef pixelImage = CGImageCreateWithImageInRect(cgImage, CGRectMake(0, 0, 1, 1));
    if (!pixelImage) return NO;

    unsigned char pixelData[4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixelData, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), pixelImage);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(pixelImage);

    // 【对暗号】：检测该像素是否为我们写入的水印色 R:12, G:34, B:56 (允许极小误差)
    if (abs(pixelData[0] - 12) <= 5 && abs(pixelData[1] - 34) <= 5 && abs(pixelData[2] - 56) <= 5) {
        return YES; // 暗号正确，这图已经套过壳了！
    }
    return NO;
}

// --------------------------------------------------------
// 核心：精准合成图像 + 写入暗号
// --------------------------------------------------------
static UIImage *applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    // 【防套娃拦截】：一旦发现暗号，直接原路返回，百分之百杜绝壳中壳！
    if (IsImageAlreadyShelled(rawScreenshot)) {
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

    // 强制使用比例 1.0 进行渲染，绝对服从 config.cfg 里的物理尺寸
    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, outSize.width, outSize.height));
    }

    // 1. 原图填洞
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];
    
    // 2. 盖上外壳
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    // 3. 【打下防伪暗号】：在最左上角画一个肉眼不可见的水印像素
    if (ctx) {
        CGContextSetRGBFillColor(ctx, 12.0/255.0, 34.0/255.0, 56.0/255.0, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, 1));
    }

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    // 【极其关键】：使用原图的 scale (例如 @3x) 重新包装。
    // 这样在 UI 编辑界面绝不会错位放大，且物理尺寸依然完美保留！
    return [UIImage imageWithCGImage:rendered.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

// --- 通道一：小窗口和编辑器拦截 ---
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


// --- 通道二：不编辑直接保存的相册底层兜底拦截 ---
%hook PHAssetCreationRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = applyShellToScreenshot(image);
        if (shelled && shelled != image) {
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
                if (shelled && shelled != rawImage) {
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
            if (shelled && shelled != rawImage) {
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
                if (shelled && shelled != rawImage) {
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
        if (shelled && shelled != image) {
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
                if (shelled && shelled != rawImage) {
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
