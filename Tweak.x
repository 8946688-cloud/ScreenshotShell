#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// --------------------------------------------------------
// 声明私有头文件
// --------------------------------------------------------
@interface SSEnvironmentDescription : NSObject
- (void)setImageSurface:(id)surface; 
@end

@interface SSSScreenshot : NSObject
@property (retain, nonatomic) UIImage *backingImage;
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@end

// --------------------------------------------------------
// 路径辅助与配置
// --------------------------------------------------------
static NSString * GetPrefDir() {
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

static NSString * GetPlistPath() {
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

static BOOL isTweakEnabled() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    return prefs ? [prefs[@"Enabled"] boolValue] : NO;
}

// --------------------------------------------------------
// 核心：锁死外壳尺寸的完美对齐算法
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

    // ⚠️ 终极改动：将画布尺寸死死锁定为 CFG 提供的大尺寸，绝对不会因为你裁剪而变化！
    CGFloat templateW = round([cfg[@"template_width"] doubleValue]);
    CGFloat templateH = round([cfg[@"template_height"] doubleValue]);
    if (templateW <= 0) templateW = round(shellImage.size.width);
    if (templateH <= 0) templateH = round(shellImage.size.height);

    CGFloat rawW = round(rawScreenshot.size.width * rawScreenshot.scale);
    CGFloat rawH = round(rawScreenshot.size.height * rawScreenshot.scale);

    // 🛡️ 无敌防死循环锁：如果传进来的图片尺寸已经和壳一样大，说明它已经是套好壳的成品，直接放行！
    if (rawW == templateW && rawH == templateH) {
        return rawScreenshot;
    }

    CGFloat ltx = round([cfg[@"left_top_x"] doubleValue]);
    CGFloat lty = round([cfg[@"left_top_y"] doubleValue]);
    CGFloat rtx = round([cfg[@"right_top_x"] doubleValue]);
    CGFloat lby = round([cfg[@"left_bottom_y"] doubleValue]);

    CGFloat holeW = rtx - ltx;
    CGFloat holeH = lby - lty;
    if (holeW <= 0 || holeH <= 0) return rawScreenshot;

    __block UIImage *finalImage = nil;

    @autoreleasepool {
        // 使用 NO 开启纯透明通道防黑白底色，1.0 锁定真实物理尺寸
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(templateW, templateH), NO, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextClearRect(ctx, CGRectMake(0, 0, templateW, templateH));

        // 底层：把截图强制塞进算好的洞口
        [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];

        // 顶层：盖上原始尺寸的手机壳，分毫不差
        [shellImage drawInRect:CGRectMake(0, 0, templateW, templateH)];

        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (renderedImage && renderedImage.CGImage) {
            // 重新赋予 1.0 缩放比，输出真无损大图
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:1.0 orientation:UIImageOrientationUp];
        }
    }

    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：海陆空 360 度封锁保存大门
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. UI 层：只为让你在左下角预览看到壳
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            // 注意：删除了之前导致你变原图的 setImageSurface:nil 骚操作，返璞归真
            %orig(shelledImage);
            return;
        }
    }
    %orig(image);
}
%end


// 2. 相册保存层：把能保存图片的方法祖宗十八代全部拦下来
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
                    NSData *shelledData = UIImagePNGRepresentation(shelled);
                    if (shelledData) {
                        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                        tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                        if ([shelledData writeToFile:tempPath atomically:YES]) {
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
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    %orig(type, shelledData, options);
                    return;
                }
            }
        }
    }
    %orig;
}

- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    if (type == 1 && fileURL && isTweakEnabled()) {
        // 使用 NSData 硬读取，突破单纯 file 路径在某些沙盒下的限制
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data) {
            UIImage *rawImage = [UIImage imageWithData:data];
            if (rawImage) {
                UIImage *shelled = applyShellToScreenshot(rawImage);
                if (shelled && shelled != rawImage) {
                    NSData *shelledData = UIImagePNGRepresentation(shelled);
                    if (shelledData) {
                        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                        tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                        if ([shelledData writeToFile:tempPath atomically:YES]) {
                            %orig(type, [NSURL fileURLWithPath:tempPath], options);
                            return;
                        }
                    }
                }
            }
        }
    }
    %orig;
}
%end // PHAssetCreationRequest


// 3. 拦截备用相册请求类（防止系统使用该途径）
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
                    NSData *shelledData = UIImagePNGRepresentation(shelled);
                    if (shelledData) {
                        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                        tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                        if ([shelledData writeToFile:tempPath atomically:YES]) {
                            return %orig([NSURL fileURLWithPath:tempPath]);
                        }
                    }
                }
            }
        }
    }
    return %orig(fileURL);
}
%end // PHAssetChangeRequest

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
