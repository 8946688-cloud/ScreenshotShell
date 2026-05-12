DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 1.0.0

TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard ScreenshotServicesService

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenshotShell
ScreenshotShell_FILES = Tweak.x
ScreenshotShell_CFLAGS = -fobjc-arc
ScreenshotShell_FRAMEWORKS = UIKit CoreGraphics
ScreenshotShell_EXTRA_FRAMEWORKS = Photos

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += screenshotshellprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
