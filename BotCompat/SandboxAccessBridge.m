#import "SandboxAccessBridge.h"
#import "ExploitCompatibility.h"

#import "../ThreeOneOSFive/kexploit/kexploit_opa334.h"
#import "../ThreeOneOSFive/kexploit/kutils.h"
#import "../ThreeOneOSFive/kexploit/sandbox_escape.h"

static volatile BOOL sKernelAccessReady = NO;
static volatile ExternalExploitRuntimeState sRuntimeState =
    ExternalExploitRuntimeStateNotStarted;

BOOL ExternalSandboxAccessIsActive(void) {
    return sandbox_access_is_active() == 1;
}

BOOL ExternalKernelAccessIsActive(void) {
    return sKernelAccessReady || ExternalSandboxAccessIsActive();
}

ExternalExploitRuntimeState ExternalCurrentExploitRuntimeState(void) {
    if (ExternalKernelAccessIsActive()) {
        return ExternalExploitRuntimeStateActive;
    }
    return sRuntimeState;
}

BOOL ExternalEnsureSandboxAccess(void) {
    static dispatch_once_t onceToken;
    static BOOL accessReady = NO;

    dispatch_once(&onceToken, ^{
        ExternalExploitCompatibility *compatibility =
            [ExternalExploitCompatibility currentStatus];
        if (!compatibility.canRun) {
            NSLog(@"[External] exploit preflight rejected: iOS=%@ build=%@ device=%@ cpu=%@ policy=%d offsets=%d",
                  compatibility.osVersion,
                  compatibility.osBuild,
                  compatibility.hardwareIdentifier,
                  compatibility.cpuFamilyName,
                  compatibility.policySupported,
                  compatibility.offsetsAvailable);
            sRuntimeState = ExternalExploitRuntimeStateUnsupported;
            return;
        }

        sRuntimeState = ExternalExploitRuntimeStateRunning;
        if (ExternalSandboxAccessIsActive()) {
            accessReady = YES;
            sKernelAccessReady = YES;
            sRuntimeState = ExternalExploitRuntimeStateActive;
            return;
        }

        NSLog(@"[External] starting 3105 kernel/sandbox access chain");
        int exploitResult = kexploit_opa334();
        if (exploitResult != 0) {
            NSLog(@"[External] kexploit_opa334 failed: %d", exploitResult);
            sRuntimeState = ExternalExploitRuntimeStateFailed;
            return;
        }
        sKernelAccessReady = YES;

        uint64_t selfProc = proc_self();
        if (selfProc == 0) {
            NSLog(@"[External] proc_self returned 0");
            sRuntimeState = ExternalExploitRuntimeStateFailed;
            sKernelAccessReady = NO;
            return;
        }

        int escapeResult = sandbox_escape(selfProc);
        BOOL sandboxReady = escapeResult == 0 &&
            ExternalSandboxAccessIsActive();
        NSInteger majorVersion =
            [NSProcessInfo processInfo].operatingSystemVersion.majorVersion;
        // 3105 treats kernel R/W as a successful Active state before iOS 26.
        // iOS 26 and later require the complete sandbox escape for Files.
        accessReady = sandboxReady || majorVersion < 26;
        if (majorVersion >= 26 && !sandboxReady) {
            sKernelAccessReady = NO;
            sRuntimeState = ExternalExploitRuntimeStateFailed;
        } else {
            sRuntimeState = ExternalExploitRuntimeStateActive;
        }
        NSLog(@"[External] sandbox escape result=%d active=%d",
              escapeResult,
              accessReady);
    });

    return accessReady;
}

void ExternalRunSandboxAccess(void (^completion)(BOOL success)) {
    void (^callback)(BOOL) = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL success = ExternalEnsureSandboxAccess();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (callback) callback(success);
        });
    });
}