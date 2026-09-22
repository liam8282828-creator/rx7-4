#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ExternalExploitRuntimeState) {
    ExternalExploitRuntimeStateNotStarted = 0,
    ExternalExploitRuntimeStateRunning,
    ExternalExploitRuntimeStateActive,
    ExternalExploitRuntimeStateFailed,
    ExternalExploitRuntimeStateUnsupported
};

/// Returns YES after the 3105 sandbox-access chain has completed.
/// This must be called from a background thread because the exploit is heavy.
BOOL ExternalEnsureSandboxAccess(void);

/// Reports whether the sandbox-access primitive is currently active.
BOOL ExternalSandboxAccessIsActive(void);

/// Reports kernel R/W success on iOS versions where 3105 does not require a
/// full sandbox probe.
BOOL ExternalKernelAccessIsActive(void);

/// Current state for the Home status card.
ExternalExploitRuntimeState ExternalCurrentExploitRuntimeState(void);

/// Runs the access chain off the main thread. The completion is delivered on
/// the main thread. This is intentionally explicit because failed exploit
/// attempts can terminate/restart the app on some iOS versions.
void ExternalRunSandboxAccess(void (^completion)(BOOL success));