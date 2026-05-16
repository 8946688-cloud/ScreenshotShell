#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ========== 获取适配越狱环境的路径 ==========
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

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

static NSString * GetPrefsPath() {
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

#define SHELL_IMG_PATH [GetPrefDir() stringByAppendingPathComponent:@"shell.png"]
#define SHELL_CFG_PATH [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"]


// ========== 核心套壳图像处理 ==========
// 注意：如果你有自己的读取 cfg 坐标和绘图的方法，可以直接替换这里的内部实现
UIImage *ApplyScreenshotShell(UIImage *originalImage) {
    if (!originalImage) return nil;

    // 1. 判断全局开关
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPath()];
    if (prefs && ![prefs[@"Enabled"] boolValue]) {
        return originalImage;
    }

    // 2. 读取透明壳图片
    UIImage *shellImage = [UIImage imageWithContentsOfFile:SHELL_IMG_PATH];
    if (!shellImage) return originalImage;

    // 3. 读取并解析 config.cfg
    // 这里假设 cfg 的格式是用逗号分隔的: x,y,width,height
    NSString *cfgString = [NSString stringWithContentsOfFile:SHELL_CFG_PATH encoding:NSUTF8StringEncoding error:nil];
    CGRect screenRect = CGRectZero;
    
    if (cfgString && cfgString.length > 0) {
        NSArray *components = [cfgString componentsSeparatedByString:@","];
        if (components.count >= 4) {
            screenRect = CGRectMake([components[0] doubleValue], 
                                    [components[1] doubleValue], 
                                    [components[2] doubleValue], 
                                    [components[3] doubleValue]);
        }
    }

    // 如果解析失败，给个默认尺寸兜底
    if (CGRectIsEmpty(screenRect)) {
        screenRect = CGRectMake(0, 0, originalImage.size.width, originalImage.size.height);
    }

    // 4. 开始图像合成
    UIGraphicsBeginImageContextWithOptions(shellImage.size, NO, 0.0);
    
    // ① 先画原始截图 (放在下层)
    [originalImage drawInRect:screenRect];
    
    // ② 再画透明套壳 (放在上层，覆盖截图边缘)
    [shellImage drawInRect:CGRectMake(0, 0, shellImage.size.width, shellImage.size.height)];
    
    UIImage *resultImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return resultImage ?: originalImage;
}


// ========== 核心 Hook 注入 ==========
%hook SSSScreenshot

// 修复 Bug 2: 解决多次调用导致的重复套壳（画中画）问题
- (UIImage *)backingImage {
    UIImage *orig = %orig;
    if (!orig) return orig;

    // 检查关联对象，判断当前截图实例是否已经套过壳
    NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
    if ([hasShelled boolValue]) {
        return orig; // 已经套过了，直接返回，绝不二次套壳
    }

    // 执行套壳
    UIImage *shelledImage = ApplyScreenshotShell(orig);
    
    if (shelledImage && shelledImage != orig) {
        // 【关键步骤】：把套好壳的图片强行写回底层属性
        [self setBackingImage:shelledImage];
        
        // 【关键步骤】：打上标记，防止未来用户编辑图片后保存时再次套壳
        objc_setAssociatedObject(self, @selector(hasShelled), @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        return shelledImage;
    }

    return orig;
}

// 修复 Bug 1 (主要): 强制系统认为图片有“未保存的编辑”
// 这样即使你不画一笔，系统也不会去存那个原始没套壳的屏幕快照，而是乖乖保存我们的 backingImage
- (BOOL)hasUnsavedImageEdits {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
        if ([hasShelled boolValue]) {
            return YES; // 强制要求系统走保存渲染流程
        }
    }
    return %orig;
}

// 修复 Bug 1 (辅助): 覆盖不同 iOS 版本的检测方法 (iOS 15-17 兼容)
- (BOOL)hasEverBeenEditedForMode:(long long)mode {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GetPrefsPath()];
    if (prefs && [prefs[@"Enabled"] boolValue]) {
        NSNumber *hasShelled = objc_getAssociatedObject(self, @selector(hasShelled));
        if ([hasShelled boolValue]) {
            return YES;
        }
    }
    return %orig;
}

%end
