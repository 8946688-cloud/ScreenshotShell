#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ============================================
// 1. 补齐私有头文件声明 (基于你提供的 dump)
// ============================================
@interface SSEnvironmentDescription : NSObject
@property (nonatomic) CGSize imagePixelSize;
@property (nonatomic) double imageScale;
- (void)setImageSurface:(id)surface; // 核心：用来破坏硬件缓存
@end

@interface SSSScreenshot : NSObject
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@end

// ============================================
// 2. 路径辅助与配置读取
// ============================================
static NSString * GetSharedSupportDir() {
    NSString *base = @"/Library/Application Support/ScreenshotShell";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

// 安全读取总开关
static BOOL isTweakEnabled() {
    CFStringRef appID = CFSTR("com.iosdump.screenshotshell");
    CFPreferencesAppSynchronize(appID);
    Boolean valid = NO;
    BOOL enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &valid);
    return valid ? enabled : NO;
}

// ============================================
// 3. 核心合成逻辑 (使用 CFG 计算坐标与缩放)
// ============================================
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    // 读取素材
    NSString *shellPath = [GetSharedSupportDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot; 
    
    // 读取 CFG
    NSString *cfgPath = [GetSharedSupportDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot; 
    
    NSError *error;
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:&error];
    if (!cfg || error) return rawScreenshot;
    
    // 解析坐标
    CGFloat leftTopX = [cfg[@"left_top_x"] floatValue];
    CGFloat leftTopY = [cfg[@"left_top_y"] floatValue];
    CGFloat rightTopX = [cfg[@"right_top_x"] floatValue];
    CGFloat leftBottomY = [cfg[@"left_bottom_y"] floatValue];
    
    CGFloat rawW = rightTopX - leftTopX;
    CGFloat rawH = leftBottomY - leftTopY;
    
    CGFloat templateW = [cfg[@"template_width"] floatValue];
    CGFloat templateH = [cfg[@"template_height"] floatValue];
    
    // 计算缩放比例 (以防外壳 png 的实际分辨率与 cfg 中定义的不一致)
    CGFloat scaleX = (templateW > 0) ? (shellImage.size.width / templateW) : 1.0;
    CGFloat scaleY = (templateH > 0) ? (shellImage.size.height / templateH) : 1.0;
    
    CGRect innerRect = CGRectMake(leftTopX * scaleX, 
                                  leftTopY * scaleY, 
                                  rawW * scaleX, 
                                  rawH * scaleY);
    
    // 开始绘制
    UIGraphicsBeginImageContextWithOptions(shellImage.size, NO, 0.0);
    [rawScreenshot drawInRect:innerRect];
    [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return finalImage ?: rawScreenshot;
}

// ============================================
// 4. Hook 截图服务 (基于最新的头文件机制)
// ============================================
%group ScreenshotServiceHook

%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        
        // 可选：静默保存不带壳的原图到相册（如有需要，解开下行注释）
        // UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            
            // 🚨 核心破解步骤：获取环境对象
            SSEnvironmentDescription *env = [self environmentDescription];
            
            if (env) {
                // 1. 抹除硬件层面的截图缓存，逼迫系统使用我们的 UIImage
                if ([env respondsToSelector:@selector(setImageSurface:)]) {
                    [env setImageSurface:nil];
                }
                
                // 2. 修正悬浮窗/编辑器里的画布尺寸，防止套壳图被拉伸或裁剪
                if ([env respondsToSelector:@selector(setImagePixelSize:)]) {
                    [env setImagePixelSize:shelledImage.size];
                }
                if ([env respondsToSelector:@selector(setImageScale:)]) {
                    [env setImageScale:shelledImage.scale];
                }
            }
            
            // 最终将套好壳的图片交给系统
            %orig(shelledImage);
            return;
        }
    }
    
    %orig(image);
}
%end

%end // ScreenshotServiceHook

// ============================================
// 5. 保底：Hook SpringBoard (处理 iOS 某些边缘触发情况)
// ============================================
%group SpringBoardHook
%hook SSUIShowScreenshotUIWithImageServiceRequest
- (void)setImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage) {
            %orig(shelledImage);
            return;
        }
    }
    %orig(image);
}
%end
%end // SpringBoardHook

// ============================================
// 6. 构造入口
// ============================================
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotServiceHook);
    } else if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardHook);
    }
}
