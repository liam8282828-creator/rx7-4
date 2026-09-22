#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A document-based patch workspace with safe file replacement.
///
/// Patch workspaces intentionally use ordinary files and folders. The manager
/// accepts regular files and folders, including `.3105` patch packages. A
/// selected workspace folder can also be applied to an app-data folder selected
/// through the document picker.
@interface PatchManagerViewController : UITableViewController

+ (NSURL *)patchesRootURL;
- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL;

@end

NS_ASSUME_NONNULL_END