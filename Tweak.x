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
// 终极杀招：防套娃（壳中壳）物理检验
// --------------------------------------------------------
static BOOL IsImageAlreadyShelled(UIImage *image, CGFloat templateW, CGFloat templateH) {
    if (!image) return NO;

    // 1. 【第一道防线】：尺寸校验
    // 如果图片的实际像素宽高已经等于壳子的宽高，说明肯定套过壳了
    CGFloat pixelW = image.size.width * image.scale;
    CGFloat pixelH = image.size.height * image.scale;
    if (fabs(pixelW - templateW) < 2.0 && fabs(pixelH - templateH) < 2.0) {
        return YES;
    }

    // 2. 【第二道防线】：读取左上角 (0,0) 的暗号像素
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;

    CGImageRef subImage = CGImageCreateWithImageInRect(cgImage, CGRectMake(0, 0, 1, 1));
    if (!subImage) return NO;

    unsigned char pixel[4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), subImage);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(subImage);

    // 对暗号：我们在套壳时写入了特殊的颜色 R:12, G:34, B:56
    if (abs(pixel[0] - 12) <= 2 && abs(pixel[1] - 34) <= 2 && abs(pixel[2] - 56) <= 2) {
        return YES;
    }

    return NO;
}

// --------------------------------------------------------
// 核心：精准合成图像
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

    // 【防套娃检测】如果在任何流转环节发现图已经套好壳，直接返回原指针！
    if (IsImageAlreadyShelled(rawScreenshot, templateW, templateH)) {
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

    // 强制按 1.0 比例画图，绝对不改变 config 定义的物理像素！
    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, outSize.width, outSize.height));
    }

    // 1. 原图填洞
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];
    
    // 2. 盖上外壳
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    // 3. 【打下防伪暗号】在左上角坐标 (0,0) 画一个肉眼不可见的颜色像素！
    CGContextSetRGBFillColor(ctx, 12.0/255.0, 34.0/255.0, 56.0/255.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, 1, 1));

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    return [UIImage imageWithCGImage:rendered.CGImage scale:1.0 orientation:UIImageOrientationUp];
}

// --------------------------------------------------------
// Hook 注入
// --------------------------------------------------------
%group ScreenshotCoreHook

// --- 提供给 UI 小窗口和编辑器使用的通道 ---
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

// --- 提供给相册最终保存的兜底通道 (完美解决“不编辑无法保存”的问题) ---
%hook PHAssetCreationRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = applyShellToScreenshot(image);
        // 如果指针没变，说明是触发了“防套娃鉴权”（即已经套过了），原路放行即可！
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
