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

// 防沙盒读取失败判断
static BOOL isTweakEnabled() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    if (prefs && prefs[@"Enabled"] != nil) {
        return [prefs[@"Enabled"] boolValue];
    }
    return NO;
}

// --------------------------------------------------------
// 核心：绝对透明上下文 + 无黑边零边距渲染引擎
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    
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

    // 【内存防爆 + 完美去黑边算法】
    // 核心思路：让画布的“内框”大小正好等于截屏像素大小，然后反推整个套壳图片最终的物理大小。
    CGFloat rawPixelW = rawScreenshot.size.width * rawScreenshot.scale;
    CGFloat rawPixelH = rawScreenshot.size.height * rawScreenshot.scale;
    
    // 计算压缩比例：截屏实际像素 / CFG的内框原始像素
    CGFloat safeScale = rawPixelW / innerW;
    
    // 根据压缩比例，计算出最终无边距的画布大小 (正好包裹住壳，不多一丝一毫空白)
    CGFloat canvasW = templateW * safeScale;
    CGFloat canvasH = templateH * safeScale;
    
    // 计算截图应该画在画布上的准确坐标
    CGFloat drawX = ltx * safeScale;
    CGFloat drawY = lty * safeScale;
    
    UIImage *finalImage = nil;
    
    @autoreleasepool {
        // ⚠️ 重点修复：使用最古老、最稳定的图片渲染 API。参数 NO 代表绝对开启透明通道，彻底告别不透明边框！
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvasW, canvasH), NO, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        
        // 双重保险：强制清空画布底色
        CGContextClearRect(context, CGRectMake(0, 0, canvasW, canvasH));
        
        // 底层：画出截图 (强制填满对应的孔洞坐标)
        [rawScreenshot drawInRect:CGRectMake(drawX, drawY, rawPixelW, rawPixelH)];
        
        // 顶层：盖上手机壳 (铺满没有多余边缘的画布，透明镂空处自然透出截图)
        [shellImage drawInRect:CGRectMake(0, 0, canvasW, canvasH)];
        
        // 提取图片
        UIImage *renderedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (renderedImage && renderedImage.CGImage) {
            // 重新赋予原始 Retina 缩放倍率，保证清晰度
            finalImage = [UIImage imageWithCGImage:renderedImage.CGImage scale:rawScreenshot.scale orientation:rawScreenshot.imageOrientation];
        } else {
            finalImage = renderedImage;
        }
    }
    
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook 核心：UI 替换 + 退回原版经得起考验的 XPC 存图逻辑
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1. 替换左下角 UI 缩略图和编辑器
%hook SSSScreenshot
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelledImage = applyShellToScreenshot(image);
        if (shelledImage && shelledImage != image) {
            %orig(shelledImage);
            SSEnvironmentDescription *envDesc = [self environmentDescription];
            if (envDesc && [envDesc respondsToSelector:@selector(setImageSurface:)]) {
                // 重置原生裁剪框
                [envDesc setImageSurface:nil];
            }
            return;
        }
    }
    %orig(image);
}
%end

// 2. 底层相册存入接管
%hook PHAssetCreationRequest

- (void)addResourceWithType:(long long)type data:(NSData *)data options:(id)options {
    if (type == 1 && data && isTweakEnabled()) {
        UIImage *rawImage = [UIImage imageWithData:data];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    %orig(type, shelledData, options);
                    return;
                }
            }
        }
    }
    %orig;
}

- (void)addResourceWithType:(long long)type fileURL:(NSURL *)fileURL options:(id)options {
    if (type == 1 && fileURL && isTweakEnabled()) {
        UIImage *rawImage = [UIImage imageWithContentsOfFile:fileURL.path];
        if (rawImage) {
            UIImage *shelled = applyShellToScreenshot(rawImage);
            if (shelled && shelled != rawImage) {
                // 强制输出 PNG 以死死守住透明通道
                NSData *shelledData = UIImagePNGRepresentation(shelled);
                if (shelledData) {
                    // ⚠️ 极其关键：退回你第一版能成功运行的“生成临时文件”逻辑，这是满足 iOS 系统安全检查的唯一路径！
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                    tempPath = [tempPath stringByAppendingPathExtension:@"png"];
                    
                    if ([shelledData writeToFile:tempPath atomically:YES]) {
                        NSURL *newURL = [NSURL fileURLWithPath:tempPath];
                        %orig(type, newURL, options);
                        return;
                    }
                }
            }
        }
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
    // 精确覆盖截图服务和桌面保存进程
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"] ||
        [bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(ScreenshotCoreHook);
    }
}
