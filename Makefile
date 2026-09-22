TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := External

External_FILES = \
	BotCompat/main.m \
	BotCompat/AppDelegate.m \
	BotCompat/ViewController.m \
BotCompat/CleanerViewController.m \
	BotCompat/SettingsViewController.m \
BotCompat/Localization.m \
BotCompat/CommonCryptoCompat.m \
	BotCompat/BuiltInAIM.m \
BotCompat/PatchCore.m \
BotCompat/PatchProjectsViewController.m \
BotCompat/HoloArmaViewController.m \
	BotCompat/FilesViewController.m \
	BotCompat/SandboxAccessBridge.m \
	BotCompat/ExploitCompatibility.m \
	BotCompat/bad_query.c \
	BotCompat/mcm_bridge.m \
	ThreeOneOSFive/exploit/zip_extract.c \
	ThreeOneOSFive/helpers/AntiDetection.m \
	ThreeOneOSFive/helpers/AppIconHelper.m \
	ThreeOneOSFive/helpers/DisplayIdentity.m \
	ThreeOneOSFive/kexploit/kexploit_opa334.m \
	ThreeOneOSFive/kexploit/krw.m \
	ThreeOneOSFive/kexploit/kutils.m \
	ThreeOneOSFive/kexploit/offsets.m \
	ThreeOneOSFive/kexploit/sandbox_escape.m \
	ThreeOneOSFive/kexploit/vnode.m

External_FRAMEWORKS := UIKit Foundation UniformTypeIdentifiers IOSurface Security
External_CFLAGS := -fobjc-arc -IBotCompat -IThreeOneOSFive -IThreeOneOSFive/exploit -IThreeOneOSFive/kexploit -IThreeOneOSFive/helpers
External_RESOURCE_FILES := \
	ThreeOneOSFive/Resources/ExternalIcon.png \
ThreeOneOSFive/Resources/FF/APOST.3105 \
ThreeOneOSFive/Resources/FF/ASSIST.3105 \
ThreeOneOSFive/Resources/FF/DRAG.3105 \
ThreeOneOSFive/Resources/FF/NECK.3105 \
ThreeOneOSFive/Resources/FF/BODY_DISGUISED.3105 \
ThreeOneOSFive/Resources/FF/REMOVE_AIMS_FF.3105 \
ThreeOneOSFive/Resources/FF/120-144_FPS.3105 \
ThreeOneOSFive/Resources/FF/REMOVE_FPS.3105 \
ThreeOneOSFive/Resources/FF/TRICK.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_ASSIST.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_DRAG.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_NECK.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_CHEST_100.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_VECTORED.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_SILENT.3105 \
ThreeOneOSFive/Resources/FF2022/FF2022_REMOVE_AIMS.3105 \
ThreeOneOSFive/Resources/HoloArma/oloarma_dump1.txt \
ThreeOneOSFive/Resources/HoloArma/oloarma_robotico_dump.txt \
ThreeOneOSFive/Resources/HoloArma/oloarma_pared_dump.txt \
	ThreeOneOSFive/en.lproj/Localizable.strings \
	ThreeOneOSFive/Info.plist

# Keep the native panel in sync with the web dump catalog. New dumps are
# picked up at build time without another Objective-C upload flow.
External_RESOURCE_FILES += $(wildcard Dumps/*.txt)
External_RESOURCE_FILES += $(wildcard ../../venom-modz-vps/Dumps/*.txt)

include $(THEOS_MAKE_PATH)/application.mk