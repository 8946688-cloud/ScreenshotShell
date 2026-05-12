TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ScreenshotShellPrefs
ScreenshotShellPrefs_FILES = ScreenshotShellRootListController.m
ScreenshotShellPrefs_FRAMEWORKS = UIKit PhotosUI UniformTypeIdentifiers
ScreenshotShellPrefs_PRIVATE_FRAMEWORKS = Preferences
ScreenshotShellPrefs_INSTALL_PATH = /Library/PreferenceBundles
ScreenshotShellPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
