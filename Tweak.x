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
// 核心：合成套壳图 (防 OOM 内存爆炸版 + 像素级精准映射)
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    __block UIImage *finalImage = nil;
    
    // ⚠️ 核心优化 1：使用自动释放池，图片一旦处理完，瞬间清空几十MB内存，防止设备卡顿被杀！
    @autoreleasepool {
        NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
        UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
        if (!shellImage) return rawScreenshot; 
        
        NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
        NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
        if (!cfgData) return rawScreenshot; 
        
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:nil];
        if (!cfg) return rawScreenshot;
        
        CGFloat leftTopX = [cfg[@"left_top_x"] floatValue];
        CGFloat leftTopY = [cfg[@"left_top_y"] floatValue];
        CGFloat rightTopX = [cfg[@"right_top_x"] floatValue];
        CGFloat leftBottomY = [cfg[@"left_bottom_y"] floatValue];
        
        CGFloat rawW = rightTopX - leftTopX;
        CGFloat rawH = leftBottomY - leftTopY;
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        
        // ⚠️ 核心优化 2：强制读取底层 CGImage 的真实像素大小，无视苹果的 @2x/@3x 机制！
        // 这样计算出的比例和坐标才是 100% 吻合 CFG 文件的。
        CGFloat pixelW = CGImageGetWidth(shellImage.CGImage);
        CGFloat pixelH = CGImageGetHeight(shellImage.CGImage);
        
        CGFloat scaleX = (templateW > 0) ? (pixelW / templateW) : 1.0;
        CGFloat scaleY = (templateH > 0) ? (pixelH / templateH) : 1.0;
        
        CGRect innerRect = CGRectMake(leftTopX * scaleX, leftTopY * scaleY, rawW * scaleX, rawH * scaleY);
        
        // ⚠️ 核心优化 3：使用现代的 Renderer API
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            // 🚨 致命关键点：强制比例为 1.0！绝对不能用默认的设备比例，否则大图直接引发系统内存 700MB 崩溃！
            format.scale = 1.0; 
            format.opaque = NO; // 保留透明通道
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pixelW, pixelH) format:format];
            
            finalImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                // 底层：画出原始截图（正好填满壳子的透明窟窿）
                [rawScreenshot drawInRect:innerRect];
                // 顶层：盖上手机壳（遮住截图中多余的部分和四角，展现边框）
                [shellImage drawInRect:CGRectMake(0, 0, pixelW, pixelH)];
            }];
        }
    }
    
    return finalImage ?: rawScreenshot;
}


// --------------------------------------------------------
// 拦截相册的保存请求 (双保险)
// --------------------------------------------------------
%group PhotoSaveHook

// 拦截现代 iOS 通过内存 UIImage 直接写入相册的动作
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

// 拦截 iOS 先写入临时文件，再存入相册的动作
+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)fileURL {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        UIImage *shelled = applyShellToScreenshot(rawImage);
        if (shelled && shelled != rawImage) {
            // 将文件写入流劫持，改为直接写入合成好的内存图片，确保透明和套壳生效
            return [self creationRequestForAssetFromImage:shelled];
        }
    }
    return %orig(fileURL);
}
%end

%end // PhotoSaveHook

// --------------------------------------------------------
// 源头狙击钩子：控制悬浮窗 UI
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
                // 1. 将套壳图塞回服务，悬浮窗立刻变样
                [screenshot setBackingImage:shelledImage];
                
                // 2. 粉碎硬件缓存，逼迫系统展示并编辑我们的套壳图
                SSEnvironmentDescription *envDesc = [screenshot environmentDescription];
                if (envDesc) {
                    if ([envDesc respondsToSelector:@selector(setImageSurface:)]) {
                        [envDesc setImageSurface:nil];
                    }
                    if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) {
                        [envDesc setImagePixelSize:shelledImage.size];
                    }
                    if ([envDesc respondsToSelector:@selector(setImageScale:)]) {
                        // 配合上方的强制 1.0 缩放，骗过系统编辑器
                        [envDesc setImageScale:1.0];
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
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    // ScreenshotServicesService 专门负责所有的截图后续流程和保存
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotUIHook);
        %init(PhotoSaveHook);
    }
}
