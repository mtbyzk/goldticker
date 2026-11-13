ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GoldTicker
GoldTicker_FILES = Tweak.xm
GoldTicker_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
GoldTicker_FRAMEWORKS = UIKit Foundation QuartzCore AVFoundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
