#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// --------------------------------------------------------
// 私有头文件
// --------------------------------------------------------
@interface SSEnvironmentDescription : NSObject
- (void)setImageSurface:(id)surface;
@end

@interface SSSScreenshot : NSObject
@property (retain, nonatomic) UIImage *backingImage;
@property (readonly, nonatomic) SSEnvironmentDescription *environmentDescription;
@property (readonly, nonatomic) NSData *imageModificationData;
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block;
@end

// --------------------------------------------------------
// 路径与配置
// --------------------------------------------------------
static NSString *GetPrefDir(void) {
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

static NSString *GetPlistPath(void) {
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

static BOOL isTweakEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPlistPath()];
    return prefs ? [prefs[@"Enabled"] boolValue] : NO;
}

// --------------------------------------------------------
// 防重复套壳
// --------------------------------------------------------
static const void *kShellAppliedKey = &kShellAppliedKey;

static BOOL ImageAlreadyShelled(UIImage *image) {
    if (!image) return NO;
    NSNumber *flag = objc_getAssociatedObject(image, kShellAppliedKey);
    return [flag boolValue];
}

static UIImage *MarkImageShelled(UIImage *image) {
    if (image) {
        objc_setAssociatedObject(image, kShellAppliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return image;
}

// --------------------------------------------------------
// 读取 shell / cfg
// --------------------------------------------------------
static UIImage *LoadShellImage(void) {
    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    return [UIImage imageWithContentsOfFile:shellPath];
}

static NSDictionary *LoadConfig(void) {
    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    return (NSDictionary *)json;
}

// --------------------------------------------------------
// 核心：按 cfg 把截图放进壳里
// 重点：最终输出尺寸固定用 template_width/template_height
// 壳不跟着截图编辑动作变化
// --------------------------------------------------------
static UIImage *ApplyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    if (ImageAlreadyShelled(rawScreenshot)) return rawScreenshot;

    UIImage *shellImage = LoadShellImage();
    if (!shellImage) return rawScreenshot;

    NSDictionary *cfg = LoadConfig();
    if (!cfg) return rawScreenshot;

    CGFloat templateW = [cfg[@"template_width"] doubleValue];
    CGFloat templateH = [cfg[@"template_height"] doubleValue];
    if (templateW <= 0 || templateH <= 0) return rawScreenshot;

    CGFloat ltx = [cfg[@"left_top_x"] doubleValue];
    CGFloat lty = [cfg[@"left_top_y"] doubleValue];
    CGFloat rtx = [cfg[@"right_top_x"] doubleValue];
    CGFloat lby = [cfg[@"left_bottom_y"] doubleValue];

    CGFloat holeW = rtx - ltx;
    CGFloat holeH = lby - lty;
    if (holeW <= 0 || holeH <= 0) return rawScreenshot;

    CGSize outSize = CGSizeMake(templateW, templateH);

    UIGraphicsBeginImageContextWithOptions(outSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, outSize.width, outSize.height));
    }

    // 先把原截图铺到洞里
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];

    // 再把壳盖上去，壳尺寸永远固定为 template 尺寸
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    UIImage *finalImage = [UIImage imageWithCGImage:rendered.CGImage
                                               scale:1.0
                                         orientation:UIImageOrientationUp];
    return MarkImageShelled(finalImage);
}

// --------------------------------------------------------
// Hook
// --------------------------------------------------------
%group ScreenshotCoreHook

// 1) 输出图路径之一：请求给 UI / 保存的图
%hook SSSScreenshot

- (UIImage *)backingImage {
    UIImage *img = %orig;
    if (!img || !isTweakEnabled()) return img;

    UIImage *shelled = ApplyShellToScreenshot(img);
    return shelled ?: img;
}

// 2) 这条通常是关键输出链路：不要改模型，只包 block 的输出
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            UIImage *shelled = ApplyShellToScreenshot((UIImage *)image);
            origBlock(shelled ?: image);
        } else {
            origBlock(image);
        }
    };

    %orig(transition, wrappedBlock);
}

// 3) 很多保存流程会走这个，直接返回带壳的图片数据
- (NSData *)imageModificationData {
    NSData *data = %orig;
    if (!data || !isTweakEnabled()) return data;

    UIImage *img = [UIImage imageWithData:data];
    if (!img) return data;

    UIImage *shelled = ApplyShellToScreenshot(img);
    if (!shelled) return data;

    NSData *png = UIImagePNGRepresentation(shelled);
    return png ?: data;
}

%end

%end // ScreenshotCoreHook

// --------------------------------------------------------
// 构造入口
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"] ||
        [bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(ScreenshotCoreHook);
    }
}
