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
// 独立保存方法
// --------------------------------------------------------
static void saveShelledScreenshotToPhotos(UIImage *shelledImage) {
    if (!shelledImage) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:shelledImage];
        } completionHandler:nil];
    });
}

// --------------------------------------------------------
// 核心：合成套壳图 (防 OOM 内存泄漏版)
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    __block UIImage *finalImage = nil;
    
    // ⚠️ 核心修复 1：使用自动释放池，图片一旦处理完，瞬间清空几百MB内存，防止 SB 被杀！
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
        
        CGFloat scaleX = (templateW > 0) ? (shellImage.size.width / templateW) : 1.0;
        CGFloat scaleY = (templateH > 0) ? (shellImage.size.height / templateH) : 1.0;
        
        CGRect innerRect = CGRectMake(leftTopX * scaleX, leftTopY * scaleY, rawW * scaleX, rawH * scaleY);
        
        // ⚠️ 核心修复 2：使用现代的 UIGraphicsImageRenderer 替代老旧接口
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            // 🚨 致命关键点：强制比例为 1.0！绝对不能用默认的设备比例，否则大图直接引发系统内存崩溃！
            format.scale = 1.0;
            format.opaque = NO;
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:shellImage.size format:format];
            
            finalImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                
                // ⚠️ 核心修复 3：图层绘制顺序
                // 【正常模式】：原图在底层，外壳在顶层盖住。(要求你导入的 shell.png 中间手机屏幕区域必须是透明镂空的)
                [rawScreenshot drawInRect:innerRect];
                [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
                
                // ---------------------------------------------------------
                // 💡 【防瞎眼模式】：如果你发现截图始终被外壳盖住看不见，说明你的外壳图片中间是白底（失去了透明度）。
                // 解决办法：注释掉上面的两行代码，解开下面这两行代码的注释 (把截图强行画在外壳的上面)：
                // 
                // [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
                // [rawScreenshot drawInRect:innerRect];
                // ---------------------------------------------------------
            }];
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// 源头狙击钩子：SSSScreenshotManager
// --------------------------------------------------------
%group SourceSniperHook

%hook SSSScreenshotManager

- (id)createScreenshotWithEnvironmentDescription:(id)env {
    SSSScreenshot *screenshot = %orig(env);
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (screenshot && prefs && [prefs[@"Enabled"] boolValue]) {
        
        UIImage *rawImage = [screenshot backingImage];
        
        if (rawImage) {
            UIImage *shelledImage = applyShellToScreenshot(rawImage);
            
            if (shelledImage && shelledImage != rawImage) {
                // 1. 将套壳图塞回服务
                [screenshot setBackingImage:shelledImage];
                
                // 2. 独立保存到相册
                saveShelledScreenshotToPhotos(shelledImage);
                
                // 3. 粉碎硬件缓存
                SSEnvironmentDescription *envDesc = [screenshot environmentDescription];
                if (envDesc) {
                    if ([envDesc respondsToSelector:@selector(setImageSurface:)]) {
                        [envDesc setImageSurface:nil];
                    }
                    if ([envDesc respondsToSelector:@selector(setImagePixelSize:)]) {
                        [envDesc setImagePixelSize:shelledImage.size];
                    }
                    if ([envDesc respondsToSelector:@selector(setImageScale:)]) {
                        // 配合上方的强制 1.0 缩放，这里也要同步骗过系统
                        [envDesc setImageScale:1.0];
                    }
                }
            }
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
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(SourceSniperHook);
    }
}
