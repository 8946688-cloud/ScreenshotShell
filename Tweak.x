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
@end

@interface SSSScreenshotImageProvider : NSObject
@property (nonatomic, weak) SSSScreenshot *screenshot;
- (id)requestOutputImageForSavingBlocking;
- (id)requestOutputImageForUIBlocking;
- (void)requestOutputImageForSaving:(id)block;
- (void)requestOutputImageForUI:(id)block;
@end

// --------------------------------------------------------
// 路径
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
    return prefs ? [prefs[@"Enabled"] boolValue] : NO;
}

// --------------------------------------------------------
// 防止重复套壳
// --------------------------------------------------------
static char kShellAppliedKey;

static BOOL IsShellApplied(UIImage *image) {
    if (!image) return NO;
    NSNumber *flag = objc_getAssociatedObject(image, &kShellAppliedKey);
    return [flag boolValue];
}

static UIImage *MarkShellApplied(UIImage *image) {
    if (image) {
        objc_setAssociatedObject(image, &kShellAppliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return image;
}

// --------------------------------------------------------
// 核心：按 cfg 把原图塞进壳里，输出尺寸保持为 template 尺寸
// --------------------------------------------------------
static UIImage* applyShellToScreenshot(UIImage *rawScreenshot) {
    if (!rawScreenshot) return nil;
    if (IsShellApplied(rawScreenshot)) return rawScreenshot;

    NSString *shellPath = [GetPrefDir() stringByAppendingPathComponent:@"shell.png"];
    UIImage *shellImage = [UIImage imageWithContentsOfFile:shellPath];
    if (!shellImage) return rawScreenshot;

    NSString *cfgPath = [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"];
    NSData *cfgData = [NSData dataWithContentsOfFile:cfgPath];
    if (!cfgData) return rawScreenshot;

    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return rawScreenshot;

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

    // 先画截图到洞里
    [rawScreenshot drawInRect:CGRectMake(ltx, lty, holeW, holeH)];

    // 再盖壳，壳尺寸固定为 template 尺寸
    [shellImage drawInRect:CGRectMake(0, 0, outSize.width, outSize.height)];

    UIImage *rendered = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!rendered) return rawScreenshot;

    UIImage *finalImage = [UIImage imageWithCGImage:rendered.CGImage scale:1.0 orientation:UIImageOrientationUp];
    return MarkShellApplied(finalImage);
}

// --------------------------------------------------------
// Hook：预览层 + 真正保存层
// --------------------------------------------------------
%group ScreenshotCoreHook

%hook SSSScreenshot

- (void)setBackingImage:(UIImage *)image {
    if (image && isTweakEnabled()) {
        UIImage *shelled = applyShellToScreenshot(image);
        if (shelled) {
            %orig(shelled);
            return;
        }
    }
    %orig(image);
}

@end
%end

%hook SSSScreenshotImageProvider

- (id)requestOutputImageForUIBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;

    if ([image isKindOfClass:[UIImage class]]) {
        UIImage *shelled = applyShellToScreenshot((UIImage *)image);
        return shelled ?: image;
    }
    return image;
}

- (id)requestOutputImageForSavingBlocking {
    id image = %orig;
    if (!image || !isTweakEnabled()) return image;

    if ([image isKindOfClass:[UIImage class]]) {
        UIImage *shelled = applyShellToScreenshot((UIImage *)image);
        return shelled ?: image;
    }
    return image;
}

// 下面两个是兜底，防止某些版本走异步路径
- (void)requestOutputImageForUI:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }

    void (^origBlock)(id) = block;
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            UIImage *shelled = applyShellToScreenshot((UIImage *)image);
            origBlock(shelled ?: image);
        } else {
            origBlock(image);
        }
    };

    %orig(wrappedBlock);
}

- (void)requestOutputImageForSaving:(id)block {
    if (!block || !isTweakEnabled()) {
        %orig(block);
        return;
    }

    void (^origBlock)(id) = block;
    void (^wrappedBlock)(id) = ^(id image) {
        if ([image isKindOfClass:[UIImage class]]) {
            UIImage *shelled = applyShellToScreenshot((UIImage *)image);
            origBlock(shelled ?: image);
        } else {
            origBlock(image);
        }
    };

    %orig(wrappedBlock);
}

%end

%end // ScreenshotCoreHook

// --------------------------------------------------------
// 构造
// --------------------------------------------------------
%ctor {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.ScreenshotServicesService"] ||
        [bundleId isEqualToString:@"com.apple.springboard"]) {
        %init(ScreenshotCoreHook);
    }
}
