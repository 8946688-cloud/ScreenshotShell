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
// 核心：等比内缩算法 (完美解决编辑框错位)
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
        
        // ⚠️ 重点：我们以原截图的尺寸作为画布基准，保证输出尺寸 100% 相同！
        CGFloat rawW = rawScreenshot.size.width * rawScreenshot.scale;
        CGFloat rawH = rawScreenshot.size.height * rawScreenshot.scale;
        
        CGFloat shellW = shellImage.size.width;
        CGFloat shellH = shellImage.size.height;
        
        // 计算外壳为了塞进屏幕需要缩小的比例 (Aspect Fit)
        CGFloat scaleX = rawW / shellW;
        CGFloat scaleY = rawH / shellH;
        CGFloat shellScale = MIN(scaleX, scaleY);
        
        // 计算外壳在画布中的最终尺寸和居中位置
        CGFloat finalShellW = shellW * shellScale;
        CGFloat finalShellH = shellH * shellScale;
        CGFloat shellX = (rawW - finalShellW) / 2.0;
        CGFloat shellY = (rawH - finalShellH) / 2.0;
        
        // 计算截图在画布中的位置 (基于 cfg 坐标)
        CGFloat ltx = [cfg[@"left_top_x"] floatValue] * shellScale;
        CGFloat lty = [cfg[@"left_top_y"] floatValue] * shellScale;
        CGFloat rtx = [cfg[@"right_top_x"] floatValue] * shellScale;
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue] * shellScale;
        
        CGFloat innerX = shellX + ltx;
        CGFloat innerY = shellY + lty;
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        
        // 开始渲染 (强制 1.0 比例防内存溢出)
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = 1.0; 
            format.opaque = NO; 
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(rawW, rawH) format:format];
            
            UIImage *renderedImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                // 底层：画出截图（它会被等比缩小塞进透明窟窿里）
                [rawScreenshot drawInRect:CGRectMake(innerX, innerY, innerW, innerH)];
                // 顶层：盖上手机壳（它天然的镂空透明层会遮住多余的边缘）
                [shellImage drawInRect:CGRectMake(shellX, shellY, finalShellW, finalShellH)];
            }];
            
            // 重新赋予原始 Scale，骗过系统 UI
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：UI 替换 + 底层文件存入替换
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
    // type == 1 代表 PHAssetResourceTypePhoto
    if (type == 1 && data && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                %orig(type, shelledData, options);
                return;
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
                // 如果系统企图存临时文件，我们狸猫换太子，生成一个新的套壳临时文件塞给它
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                [shelledData writeToFile:tempPath atomically:YES];
                
                NSURL *newURL = [NSURL fileURLWithPath:tempPath];
                %orig(type, newURL, options);
                return;
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
    // 悬浮窗进程负责后续的 UI 展示和相册保存，我们只在这里下钩子
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotCoreHook);
    }
}
