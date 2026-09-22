# Building with the IPA bot

This archive keeps the original 3105 project and adds an Objective-C/C
compatibility build for the IPA bot. The bot environment does not provide the
host `swift` command, so the Theos target uses UIKit instead of compiling the
SwiftUI views. `BotCompat/PatchCore.m` is a real port of the 3105 patch
subsystem: it reads/writes the same `.3105` binary-plist envelope, supports
PBKDF2/AES-GCM protected packages, maintains `.3105-project.plist`
workspaces, and applies/restores journaled file transactions. The original
SwiftUI sources remain in `ThreeOneOSFive/` for the Swift-enabled build path.

The bot should receive this ZIP from the project root, where it can find:

- `Makefile` with `APPLICATION_NAME = External`
- `External_FILES` containing the Objective-C/C compatibility target, the
  patch core, and the original 3105 native sources
- `include $(THEOS_MAKE_PATH)/application.mk`
- `ThreeOneOSFive/Info.plist` with the bundle identifier
  `com.dts.external.ios.app`
- `ThreeOneOSFive/Resources/` containing the app icon

The archive does not contain signing credentials. If the bot has a signing
identity and provisioning profile, it can sign the resulting IPA; otherwise
the result will be unsigned.

The bot-compatible native sources also include SDK fallbacks for the missing
`xpc/xpc.h` and `sys/fileport.h` headers, plus warning-clean kernel read/write
signatures for the bot's `-Werror` build settings.

The patch resources are grouped under `Resources/FF/` and
`Resources/FF2022/`; the loader searches those folders and also supports a
flat app bundle. The Patches tab presents the existing catalog as `FF`, with
the `FF 2022` catalog above it. `REMOVE AIMS FF` uses the supplied
`Resources/FF/REMOVE_AIMS_FF.3105` package. The former shared
`cache_res.3105` and `aim_assetindexer.3105` resources are no longer bundled
or referenced.

The compatibility patch path resolves an app container in the same order as
the native 3105 implementation: MCM activation, the LaunchServices data
container, then metadata validation over the application-data directory. The
filesystem fallback deliberately supplements (rather than trusts) a partial
directory listing, because a custom host can otherwise expose only its own
container. Keep `BotCompat/bad_query.c` in the target.