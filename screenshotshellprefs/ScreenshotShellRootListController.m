#import "ScreenshotShellRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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

#define SHELL_IMG_PATH [GetPrefDir() stringByAppendingPathComponent:@"shell.png"]

@implementation ScreenshotShellRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = GetPrefDir();
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} error:nil];
    } else {
        [fm setAttributes:@{NSFileProtectionKey: NSFileProtectionNone, NSFilePosixPermissions: @0777} ofItemAtPath:dir error:nil];
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    }
    return _specifiers;
}

- (void)chooseShellImage {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.selectionLimit = 1;
            config.filter = [PHPickerFilter imagesFilter];
            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
            picker.delegate = self;
            
            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    
    NSItemProvider *itemProvider = results.firstObject.itemProvider;
    if ([itemProvider canLoadObjectOfClass:[UIImage class]]) {
        [itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id object, NSError *error) {
            if ([object isKindOfClass:[UIImage class]]) {
                // 使用 PNG 保存，保留透明层
                NSData *imageData = UIImagePNGRepresentation((UIImage *)object);
                if ([imageData writeToFile:SHELL_IMG_PATH atomically:YES]) {
                    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:SHELL_IMG_PATH error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self reloadSpecifiers];
                    });
                }
            }
        }];
    }
}

// 在设置里展示选中的壳缩略图
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    
    if ([specifier.identifier isEqualToString:@"shellImageBtn"]) {
        UIImage *savedImage = [UIImage imageWithContentsOfFile:SHELL_IMG_PATH];
        if (savedImage) {
            UIImageView *previewView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 32, 64)];
            previewView.contentMode = UIViewContentModeScaleAspectFit;
            previewView.image = savedImage;
            cell.accessoryView = previewView;
        } else {
            cell.accessoryView = nil;
        }
    }
    return cell;
}
@end
