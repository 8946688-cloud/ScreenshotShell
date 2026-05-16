#import "ScreenshotShellRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 完全使用原有的路径逻辑
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
#define SHELL_CFG_PATH [GetPrefDir() stringByAppendingPathComponent:@"config.cfg"]

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

// ========== 跳转 Filza 功能 ==========
- (void)openInFilza {
    NSString *dir = GetPrefDir();
    NSString *filzaUrlStr = [NSString stringWithFormat:@"filza://workspace%@", dir];
    NSURL *url = [NSURL URLWithString:[filzaUrlStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未找到 Filza" message:@"请先在越狱商店安装 Filza File Manager。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// ========== 导入图片 ==========
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

// ========== 导入 CFG ==========
- (void)importConfigFile {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            UIDocumentPickerViewController *docPicker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]];
            docPicker.delegate = self;
            docPicker.allowsMultipleSelection = NO;
            
            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:docPicker animated:YES completion:nil];
        }
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;
    
    BOOL accessing = [sourceURL startAccessingSecurityScopedResource];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:SHELL_CFG_PATH]) {
        [fm removeItemAtPath:SHELL_CFG_PATH error:nil];
    }
    
    NSError *error = nil;
    [fm copyItemAtURL:sourceURL toURL:[NSURL fileURLWithPath:SHELL_CFG_PATH] error:&error];
    if (!error) {
        [fm setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:SHELL_CFG_PATH error:nil];
    }
    
    if (accessing) {
        [sourceURL stopAccessingSecurityScopedResource];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadSpecifiers];
    });
}

// ========== UI 反馈 ==========
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([specifier.identifier isEqualToString:@"shellImageBtn"]) {
        if ([fm fileExistsAtPath:SHELL_IMG_PATH]) {
            UIImage *savedImage = [UIImage imageWithContentsOfFile:SHELL_IMG_PATH];
            UIImageView *previewView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 60)];
            previewView.contentMode = UIViewContentModeScaleAspectFit;
            previewView.image = savedImage;
            cell.accessoryView = previewView;
        } else {
            cell.accessoryView = nil;
        }
    }
    if ([specifier.identifier isEqualToString:@"cfgFileBtn"]) {
        if ([fm fileExistsAtPath:SHELL_CFG_PATH]) {
            UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
            statusLabel.text = @"✅ 已导入";
            statusLabel.textColor = [UIColor systemGreenColor];
            statusLabel.font = [UIFont systemFontOfSize:14];
            statusLabel.textAlignment = NSTextAlignmentRight;
            cell.accessoryView = statusLabel;
        } else {
            cell.accessoryView = nil;
        }
    }
    return cell;
}
@end
