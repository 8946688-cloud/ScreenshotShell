#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

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
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@end

// --------------------------------------------------------
// 路径辅助 (完全恢复为你最初的要求)
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
// 核心：读取 JSON cfg 并合成图片
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot; 
    
    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot; 
    
    NSError *error;
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:&error];
    if (!cfg || error) return rawScreenshot;
    
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
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// 核心：将【套壳后】的图片静默保存到系统相册
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
// Hook ScreenshotServicesService
// --------------------------------------------------------
%group ScreenshotServiceHook

%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            
            // 1. 静默保存【套壳后的图片】到相册
            saveShelledScreenshotToPhotos(shelledImage);
            
            // 2. 核心破解：粉碎底层的原图缓存，逼迫系统展示套壳图
            SSEnvironmentDescription *env = [self environmentDescription];
            if (env) {
                if ([env respondsToSelector:@selector(setImageSurface:)]) {
                    [env setImageSurface:nil];
                }
                if ([env respondsToSelector:@selector(setImagePixelSize:)]) {
                    [env setImagePixelSize:shelledImage.size];
                }
                if ([env respondsToSelector:@selector(setImageScale:)]) {
                    [env setImageScale:shelledImage.scale];
                }
            }
            
            %orig(shelledImage);
            return;
        }
    }
    %orig(image);
}
%end

%end // ScreenshotServiceHook

// --------------------------------------------------------
// 保底 Hook SpringBoard
// --------------------------------------------------------
%group SpringBoardHook

%hook SSUIShowScreenshotUIWithImageServiceRequest
- (void)setImage:(UIImage *)image {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (image && prefs && [prefs[@"Enabled"] boolValue]) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            // SpringBoard 层也触发相册保存
            saveShelledScreenshotToPhotos(shelledImage);
            %orig(shelledImage);
            return;
        }
    }
    %orig(image);
}
%end

%end // SpringBoardHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotServiceHook);
    } else if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardHook);
    }
}
