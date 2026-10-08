ARCHS = arm64 arm64e
TARGET := iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallAudioInjector CallAudioInjectorUI

CallAudioInjector_FILES = TweakServer.x
CallAudioInjector_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CallAudioInjector_FRAMEWORKS = AudioToolbox CoreAudio Foundation AVFoundation

CallAudioInjectorUI_FILES = TweakUI.x
CallAudioInjectorUI_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CallAudioInjectorUI_FRAMEWORKS = UIKit Foundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

INSTALL_TARGET_PROCESSES = audiomxd mediaserverd callservicesd InCallService SpringBoard
