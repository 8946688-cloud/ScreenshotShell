
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
// 核心：基于原屏幕尺寸的完美透明渲染算法
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ❌ 失败：原始截图为空");
        return nil;
    }
    
    __block UIImage *finalImage = nil;
    
    @autoreleasepool {
        NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
        UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
        if (!shellImage) {
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: ❌ 失败：找不到外壳素材");
            return rawScreenshot; 
        }
        
        NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
        NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
        if (!cfgData) {
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: ❌ 失败：找不到配置文件");
            return rawScreenshot; 
        }
        
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:nil];
        if (!cfg) return rawScreenshot;
        
        // 1. 获取原截图的真实像素尺寸（保持这个画布大小，系统UI才绝对不会乱裁剪！）
        CGFloat rawW = rawScreenshot.size.width * rawScreenshot.scale;
        CGFloat rawH = rawScreenshot.size.height * rawScreenshot.scale;
        
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        if (templateW <= 0 || templateH <= 0) {
            templateW = shellImage.size.width;
            templateH = shellImage.size.height;
        }
        
        // 2. 计算外壳缩放比例 (将巨大的外壳等比缩小，刚好塞进手机屏幕的画布里)
        CGFloat scaleX = rawW / templateW;
        CGFloat scaleY = rawH / templateH;
        CGFloat shellScale = MIN(scaleX, scaleY);
        
        CGFloat finalShellW = templateW * shellScale;
        CGFloat finalShellH = templateH * shellScale;
        
        // 居中外壳
        CGFloat shellX = (rawW - finalShellW) / 2.0;
        CGFloat shellY = (rawH - finalShellH) / 2.0;
        
        // 3. 计算出缩小后的窟窿位置
        CGFloat ltx = [cfg[@"left_top_x"] floatValue] * shellScale;
        CGFloat lty = [cfg[@"left_top_y"] floatValue] * shellScale;
        CGFloat rtx = [cfg[@"right_top_x"] floatValue] * shellScale;
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue] * shellScale;
        
        CGFloat innerX = shellX + ltx;
        CGFloat innerY = shellY + lty;
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 画布尺寸: %.1f x %.1f", rawW, rawH);
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 外壳缩小至: %.1f x %.1f", finalShellW, finalShellH);
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 截图将被压缩在: %@", NSStringFromCGRect(CGRectMake(innerX, innerY, innerW, innerH)));
        
        // 4. ⚠️ 终极杀招：使用原始的上下文 API 彻底根除黑/白底！参数 NO 代表透明画布！
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(rawW, rawH), NO, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextClearRect(context, CGRectMake(0, 0, rawW, rawH));
        
        // 底层：把你的屏幕截图，挤压填进算好的窟窿里
        [rawScreenshot drawInRect:CGRectMake(innerX, innerY, innerW, innerH)];
        
        // 顶层：盖上手机外壳（因为画布是透明的，窟窿也是透明的，所以刚好能漏出底下的截图！）
        [shellImage drawInRect:CGRectMake(shellX, shellY, finalShellW, finalShellH)];
        
        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (renderedImage && renderedImage.CGImage) {
            // 重新赋予原始 Scale 和 方向，完美骗过系统
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:UIImageOrientationUp];
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🎉 图片内存合成完毕！");
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：退回原汁原味的拦截点 (告别双重保存的诡异BUG)
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 替换左下角 UI 显示
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🚀 触发编辑器 UI 替换");
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

// 2. 接管底层相册写入 (利用系统的正常保存流，只存一张完美的 PNG！)
%hook PHAssetCreationRequest

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (type == 1 && data && prefs && [prefs[@"Enabled"] boolValue]) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 📸 触发相册直写 (Data)");
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                // 强制输出为 PNG 以保留透明通道
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
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 📸 触发相册直写 (FileURL)");
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                // 强制输出 PNG 保留透明通道
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    // 经典的临时文件“狸猫换太子”，这个逻辑在你的机器上是绝对成功的
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
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 💉 成功注入进程: %@", bundleId);
        %init(ScreenshotCoreHook);
    }
}
