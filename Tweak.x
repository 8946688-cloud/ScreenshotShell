#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// --------------------------------------------------------
// 声明私有头文件 (匹配 iOS 14-17)
// --------------------------------------------------------
@interface SSEnvironmentDescription : NSObject
- (void)setImageSurface:(id)surface; 
@end

@interface SSSScreenshot : NSObject
@property (retain, nonatomic) UIImage *backingImage;
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@end

// --------------------------------------------------------
// 路径辅助与偏好设置获取
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

static BOOL isTweakEnabled() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && prefs[@"Enabled"] != nil) {
        return [prefs[@"Enabled"] boolValue];
    }
    return NO;
}

// --------------------------------------------------------
// 核心：强制透明画布 + 内存防爆缩放算法
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    __block UIImage *finalImage = nil;
    
    @autoreleasepool {
        NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
        UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
        if (!shellImage) return rawScreenshot; 
        
        NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
        NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
        if (!cfgData) return rawScreenshot; 
        
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:kNilOptions error:nil];
        if (!cfg) return rawScreenshot;
        
        CGFloat templateW = [cfg[@"template_width"] floatValue];
        CGFloat templateH = [cfg[@"template_height"] floatValue];
        
        if (templateW <= 0 || templateH <= 0) {
            templateW = shellImage.size.width * shellImage.scale;
            templateH = shellImage.size.height * shellImage.scale;
        }
        
        CGFloat ltx = [cfg[@"left_top_x"] floatValue];
        CGFloat lty = [cfg[@"left_top_y"] floatValue];
        CGFloat rtx = [cfg[@"right_top_x"] floatValue];
        CGFloat lby = [cfg[@"left_bottom_y"] floatValue];
        
        CGFloat innerW = rtx - ltx;
        CGFloat innerH = lby - lty;
        if (innerW <= 0 || innerH <= 0) return rawScreenshot;

        // 【内存防爆 + 完美对齐】根据真实截图尺寸等比缩放整个画布
        CGFloat rawPixelW = rawScreenshot.size.width * rawScreenshot.scale;
        CGFloat safeScale = rawPixelW / innerW;
        
        CGFloat safeCanvasW = templateW * safeScale;
        CGFloat safeCanvasH = templateH * safeScale;
        CGFloat safeLtx = ltx * safeScale;
        CGFloat safeLty = lty * safeScale;
        CGFloat safeInnerW = innerW * safeScale;
        CGFloat safeInnerH = innerH * safeScale;
        
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = 1.0; 
            format.opaque = NO; // 开启透明通道
            
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(safeCanvasW, safeCanvasH) format:format];
            
            UIImage *renderedImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                // ⚠️ 重点修复：强制擦除整个画布，消除底层系统的黑底/白底，还你完美的 PNG 透明！
                CGContextClearRect(context.CGContext, CGRectMake(0, 0, safeCanvasW, safeCanvasH));
                
                // 底层：塞入原图
                [rawScreenshot drawInRect:CGRectMake(safeLtx, safeLty, safeInnerW, safeInnerH)];
                // 顶层：覆盖带有透明窟窿的手机壳
                [shellImage drawInRect:CGRectMake(0, 0, safeCanvasW, safeCanvasH)];
            }];
            
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
        }
    }
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：UI 替换 + 相册底层沙盒穿透
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 替换左下角悬浮窗和编辑器内的 UI 显示
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            %orig(shelledImage);
            SSEnvironmentDescription *envDesc = [self environmentDescription];
            if (envDesc && [envDesc respondsToSelector:@selector(setImageSurface:)]) {
                // 重置原生的剪裁框
                [envDesc setImageSurface:nil];
            }
            return;
        }
    }
    %orig(image);
}
%end

// 2. 彻底接管底层相册写入 (带防循环保护和沙盒穿透)
%hook PHAssetCreationRequest

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    NSMutableDictionary *threadDict = [[NSThread currentThread] threadDictionary];
    // 拦截标志，防止发生无限循环调用
    if (type == 1 && data && isTweakEnabled() && ![threadDict objectForKey:@"ScreenshotShell_Processing"]) {
        [threadDict setObject:@YES forKey:@"ScreenshotShell_Processing"];
        
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                // 强制输出为 PNG 以保留透明通道
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    %orig(type, shelledData, options);
                    [threadDict removeObjectForKey:@"ScreenshotShell_Processing"];
                    return;
                }
            }
        }
        [threadDict removeObjectForKey:@"ScreenshotShell_Processing"];
    }
    %orig;
}

- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    NSMutableDictionary *threadDict = [[NSThread currentThread] threadDictionary];
    if (type == 1 && fileURL && isTweakEnabled() && ![threadDict objectForKey:@"ScreenshotShell_Processing"]) {
        [threadDict setObject:@YES forKey:@"ScreenshotShell_Processing"];
        
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    // ⚠️ 极其关键【沙盒穿透】：
                    // 我们放弃往 fileURL 写入文件（因为没权限），而是直接调用当前对象的 data 保存方法！
                    // 这绕过了所有的文件沙盒锁，直接把带壳 PNG 数据塞进了相册！
                    [self addResourceWithType:type data:shelledData options:options];
                    [threadDict removeObjectForKey:@"ScreenshotShell_Processing"];
                    return;
                }
            }
        }
        [threadDict removeObjectForKey:@"ScreenshotShell_Processing"];
    }
    %orig;
}
%end // PHAssetCreationRequest
%end // ScreenshotCoreHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    // 精准注入负责处理截图和相册保存的两个核心进程
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"] ||
        [bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(ScreenshotCoreHook);
    }
}
