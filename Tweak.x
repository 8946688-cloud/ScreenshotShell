#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ============================================
// 1. 路径与配置辅助 (完全保留你的原逻辑)
// ============================================
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

// ============================================
// 2. 核心合成逻辑 (加入追踪日志)
// ============================================
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) {
        NSLog(@"[ScreenshotShell] ❌ 合成失败：传入的原始图片为空");
        return nil;
    }
    
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) {
        NSLog(@"[ScreenshotShell] ❌ 合成失败：未找到外壳素材 -> %@", shellPath);
        return rawScreenshot; 
    }
    
    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) {
        NSLog(@"[ScreenshotShell] ❌ 合成失败：未找到配置文件 -> %@", cfgPath);
        return rawScreenshot; 
    }
    
    NSError *error;
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:&error];
    if (!cfg || error) {
        NSLog(@"[ScreenshotShell] ❌ 合成失败：JSON 配置文件解析错误 -> %@", error);
        return rawScreenshot;
    }
    
    NSLog(@"[ScreenshotShell] ✅ 素材和配置读取成功，开始计算坐标并合成！");
    
    CGFloat leftTopX = [cfg[@"left_top_x"] floatValue];
    CGFloat leftTopY = [cfg[@"left_top_y"] floatValue];
    CGFloat rightTopX = [cfg[@"right_top_x"] floatValue];
    CGFloat leftBottomY = [cfg[@"left_bottom_y"] floatValue];
    
    CGFloat rawW = rightTopX - leftTopX;
    CGFloat rawH = leftBottomY - leftTopY;
    
    CGFloat templateW = [cfg[@"template_width"] floatValue];
    CGFloat templateH = [cfg[@"template_height"] floatValue];
    
    // 动态比例换算
    CGFloat scaleX = (templateW > 0) ? (shellImage.size.width / templateW) : 1.0;
    CGFloat scaleY = (templateH > 0) ? (shellImage.size.height / templateH) : 1.0;
    
    CGRect innerRect = CGRectMake(leftTopX * scaleX, leftTopY * scaleY, rawW * scaleX, rawH * scaleY);
    
    UIGraphicsBeginImageContextWithOptions(shellImage.size, NO, 0.0);
    [rawScreenshot drawInRect:innerRect];
    [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    NSLog(@"[ScreenshotShell] 🎉 恭喜！套壳合成完毕！");
    return finalImage ?: rawScreenshot;
}

// ============================================
// 3. 终极必杀技：拦截相册保存入口
// ============================================
%group UltimateSaveHook

%hook PHAssetChangeRequest

// 拦截保存 UIImage 到相册的请求
+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        NSLog(@"[ScreenshotShell] 📸 成功拦截到系统相册写入请求 (Image)");
        
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            NSLog(@"[ScreenshotShell] 💾 正在将套壳后的图片写入相册...");
            return %orig(shelledImage); // 替换原图，直接存入套壳图
        }
    }
    return %orig(image);
}

// 拦截通过文件路径保存到相册的请求 (部分 iOS 版本采用此方式)
+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        NSLog(@"[ScreenshotShell] 📸 成功拦截到系统相册写入请求 (FileURL: %@)", fileURL);
        
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        UIImage *shelledImage = applyShellToScreenshot(rawImage);
        
        if (shelledImage && shelledImage != rawImage) {
            NSLog(@"[ScreenshotShell] 💾 正在将套壳后的图片写入相册 (转换 FileURL 为 Image)");
            // 改变保存方式，将处理好的内存图片保存进去
            return [self creationRequestForAssetFromImage:shelledImage];
        }
    }
    return %orig(fileURL);
}

%end
%end // UltimateSaveHook


// ============================================
// 4. 辅助观察 UI 触发 (仅用于日志追踪)
// ============================================
%group UIObserverHook
%hook SSSScreenshotManager
- (id)createScreenshotWithEnvironmentDescription:(id)env {
    NSLog(@"[ScreenshotShell] 🚀 悬浮窗服务已接收到截图数据包!");
    return %orig(env);
}
%end
%end


// ============================================
// 5. 构造入口，分配进程
// ============================================
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[ScreenshotShell] 💉 插件已成功注入进程: %@", bundleId);
    
    // 无论是截图悬浮窗服务，还是 SpringBoard 直接保存，我们都在它们的相册写入接口设下埋伏
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(UltimateSaveHook);
        %init(UIObserverHook);
    } else if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(UltimateSaveHook);
    }
}
