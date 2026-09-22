#import <UIKit/UIKit.h>

/// UIKit implementation of 3105's PatchProjectsView. It intentionally talks
/// only to PatchCore so the bot build has the same package/workspace/
/// transaction behavior without requiring a Swift compiler.
@interface PatchProjectsViewController : UITableViewController
@end