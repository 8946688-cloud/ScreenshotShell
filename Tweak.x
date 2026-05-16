#import <UIKit/UIKit.h>
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
// 用 screenshot 对象本身存“原图”，避免 UIImage 重建后标记丢失
// --------------------------------------------------------
static const void *kRawImageKey = &kRawImageKey;

static UIImage *GetRawImage(id screenshot) {
    return objc_getAssociatedObject(screenshot, kRawImageKey);
}

static void SetRawImage(id screenshot, UIImage *image) {
    if (screenshot) {
        objc_setAssociatedObject(screenshot, kRawImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// --------------------------------------------------------
// 读取壳图 / cfg
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
// 核心：只套一次壳
// - 原图永远不变
// - 输出图才套壳
// --------------------------------------------------------
static UIImage *ApplyShellToRawImage(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;

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

    // 先把原截图放进洞里
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];

    // 再盖壳，壳尺寸固定
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    UIImage *finalImage = [UIImage imageWithCGImage:rendered.CGImage
                                               scale:1.0
                                         orientation:UIImageOrientationUp];
    return finalImage ?: rawScreenshot;
}

// --------------------------------------------------------
// Hook
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

// 只保存原图，不在这里套壳
- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        SetRawImage(self, image);
    }
    %orig(image);
}

// 输出给 UI / 保存的关键点：这里再套壳
- (void)requestImageInTransition:(BOOL)transition withBlock:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(transition, block);
        return;
    }

    UIImage *raw = GetRawImage(self);

    void (^origBlock)(id) = [block copy];
    void (^wrappedBlock)(id) = ^(id image) {
        UIImage *source = nil;

        // 优先用我们保存的原图，避免对已经套过壳的图再次加工
        if (raw && [raw isKindOfClass:[UIImage class]]) {
            source = raw;
        } else if ([image isKindOfClass:[UIImage class]]) {
            source = (UIImage *)image;
        }

        if (source) {
            UIImage *shelled = ApplyShellToRawImage(source);
            origBlock(shelled ?: source);
        } else {
            origBlock(image);
        }
    };

    %orig(transition, wrappedBlock);
}

// 保存数据的地方也套壳
- (NSData *)imageModificationData {
    NSData *data = %orig;
    if (!data || !isTweakEnabled()) return data;

    UIImage *raw = GetRawImage(self);
    if (!raw) {
        raw = [UIImage imageWithData:data];
    }
    if (!raw) return data;

    UIImage *shelled = ApplyShellToRawImage(raw);
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
