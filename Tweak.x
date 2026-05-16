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
// 核心：终极完美防裁剪、纯透明渲染算法
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    // ⚠️ 防二次套壳死循环保护标记
    if ([rawScreenshot.accessibilityIdentifier isEqualToString:@"ScreenshotShell_Done"]) {
        return rawScreenshot;
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
        
        // 1. 获取原图真实的像素尺寸（这是最重要的基准，保持它，系统绝不裁剪！）
        CGFloat rawW = rawScreenshot.size.width * rawScreenshot.scale;
        CGFloat rawH = rawScreenshot.size.height * rawScreenshot.scale;
        
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        
        CGFloat ltx = [cfg[@"left_top_x"] floatValue];
        CGFloat lty = [cfg[@"left_top_y"] floatValue];
        CGFloat rtx = [cfg[@"right_top_x"] floatValue];
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue];
        
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        if (innerW <= 0 || innerH <= 0) return rawScreenshot;

        // 2. ⚠️ 终极算法：倒推外壳缩放比例。
        // 我们强行把透明窟窿对准截图！用 截图尺寸 ÷ CFG孔洞尺寸 = 外壳需要缩放的比例
        CGFloat scaleX = rawW / innerW;
        CGFloat scaleY = rawH / innerH;
        
        // 算出最终的整个带壳画布的大小
        CGFloat canvasW = templateW * scaleX;
        CGFloat canvasH = templateH * scaleY;
        
        // 算出截屏在这个画布上精准的(X,Y)偏移量
        CGFloat drawX = ltx * scaleX;
        CGFloat drawY = lty * scaleY;
        
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 原图像素: %.1f x %.1f", rawW, rawH);
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 动态画布: %.1f x %.1f", canvasW, canvasH);
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 精准合成坐标: X=%.1f, Y=%.1f", drawX, drawY);
        
        // 3. ⚠️ 绝对透明底色引擎 (参数 NO 为透明)
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvasW, canvasH), NO, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextClearRect(context, CGRectMake(0, 0, canvasW, canvasH));
        
        // 底层：画出截图（严丝合缝地画进倒推出来的空洞位置）
        [rawScreenshot drawInRect:CGRectMake(drawX, drawY, rawW, rawH)];
        
        // 顶层：铺满外壳（透明层会天然遮住多余区域）
        [shellImage drawInRect:CGRectMake(0, 0, canvasW, canvasH)];
        
        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (renderedImage && renderedImage.CGImage) {
            // 重新赋予原始高清比例和正确的方向
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:UIImageOrientationUp];
            // 打上烙印，防止重复套壳
            finalImage.accessibilityIdentifier = @"ScreenshotShell_Done";
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🎉 图片内存合成完毕！");
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// 源头拦截：用你最原本的方式修改系统界面
// --------------------------------------------------------
%group SourceSniperHook

%hook SSSScreenshotManager

- (id)createScreenshotWithEnvironmentDescription:(id)env {
    NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🚀 SSSScreenshotManager 被触发!");
    SSSScreenshot *screenshot = %orig(env);
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (screenshot && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [screenshot backingImage];
        if (rawImage) {
            UIImage *shelledImage = applyShellToScreenshot(rawImage);
            if (shelledImage && shelledImage != rawImage) {
                // 1. 替换 UI 的显示图片
                [screenshot setBackingImage:shelledImage];
                NSLog(@"[ScreenshotShell] :::::::::::::::::::: ✅ UI图片替换成功!");
                
                // 2. 摧毁硬件截图表面，逼系统使用我们的 backingImage 保存
                SSEnvironmentDescription *envDesc = [screenshot environmentDescription];
                if (envDesc) {
                    if ([envDesc respondsToSelector:@selector(setImageSurface:)]) [envDesc setImageSurface:nil];
                    if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) [envDesc setImagePixelSize:CGSizeMake(shelledImage.size.width * shelledImage.scale, shelledImage.size.height * shelledImage.scale)];
                    if ([envDesc respondsToSelector:@selector(setImageScale:)]) [envDesc setImageScale:1.0];
                }
            }
        }
    }
    return screenshot;
}

%end // SSSScreenshotManager

// --------------------------------------------------------
// 终极拦截：封堵苹果底层相册存入的所有退路 (取代你原来的双重保存)
// --------------------------------------------------------
%hook PHAssetCreationRequest

+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *shelled = applyShellToScreenshot(image);
        if (shelled && shelled != image) {
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: 📸 拦截成功：替换相册 UIImage 存入");
            return %orig(shelled);
        }
    }
    return %orig(image);
}

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (type == 1 && data && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    NSLog(@"[ScreenshotShell] :::::::::::::::::::: 📸 拦截成功：替换相册 NSData 存入");
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
                    // 原汁原味的狸猫换太子，这是在 SSS 沙盒中最绝对合法的路径
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                    tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                    [shelledData writeToFile:tempPath atomically:YES];
                    
                    NSURL *newURL = [NSURL fileURLWithPath:tempPath];
                    NSLog(@"[ScreenshotShell] :::::::::::::::::::: 📸 拦截成功：替换相册 FileURL 存入");
                    %orig(type, newURL, options);
                    return;
                }
            }
        }
    }
    %orig;
}

%end // PHAssetCreationRequest

%end // SourceSniperHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"] ||
        [bundleId isEqualToString:@"com.apple.springboard"]) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 💉 成功注入核心进程: %@", bundleId);
        %init(SourceSniperHook);
    }
}
