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
@property (nonatomic) CGSize imagePixelSize;
@property (nonatomic) double imageScale;
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

// --------------------------------------------------------
// 核心：基于取整与直接输出的完美透明渲染算法
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    // ⚠️ 防死循环标记，保证只套壳一次
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

    CGFloat rawW = rawScreenshot.size.width * rawScreenshot.scale;
    CGFloat rawH = rawScreenshot.size.height * rawScreenshot.scale;

    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];

    // 仅提取我们需要用到的四个有效坐标，避免出现 unused variable 编译错误
    CGFloat ltx = [cfg[@"left_top_x"] doubleValue];
    CGFloat lty = [cfg[@"left_top_y"] doubleValue];
    CGFloat rtx = [cfg[@"right_top_x"] doubleValue];
    CGFloat lby = [cfg[@"left_bottom_y"] doubleValue];

    // 计算内部洞的实际宽和高
    CGFloat holeW = rtx - ltx;
    CGFloat holeH = lby - lty;
    if (holeW <= 0 || holeH <= 0) return rawScreenshot;

    CGFloat scaleX = rawW / holeW;
    CGFloat scaleY = rawH / holeH;
    CGFloat scale = MIN(scaleX, scaleY);

    // ⚠️ 关键点：统一使用 round 取整，防止出现半像素抗锯齿导致的黑白边缝隙
    CGFloat canvasW = round(templateW * scale);
    CGFloat canvasH = round(templateH * scale);

    CGFloat drawX = round(ltx * scale);
    CGFloat drawY = round(lty * scale);
    CGFloat drawW = round(holeW * scale);
    CGFloat drawH = round(holeH * scale);

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvasW, canvasH), NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextClearRect(ctx, CGRectMake(0, 0, canvasW, canvasH));

    [rawScreenshot drawInRect:CGRectMake(drawX, drawY, drawW, drawH)];
    [shellImage drawInRect:CGRectMake(0, 0, canvasW, canvasH)];

    UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (renderedImage) {
        renderedImage.accessibilityIdentifier = @"ScreenshotShell_Done";
    }

    // ⚠️ 关键点：不再二次包一层 scale，直接原封不动返回当前画出来的纯净图片对象
    return renderedImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：回归稳定版拦截，去除多余操作
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 专门骗过 UI：让左下角小窗口显示带壳图片
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            
            // ⚠️ 关键点：直接覆盖原图交给系统，不再调用 setImageSurface:nil 导致整个 UI 图层消失！
            %orig(shelledImage);
            return;
        }
    }
    %orig(image);
}
%end

// 2. 专门骗过相册：拦截系统自身真正的保存动作！
%hook PHAssetCreationRequest

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (type == 1 && data && prefs && [prefs[@"Enabled"] boolValue]) {
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
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (type == 1 && fileURL && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    // 使用最稳妥的临时文件大法，保证权限无懈可击
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
