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
// 核心：合成套壳图
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) {
        NSLog(@"[ScreenshotShell] ❌ 失败：找不到外壳 PNG");
        return rawScreenshot; 
    }
    
    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) {
        NSLog(@"[ScreenshotShell] ❌ 失败：找不到 config.cfg");
        return rawScreenshot; 
    }
    
    NSError *error;
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:&error];
    if (!cfg || error) {
        NSLog(@"[ScreenshotShell] ❌ 失败：CFG 解析错误");
        return rawScreenshot;
    }
    
    NSLog(@"[ScreenshotShell] ⚙️ 开始合成...");
    CGFloat leftTopX = [cfg[@"left_top_x"] floatValue];
    CGFloat leftTopY = [cfg[@"left_top_y"] floatValue];
    CGFloat rightTopX = [cfg[@"right_top_x"] floatValue];
    CGFloat leftBottomY = [cfg[@"left_bottom_y"] floatValue];
    
    CGFloat rawW = rightTopX - leftTopX;
    CGFloat rawH = leftBottomY - leftTopY;
    CGFloat templateW = [cfg[@"template_width"] floatValue];
    CGFloat templateH = [cfg[@"template_height"] floatValue];
    
    CGFloat scaleX = (templateW > 0) ? (shellImage.size.width / templateW) : 1.0;
    CGFloat scaleY = (templateH > 0) ? (shellImage.size.height / templateH) : 1.0;
    
    CGRect innerRect = CGRectMake(leftTopX * scaleX, leftTopY * scaleY, rawW * scaleX, rawH * scaleY);
    
    UIGraphicsBeginImageContextWithOptions(shellImage.size, NO, 0.0);
    [rawScreenshot drawInRect:innerRect];
    [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    NSLog(@"[ScreenshotShell] 🎉 合成完毕！");
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// 独立保存方法
// --------------------------------------------------------
static void saveShelledScreenshotToPhotos(UIImage *shelledImage) {
    if (!shelledImage) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:shelledImage];
        } completionHandler:^(BOOL success, NSError *error) {
            if (success) {
                NSLog(@"[ScreenshotShell] 💾 已成功保存套壳图到系统相册！");
            } else {
                NSLog(@"[ScreenshotShell] ❌ 保存到相册失败：%@", error);
            }
        }];
    });
}

// --------------------------------------------------------
// 源头狙击钩子：SSSScreenshotManager
// --------------------------------------------------------
%group SourceSniperHook

%hook SSSScreenshotManager

- (id)createScreenshotWithEnvironmentDescription:(id)env {
    NSLog(@"[ScreenshotShell] 🚀 悬浮窗服务接收到截图包，开始拦截...");
    
    // 1. 让系统原逻辑先执行，生成一个 SSSScreenshot 实体对象
    SSSScreenshot *screenshot = %orig(env);
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (screenshot && prefs && [prefs[@"Enabled"] boolValue]) {
        NSLog(@"[ScreenshotShell] 🔍 提取原始截图中...");
        
        // 2. 强行提取原图 (这会逼迫系统将底层的 IOSurface 转化为 UIImage)
        UIImage *rawImage = [screenshot backingImage];
        
        if (rawImage) {
            // 3. 套壳
            UIImage *shelledImage = applyShellToScreenshot(rawImage);
            
            if (shelledImage && shelledImage != rawImage) {
                // 4. 将套完壳的图塞回去！
                [screenshot setBackingImage:shelledImage];
                NSLog(@"[ScreenshotShell] ✅ 已将套壳图替换进实体!");
                
                // 5. 立即保存一张到相册保底
                saveShelledScreenshotToPhotos(shelledImage);
                
                // 6. 核心动作：粉碎底层的 IOSurface 硬件缓存
                SSEnvironmentDescription *envDesc = [screenshot environmentDescription];
                if (envDesc) {
                    if ([envDesc respondsToSelector:@selector(setImageSurface:)]) {
                        [envDesc setImageSurface:nil];
                        NSLog(@"[ScreenshotShell] 💥 已粉碎 IOSurface 缓存!");
                    }
                    if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) {
                        [envDesc setImagePixelSize:shelledImage.size];
                    }
                    if ([envDesc respondsToSelector:@selector(setImageScale:)]) {
                        [envDesc setImageScale:shelledImage.scale];
                    }
                }
            }
        } else {
            NSLog(@"[ScreenshotShell] ⚠️ 警告：无法提取出 rawImage!");
        }
    }
    
    return screenshot;
}

%end
%end // SourceSniperHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[ScreenshotShell] 💉 插件已注入: %@", bundleId);
    
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(SourceSniperHook);
    }
}
