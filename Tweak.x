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
- (void)setImageSurface:(id)surface; 
@end

@interface SSSScreenshot : NSObject
@property (retain, nonatomic) UIImage *backingImage;
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@end

// --------------------------------------------------------
// 路径辅助与配置读取
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
// 核心：逆向等比缩放算法 (完美修复 OOM 与编辑框错位)
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
        
        // 1. 获取原始截图的真实物理像素尺寸
        CGFloat rawW = rawScreenshot.size.width * rawScreenshot.scale;
        CGFloat rawH = rawScreenshot.size.height * rawScreenshot.scale;
        
        // 2. 获取 CFG 中定义的手机屏幕在壳子中的坐标
        CGFloat ltx = [cfg[@"left_top_x"] floatValue];
        CGFloat lty = [cfg[@"left_top_y"] floatValue];
        CGFloat rbx = [cfg[@"right_bottom_x"] floatValue];
        CGFloat rby = [cfg[@"right_bottom_y"] floatValue];
        
        // CFG 屏幕区域的宽高
        CGFloat cfgScreenW = rbx - ltx;
        CGFloat cfgScreenH = rby - lty;
        if (cfgScreenW <= 0 || cfgScreenH <= 0) return rawScreenshot;
        
        // 3. 计算外壳需要缩小多少，才能正好套住原截图
        CGFloat scaleX = rawW / cfgScreenW;
        CGFloat scaleY = rawH / cfgScreenH;
        
        // 缩小后的最终画布尺寸（截图尺寸 + 边框厚度）
        CGFloat finalShellW = shellImage.size.width * scaleX;
        CGFloat finalShellH = shellImage.size.height * scaleY;
        
        // 计算截图应该画在画布的哪个位置
        CGFloat drawX = ltx * scaleX;
        CGFloat drawY = lty * scaleY;
        
        // 4. 开始纯 CPU 安全渲染
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = 1.0; // 🚨 强锁 1.0，彻底告别内存溢出！
            format.opaque = NO; // 保留外壳的透明边缘
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(finalShellW, finalShellH) format:format];
            
            UIImage *renderedImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                // 底层：画出原生截图
                [rawScreenshot drawInRect:CGRectMake(drawX, drawY, rawW, rawH)];
                // 顶层：盖上缩放好的外壳（外壳上的透明窟窿完美对齐截图）
                [shellImage drawInRect:CGRectMake(0, 0, finalShellW, finalShellH)];
            }];
            
            // 5. 将处理好的图片赋予原始的 scale（骗过 iOS 编辑器，让其保持正常的 UI 比例）
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
        }
    }
    
    return finalImage ?: rawScreenshot;
}


// --------------------------------------------------------
// 钩子 1：拦截悬浮窗，替换界面上的图片并粉碎缓存
// --------------------------------------------------------
%group ScreenshotUIHook

%hook SSSScreenshotManager
- (id)createScreenshotWithEnvironmentDescription:(id)env {
    SSSScreenshot *screenshot = %orig(env);
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (screenshot && prefs && [prefs[@"Enabled"] boolValue]) {
        
        UIImage *rawImage = [screenshot backingImage];
        if (rawImage) {
            UIImage *shelledImage = applyShellToScreenshot(rawImage);
            
            if (shelledImage && shelledImage != rawImage) {
                // 1. 塞回实体对象，改变悬浮窗的展示
                [screenshot setBackingImage:shelledImage];
                
                // 2. 粉碎底层的 IOSurface 硬件缓存
                SSEnvironmentDescription *envDesc = [screenshot environmentDescription];
                if (envDesc) {
                    if ([envDesc respondsToSelector:@selector(setImageSurface:)]) {
                        [envDesc setImageSurface:nil];
                    }
                    if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) {
                        [envDesc setImagePixelSize:CGSizeMake(shelledImage.size.width * shelledImage.scale, shelledImage.size.height * shelledImage.scale)];
                    }
                }
            }
        }
    }
    return screenshot;
}
%end

%end // ScreenshotUIHook


// --------------------------------------------------------
// 钩子 2：封死相册保存的所有底层后门
// --------------------------------------------------------
%group PhotoSaveHook

%hook PHAssetCreationRequest

// 拦截方法A：通过 UIImage 直接保存
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

// 拦截方法B：系统生成临时文件后通过文件路径保存
+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        UIImage *shelled = applyShellToScreenshot(rawImage);
        if (shelled && shelled != rawImage) {
            // 狸猫换太子：将文件保存请求强制替换为内存图片保存请求！
            return [self creationRequestForAssetFromImage:shelled];
        }
    }
    return %orig(fileURL);
}

// 拦截方法C：系统通过 NSData 二进制流保存
- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    // type == 1 代表 Photo 资源
    if (type == 1 && data && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithData:data];
        UIImage *shelled = applyShellToScreenshot(rawImage);
        if (shelled && shelled != rawImage) {
            NSData *shelledData = UIImagePNGRepresentation(shelled);
            %orig(type, shelledData, options);
            return;
        }
    }
    %orig(type, data, options);
}

// 拦截方法D：实例化的文件流保存
- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (type == 1 && fileURL && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        UIImage *shelled = applyShellToScreenshot(rawImage);
        if (shelled && shelled != rawImage) {
            NSData *shelledData = UIImagePNGRepresentation(shelled);
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            tempPath = [tempPath stringByAppendingPathExtension:@"png"];
            [shelledData writeToFile:tempPath atomically:YES];
            NSURL *newURL = [NSURL fileURLWithPath:tempPath];
            %orig(type, newURL, options);
            return;
        }
    }
    %orig(type, fileURL, options);
}

%end
%end // PhotoSaveHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    
    // 悬浮窗服务（处理 UI）
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotUIHook);
        %init(PhotoSaveHook);
    } 
    // SpringBoard 或其他进程如果直接调用了底层相册保存 API，一并拦截！
    else if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(PhotoSaveHook);
    }
}
