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
// 路径辅助与偏好设置获取
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

// 解决沙盒读取偏好设置失败的备用方案
static BOOL isTweakEnabled() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && prefs[@"Enabled"] != nil) {
        return [prefs[@"Enabled"] boolValue];
    }
    // 降级使用 CFPreferences，无视沙盒阻拦
    Boolean valid = NO;
    Boolean value = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), CFSTR("com.iosdump.screenshotshell"), &valid);
    return valid ? value : NO;
}

// --------------------------------------------------------
// 核心：基于安全内存的防爆像素渲染算法
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
        
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        
        if (templateW <= 0 || templateH <= 0) {
            templateW = shellImage.size.width * shellImage.scale;
            templateH = shellImage.size.height * shellImage.scale;
        }
        
        CGFloat ltx = [cfg[@"left_top_x"] floatValue];
        CGFloat lty = [cfg[@"left_top_y"] floatValue];
        CGFloat rtx = [cfg[@"right_top_x"] floatValue];
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue];
        
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        if (innerW <= 0 || innerH <= 0) return rawScreenshot;

        // ⚠️ 极其关键【内存防爆机制】：
        // 算出系统原图的真实像素大小
        CGFloat rawPixelW = rawScreenshot.size.width * rawScreenshot.scale;
        // 计算缩放比例：用手机截图真实宽度 ÷ cfg窟窿的宽度
        CGFloat safeScale = rawPixelW / innerW;
        
        // 动态将 3000 多像素的 CFG 画布，等比压缩到适应你手机物理分辨率的安全大小！
        CGFloat safeCanvasW = templateW * safeScale;
        CGFloat safeCanvasH = templateH * safeScale;
        CGFloat safeLtx = ltx * safeScale;
        CGFloat safeLty = lty * safeScale;
        CGFloat safeInnerW = innerW * safeScale;
        CGFloat safeInnerH = innerH * safeScale;
        
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = 1.0;  // 必须是 1.0，依靠上面的真实像素点映射
            format.opaque = NO;
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(safeCanvasW, safeCanvasH) format:format];
            
            UIImage *renderedImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                // 底层：塞入原图
                [rawScreenshot drawInRect:CGRectMake(safeLtx, safeLty, safeInnerW, safeInnerH)];
                // 顶层：覆盖安全缩放后的壳（iOS底层绘制会自动下采样优化内存）
                [shellImage drawInRect:CGRectMake(0, 0, safeCanvasW, safeCanvasH)];
            }];
            
            // 生成后，赋予屏幕原始的 Retina 缩放倍率，完美清晰！
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
        }
    }
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：UI 替换 + 底层文件存入替换
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 替换 UI 显示
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
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

// 2. 彻底接管底层相册写入
%hook PHAssetCreationRequest

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    if (type == 1 && data && isTweakEnabled()) {
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
    if (type == 1 && fileURL && isTweakEnabled()) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                
                // ⚠️ 极其关键【沙盒穿透】：
                // 不要新建临时文件（相册无权读取），直接覆盖系统给定的这个原本要存入的 fileURL ！
                // 因为系统已经分配好了相册读取权限，狸猫换太子最安全！
                [shelledData writeToFile:fileURL.path atomically:YES];
                
                %orig(type, fileURL, options);
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
    // ⚠️ 极其关键【进程全接管】：
    // 移除了只监听 com.apple.ScreenshotServicesService 的限制！
    // 这样如果你截图后直接左滑隐藏，SpringBoard 进程也会触发相册保存拦截，做到 100% 覆盖。
    %init(ScreenshotCoreHook);
}
