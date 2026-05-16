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
// 核心：外壳尺寸锁死算法 (壳绝对不变，截图塞进洞里)
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    // 防重复套壳标记
    if ([rawScreenshot.accessibilityIdentifier isEqualToString:@"ScreenshotShell_Done"]) {
        return rawScreenshot;
    }

    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

    // ⚠️ 终极改动：直接读取外壳的原始绝对像素！
    // 不管截图怎么被裁剪，画布永远是外壳的大小！
    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];
    if (templateW <= 0 || templateH <= 0) {
        templateW = shellImage.size.width;
        templateH = shellImage.size.height;
    }

    CGFloat ltx = [cfg[@"left_top_x"] doubleValue];
    CGFloat lty = [cfg[@"left_top_y"] doubleValue];
    CGFloat rtx = [cfg[@"right_top_x"] doubleValue];
    CGFloat lby = [cfg[@"left_bottom_y"] doubleValue];

    CGFloat holeW = rtx - ltx;
    CGFloat holeH = lby - lty;
    if (holeW <= 0 || holeH <= 0) return rawScreenshot;

    __block UIImage *finalImage = nil;

    @autoreleasepool {
        // ⚠️ 开启透明底色上下文，画布大小死死锁定为壳的原始大小！
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(templateW, templateH), NO, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextClearRect(ctx, CGRectMake(0, 0, templateW, templateH));

        // 1. 底层：把截图强行拉伸/压缩，严丝合缝地填满 CFG 标记的那个窟窿坐标
        [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];

        // 2. 顶层：从 (0,0) 开始铺满原汁原味、大小分毫不差的手机壳
        [shellImage drawInRect:CGRectMake(0, 0, templateW, templateH)];

        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (renderedImage && renderedImage.CGImage) {
            // scale 保持 1.0，这意味着最终输出的就是绝对物理像素 (比如 3370x5996)
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:1.0 orientation:UIImageOrientationUp];
            finalImage.accessibilityIdentifier = @"ScreenshotShell_Done"; // 打上处理完毕烙印
        }
    }

    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：海陆空全面封锁保存路径
// --------------------------------------------------------
%group ScreenshotCoreHook

// 专门骗过 UI：修改左下角预览窗
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            %orig(shelledImage);
            
            // 防 UI 崩溃
            SSEnvironmentDescription *envDesc = [self environmentDescription];
            if (envDesc && [envDesc respondsToSelector:@selector(setImageSurface:)]) {
                [envDesc setImageSurface:nil];
            }
            return;
        }
    }
    %orig(image);
}
%end


// 专门拦截相册：封死所有“直接滑动保存”的隐蔽类方法与实例方法
%hook PHAssetCreationRequest

// 拦截类方法 1 (内存图直接保存)
+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = applyShellToScreenshot(image);
        if (shelled && shelled != image) {
            return %orig(shelled);
        }
    }
    return %orig(image);
}

// 拦截类方法 2 (缓存文件直接保存 - 这是导致你不点编辑就没壳的最大元凶)
+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    if (fileURL && isTweakEnabled()) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
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
    return %orig(fileURL);
}

// 拦截实例方法 1 (二进制流保存)
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

// 拦截实例方法 2 (文件流保存)
- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    if (type == 1 && fileURL && isTweakEnabled()) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                    tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                    [shelledData writeToFile:tempPath atomically:YES];
                    
                    NSURL *newURL = [NSURL fileURLWithPath:tempPath];
                    %orig(type, newURL, options);
                    return;
                }
            }
        }
    }
    %orig;
}
%end // PHAssetCreationRequest

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
