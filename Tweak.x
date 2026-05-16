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
// 核心：基于原版逻辑的 坐标修正 + 强制透明 引擎
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    __block UIImage *finalImage = nil;
    
    @autoreleasepool {
        NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
        UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
        if (!shellImage) return rawScreenshot; 
        
        NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
        NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
        if (!cfgData) return rawScreenshot; 
        
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:nil];
        if (!cfg) return rawScreenshot;
        
        // 维持原版逻辑：以原截图的尺寸作为画布基准，保证 UI 编辑器绝不出错！
        CGFloat rawW = rawScreenshot.size.width * rawScreenshot.scale;
        CGFloat rawH = rawScreenshot.size.height * rawScreenshot.scale;
        
        // ⚠️ 修复1：原作者没用 template_width 算比例，导致坐标全错。这里补上！
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        if (templateW <= 0 || templateH <= 0) {
            templateW = shellImage.size.width;
            templateH = shellImage.size.height;
        }
        
        // 计算外壳为了塞进屏幕需要缩小的比例 (Aspect Fit)
        CGFloat scaleX = rawW / templateW;
        CGFloat scaleY = rawH / templateH;
        CGFloat shellScale = MIN(scaleX, scaleY);
        
        // 计算外壳在画布中的最终尺寸和居中位置
        CGFloat finalShellW = templateW * shellScale;
        CGFloat finalShellH = templateH * shellScale;
        CGFloat shellX = (rawW - finalShellW) / 2.0;
        CGFloat shellY = (rawH - finalShellH) / 2.0;
        
        // 计算截图窟窿在画布中的绝对位置
        CGFloat ltx = [cfg[@"left_top_x"] floatValue] * shellScale;
        CGFloat lty = [cfg[@"left_top_y"] floatValue] * shellScale;
        CGFloat rtx = [cfg[@"right_top_x"] floatValue] * shellScale;
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue] * shellScale;
        
        CGFloat innerX = shellX + ltx;
        CGFloat innerY = shellY + lty;
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        
        if (innerW <= 0 || innerH <= 0) return rawScreenshot;
        
        // ⚠️ 修复2：换用 CG 上下文，参数 NO 强制开启透明底板，根除黑白底色！
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(rawW, rawH), NO, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextClearRect(context, CGRectMake(0, 0, rawW, rawH));
        
        // 底层：画出截图（精准塞入算好的透明窟窿里）
        [rawScreenshot drawInRect:CGRectMake(innerX, innerY, innerW, innerH)];
        
        // 顶层：盖上手机壳（透明层自然遮住边缘）
        [shellImage drawInRect:CGRectMake(shellX, shellY, finalShellW, finalShellH)];
        
        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (renderedImage && renderedImage.CGImage) {
            // 重新赋予原始 Scale，骗过系统 UI
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:UIImageOrientationUp];
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：完全退回你的第一版稳定代码 (只拦截该拦截的)
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 替换 UI 显示（因为尺寸一模一样，编辑框完美工作）
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            
            %orig(shelledImage);
            
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

// 2. 彻底接管底层相册写入（防系统偷存原图）
%hook PHAssetCreationRequest

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (type == 1 && data && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                // 转 PNG 二进制，死死守住透明通道
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
                    // 使用临时文件骗过系统安全机制，原版经典逻辑
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
// 构造入口：回归初心
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotCoreHook);
    }
}
