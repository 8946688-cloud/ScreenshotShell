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
// 核心：基于 CFG 绝对像素的外壳渲染算法 (完美契合)
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    __block UIImage *finalImage = nil;
    
    @autoreleasepool {
        // 1. 读取手机壳图片和配置
        NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
        UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
        if (!shellImage) return rawScreenshot; 
        
        NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
        NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
        if (!cfgData) return rawScreenshot; 
        
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:nil];
        if (!cfg) return rawScreenshot;
        
        // 2. 从 CFG 读取外壳整体尺寸 (使用绝对像素)
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        
        // 容错处理：如果 cfg 没写宽高，降级使用图片的真实像素大小
        if (templateW <= 0 || templateH <= 0) {
            templateW = shellImage.size.width * shellImage.scale;
            templateH = shellImage.size.height * shellImage.scale;
        }
        
        // 3. 从 CFG 读取内部透明窟窿的坐标
        CGFloat ltx = [cfg[@"left_top_x"] floatValue];
        CGFloat lty = [cfg[@"left_top_y"] floatValue];
        CGFloat rtx = [cfg[@"right_top_x"] floatValue];
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue];
        
        // 计算内部窟窿的真实宽度和高度
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        
        // 防止除数为0或配置异常
        if (innerW <= 0 || innerH <= 0) return rawScreenshot;
        
        // 4. 开始渲染画布
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            // ⚠️ 极其关键：强制 Scale 为 1.0，这意味着我们完全按照 1:1 的真实像素(1像素=1点)来画，防止被系统的 @3x 机制扰乱坐标！
            format.scale = 1.0;  
            format.opaque = NO;  // 允许透明层
            
            // 以外壳的总像素大小作为大画布
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(templateW, templateH) format:format];
            
            UIImage *renderedImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                
                // 第一步（底层）：把系统的原截图，强行塞进 CFG 规定的“窟窿”坐标里
                [rawScreenshot drawInRect:CGRectMake(ltx, lty, innerW, innerH)];
                
                // 第二步（顶层）：把手机壳盖在最上面（从 0,0 开始铺满画布），透明区域自然会漏出下面的原图
                [shellImage drawInRect:CGRectMake(0, 0, templateW, templateH)];
                
            }];
            
            // 5. 重新赋予原始截屏的 Scale (例如 @3x) 
            // 这样系统保存相册和显示时，依然会认为这是一张超高清的 Retina 图片，不会变模糊。
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：UI 替换 + 底层文件存入替换
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 替换 UI 显示（因为尺寸变了，所以重置系统编辑框约束）
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
