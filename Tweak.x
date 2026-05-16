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
// 独立保存方法 (⚠️已修复透明通道丢失问题)
// --------------------------------------------------------
static void saveShelledScreenshotToPhotos(UIImage *shelledImage) {
    if (!shelledImage) return;
    
    // ⚠️ 极其关键：必须转成 PNG Data 才能保住透明通道，直接存 UIImage 会被系统强转为不透明的 JPG！
    NSData *pngData = UIImagePNGRepresentation(shelledImage);
    if (!pngData) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ❌ 失败：PNG 转换失败");
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            // 改为通过 Data 创建资源库对象，完美保留 PNG 透明度
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto data:pngData options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            if (success) {
                NSLog(@"[ScreenshotShell] :::::::::::::::::::: 💾 成功：透明 PNG 套壳图已保存到相册！");
            } else {
                NSLog(@"[ScreenshotShell] :::::::::::::::::::: ❌ 失败：相册保存报错 -> %@", error);
            }
        }];
    });
}

// --------------------------------------------------------
// 核心：合成套壳图 (⚠️已修复截图不见了的问题)
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
        
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        if (templateW <= 0 || templateH <= 0) return rawScreenshot;
        
        CGFloat pixelW = shellImage.size.width;
        CGFloat pixelH = shellImage.size.height;
        
        CGFloat scaleX = pixelW / templateW;
        CGFloat scaleY = pixelH / templateH;
        
        // 提取 4 个点
        CGFloat ltx = [cfg[@"left_top_x"] floatValue];
        CGFloat lty = [cfg[@"left_top_y"] floatValue];
        CGFloat rtx = [cfg[@"right_top_x"] floatValue];
        CGFloat rty = [cfg[@"right_top_y"] floatValue];
        CGFloat lbx = [cfg[@"left_bottom_x"] floatValue];
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue];
        CGFloat rbx = [cfg[@"right_bottom_x"] floatValue];
        CGFloat rby = [cfg[@"right_bottom_y"] floatValue];
        
        // 核心算法：计算最大外接矩形 (Bounding Box)
        CGFloat minX = MIN(ltx, lbx) * scaleX;
        CGFloat minY = MIN(lty, rty) * scaleY;
        CGFloat maxX = MAX(rtx, rbx) * scaleX;
        CGFloat maxY = MAX(lby, rby) * scaleY;
        
        CGRect innerRect = CGRectMake(minX, minY, maxX - minX, maxY - minY);
        
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 原图大小: %.1f x %.1f", rawScreenshot.size.width, rawScreenshot.size.height);
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 画布大小: %.1f x %.1f", pixelW, pixelH);
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚙️ 截图将画在: %@", NSStringFromCGRect(innerRect));
        
        // ⚠️ 极其关键修复：废弃 Renderer，改用最稳定的上下文引擎
        // 参数 NO 表示透明背景，1.0 比例防内存爆炸
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(pixelW, pixelH), NO, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextClearRect(context, CGRectMake(0, 0, pixelW, pixelH)); // 清空画布底色
        
        // 底层：画出截图 (drawInRect会自动纠正截图原本乱七八糟的朝向)
        [rawScreenshot drawInRect:innerRect];
        
        // 顶层：盖上手机壳
        [shellImage drawInRect:CGRectMake(0, 0, pixelW, pixelH)];
        
        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (renderedImage && renderedImage.CGImage) {
            // ⚠️ 极其关键修复2：Orientation 必须强锁 UIImageOrientationUp，否则图片会在后台被双重旋转抛出屏幕外！
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:UIImageOrientationUp];
        } else {
            finalImage = renderedImage;
        }
    }
    
    if (finalImage) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🎉 图片内存合成完毕！");
    }
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// 源头狙击钩子：SSSScreenshotManager
// --------------------------------------------------------
%group SourceSniperHook

%hook SSSScreenshotManager

- (id)createScreenshotWithEnvironmentDescription:(id)env {
    NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🚀 触发拦截：接收到截图环境包!");
    
    SSSScreenshot *screenshot = %orig(env);
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (screenshot && prefs && [prefs[@"Enabled"] boolValue]) {
        
        UIImage *rawImage = [screenshot backingImage];
        if (rawImage) {
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: 🔍 成功提取出原图，准备套壳...");
            UIImage *shelledImage = applyShellToScreenshot(rawImage);
            
            if (shelledImage && shelledImage != rawImage) {
                // 1. 将套壳图塞回服务
                [screenshot setBackingImage:shelledImage];
                NSLog(@"[ScreenshotShell] :::::::::::::::::::: ✅ 已替换系统截图对象！");
                
                // 2. 独立保存到相册 (抢在系统前面)
                saveShelledScreenshotToPhotos(shelledImage);
                
                // 3. 粉碎硬件缓存
                SSEnvironmentDescription *envDesc = [screenshot environmentDescription];
                if (envDesc) {
                    if ([envDesc respondsToSelector:@selector(setImageSurface:)]) {
                        [envDesc setImageSurface:nil];
                        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 💥 已粉碎 IOSurface！");
                    }
                    if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) {
                        [envDesc setImagePixelSize:shelledImage.size];
                    }
                    if ([envDesc respondsToSelector:@selector(setImageScale:)]) {
                        [envDesc setImageScale:1.0];
                    }
                }
            }
        } else {
            NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚠️ 原图为空，可能还未生成 backingImage");
        }
    } else {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: ⚠️ 插件未开启或配置无效");
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
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        NSLog(@"[ScreenshotShell] :::::::::::::::::::: 💉 成功注入进程: %@", bundleId);
        %init(SourceSniperHook);
    }
}
