#import <UIKit/UIKit.h>

/// Scans and removes disposable per-app data from Library/Caches and tmp.
/// Documents, preferences, Keychain data, and global system paths are not touched.
@interface CleanerViewController : UITableViewController
@end