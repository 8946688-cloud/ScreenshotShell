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
    
    // 1. 读取配置
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (!prefs || ![prefs[@"Enabled"] boolValue]) {
        return rawScreenshot; // 未开启
    }
    
    // 2. 读取外壳图片
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) {
        return rawScreenshot; // 没有外壳图片
    }
    
    // 3. 读取坐标
    CGFloat rx = [prefs[@"RectX"] floatValue];
    CGFloat ry = [prefs[@"RectY"] floatValue];
    CGFloat rw = [prefs[@"RectW"] floatValue];
    CGFloat rh = [prefs[@"RectH"] floatValue];
    CGRect innerRect = CGRectMake(rx, ry, rw, rh);
    
    // 4. 开始合成
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
// Hook ScreenshotServicesService (控制悬浮窗及保存)
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

%end // ScreenshotServiceHook

// ============================================
// Hook SpringBoard (保险：某些版本在发往服务前就设置了)
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

%end // SpringBoardHook

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
