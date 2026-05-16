#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <CoreImage/CoreImage.h> // 必须引入透视形变框架

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// --------------------------------------------------------
// 声明私有头文件 (粉碎截图缓存的必要组件)
// --------------------------------------------------------
@interface SSEnvironmentDescription : NSObject
@property (nonatomic) CGSize imagePixelSize;
@property (nonatomic) double imageScale;
- (void)setImageSurface:(id)surface; 
@end

@interface SSSScreenshot : NSObject
@property (retain, nonatomic) UIImage *backingImage;
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@end

// --------------------------------------------------------
// 路径辅助
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
// 核心：基于 4 个顶点进行 3D 透视形变并合成
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    __block UIImage *finalImage = nil;
    
    // 开启内存释放池，防止处理 3000x5000 级大图时引发 SpringBoard OOM 崩溃被杀
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
        if (templateW <= 0 || templateH <= 0) return rawScreenshot;
        
        CGFloat pixelW = shellImage.size.width;
        CGFloat pixelH = shellImage.size.height;
        
        // 【防重复套壳】防止 Hook 被多次触发导致画中画
        if (CGSizeEqualToSize(rawScreenshot.size, CGSizeMake(pixelW, pixelH)) || 
            CGSizeEqualToSize(rawScreenshot.size, CGSizeMake(templateW, templateH))) {
            return rawScreenshot;
        }
        
        CGFloat scaleX = pixelW / templateW;
        CGFloat scaleY = pixelH / templateH;
        
        // 严格提取 CFG 中的 4 个顶点坐标，并进行比例换算
        CGFloat ltx = [cfg[@"left_top_x"] floatValue] * scaleX;
        CGFloat lty = [cfg[@"left_top_y"] floatValue] * scaleY;
        CGFloat rtx = [cfg[@"right_top_x"] floatValue] * scaleX;
        CGFloat rty = [cfg[@"right_top_y"] floatValue] * scaleY;
        CGFloat lbx = [cfg[@"left_bottom_x"] floatValue] * scaleX;
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue] * scaleY;
        CGFloat rbx = [cfg[@"right_bottom_x"] floatValue] * scaleX;
        CGFloat rby = [cfg[@"right_bottom_y"] floatValue] * scaleY;
        
        // 1. 将截图标准化 (消除屏幕旋转可能带来的干扰)
        UIGraphicsBeginImageContextWithOptions(rawScreenshot.size, NO, rawScreenshot.scale);
        [rawScreenshot drawAtPoint:CGPointZero];
        UIImage *normalizedScreenshot = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        // 2. 动用底层滤镜：CIPerspectiveTransform 透视形变
        CIImage *ciScreenshot = [[CIImage alloc] initWithImage:normalizedScreenshot];
        CIFilter *perspectiveFilter = [CIFilter filterWithName:@"CIPerspectiveTransform"];
        [perspectiveFilter setValue:ciScreenshot forKey:kCIInputImageKey];
        
        // 注意：CoreImage 坐标系的原点在【左下角】，需要将 Y 轴反转映射
        [perspectiveFilter setValue:[CIVector vectorWithX:ltx Y:pixelH - lty] forKey:@"inputTopLeft"];
        [perspectiveFilter setValue:[CIVector vectorWithX:rtx Y:pixelH - rty] forKey:@"inputTopRight"];
        [perspectiveFilter setValue:[CIVector vectorWithX:lbx Y:pixelH - lby] forKey:@"inputBottomLeft"];
        [perspectiveFilter setValue:[CIVector vectorWithX:rbx Y:pixelH - rby] forKey:@"inputBottomRight"];
        
        // 渲染形变后的截图
        CIImage *outputCIImage = perspectiveFilter.outputImage;
        CIContext *ciContext = [CIContext contextWithOptions:nil];
        CGImageRef cgTransformed = [ciContext createCGImage:outputCIImage fromRect:CGRectMake(0, 0, pixelW, pixelH)];
        UIImage *transformedScreenshot = [UIImage imageWithCGImage:cgTransformed scale:1.0 orientation:UIImageOrientationUp];
        CGImageRelease(cgTransformed);
        
        // 3. 最终画面合成
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            // 🚨 强制锁定 1.0 比例，绝对不能用设备默认的 @3x，这是彻底修复 OOM 内存崩溃的关键！
            format.scale = 1.0; 
            format.opaque = NO; // 保留外壳透明通道
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pixelW, pixelH) format:format];
            
            finalImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                // 底层：已被完美扭曲到 4 个坐标点的截图
                [transformedScreenshot drawInRect:CGRectMake(0, 0, pixelW, pixelH)];
                // 顶层：覆盖带有透明镂空区域的手机壳素材
                [shellImage drawInRect:CGRectMake(0, 0, pixelW, pixelH)];
            }];
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 拦截：接管截屏流与相册保存
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 拦截左下角悬浮窗
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            
            %orig(shelledImage);
            
            // 彻底粉碎系统的硬件级画面缓存，逼迫其使用我们套好壳的图片
            SSEnvironmentDescription *envDesc = [self environmentDescription];
            if (envDesc) {
                if ([envDesc respondsToSelector:@selector(setImageSurface:)]) {
                    [envDesc setImageSurface:nil];
                }
                if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) {
                    [envDesc setImagePixelSize:shelledImage.size];
                }
                if ([envDesc respondsToSelector:@selector(setImageScale:)]) {
                    [envDesc setImageScale:1.0];
                }
            }
            return;
        }
    }
    %orig(image);
}
%end

// 2. 拦截相册的真实保存动作（双保险，防止系统静默绕过悬浮窗保存原图）
%hook PHAssetCreationRequest
+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *shelled = applyShellToScreenshot(image);
        if (shelled && shelled != image) {
            return %orig(shelled);
        }
    }
    return %orig(image);
}

+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        UIImage *shelled = applyShellToScreenshot(rawImage);
        if (shelled && shelled != rawImage) {
            // 如果系统企图用文件路径写入，我们拦截它并换成我们的内存套壳图片！
            return [self creationRequestForAssetFromImage:shelled];
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
