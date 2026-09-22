#import <Foundation/Foundation.h>

/// Returns the definitions for the built-in patch switches shown in Patches.
/// Package payloads are shipped as app resources and decoded only when needed.
FOUNDATION_EXPORT NSArray<NSDictionary *> *ExternalBuiltInPatchDefinitions(void);
FOUNDATION_EXPORT NSDictionary *ExternalBuiltInPatchProject(NSDictionary *definition);