ARCHS = arm64 arm64e
TARGET := iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallAudioInjector

CallAudioInjector_FILES = Tweak.x
CallAudioInjector_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
CallAudioInjector_FRAMEWORKS = AudioToolbox CoreAudio Foundation UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

INSTALL_TARGET_PROCESSES = mediaserverd SpringBoard
