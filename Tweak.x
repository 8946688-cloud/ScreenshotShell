#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ========== 路径辅助 ==========
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

// ========== 核心合成函数 ==========
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
    // 1. 读取总开关配置
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (!prefs || ![prefs[@"Enabled"] boolValue]) {
        return rawScreenshot;
    }
    
    // 2. 读取外壳图片
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) {
        return rawScreenshot;
    }
    
    // 3. 读取配置文件 (JSON格式)
    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) {
        return rawScreenshot;
    }
    
    NSError *error;
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:&error];
    if (!cfg || error) {
        return rawScreenshot;
    }
    
    // 4. 解析坐标
    CGFloat leftTopX = [cfg[@"left_top_x"] floatValue];
    CGFloat leftTopY = [cfg[@"left_top_y"] floatValue];
    CGFloat rightTopX = [cfg[@"right_top_x"] floatValue];
    CGFloat leftBottomY = [cfg[@"left_bottom_y"] floatValue];
    
    CGFloat rawW = rightTopX - leftTopX;
    CGFloat rawH = leftBottomY - leftTopY;
    
    // 5. 动态比例换算 (适配外壳图片的实际分辨率)
    CGFloat templateW = [cfg[@"template_width"] floatValue];
    CGFloat templateH = [cfg[@"template_height"] floatValue];
    
    CGFloat scaleX = (templateW > 0) ? (shellImage.size.width / templateW) : 1.0;
    CGFloat scaleY = (templateH > 0) ? (shellImage.size.height / templateH) : 1.0;
    
    // 最终截图需要绘制的内部区域
    CGRect innerRect = CGRectMake(leftTopX * scaleX, 
                                  leftTopY * scaleY, 
                                  rawW * scaleX, 
                                  rawH * scaleY);
    
    // 6. 开始合成
    UIGraphicsBeginImageContextWithOptions(shellImage.size, NO, 0.0);
    
    // 底层画原始截图
    [rawScreenshot drawInRect:innerRect];
    // 顶层画透明外壳
    [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
    
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return finalImage ?: rawScreenshot;
}

// ========== 静默保存原图 ==========
static void saveRawScreenshotToPhotos(UIImage *rawImage) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (!prefs || ![prefs[@"Enabled"] boolValue]) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:rawImage];
        } completionHandler:nil];
    });
}

// ============================================
// Hook ScreenshotServicesService
// ============================================
%group ScreenshotServiceHook
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image) {
        saveRawScreenshotToPhotos(image);
        UIImage *shelledImage = applyShellToScreenshot(image);
        %orig(shelledImage);
    } else {
        %orig(image);
    }
}
%end
%end

// ============================================
// Hook SpringBoard
// ============================================
%group SpringBoardHook
%hook SSUIShowScreenshotUIWithImageServiceRequest
- (void)setImage:(UIImage *)image {
    if (image) {
        saveRawScreenshotToPhotos(image);
        UIImage *shelledImage = applyShellToScreenshot(image);
        %orig(shelledImage);
    } else {
        %orig(image);
    }
}
%end
%end

// ============================================
// 构造入口，分配进程
// ============================================
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"]) {
        %init(ScreenshotServiceHook);
    } else if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardHook);
    }
}
