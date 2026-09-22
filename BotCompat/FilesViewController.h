#import <UIKit/UIKit.h>

/// Browses all application data containers exposed by the same filesystem
/// access path used by 3105, with copy, move, paste, replace, rename and
/// delete actions for files and folders.
@interface FilesViewController : UITableViewController

- (instancetype)initWithApplicationList;
- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL
                           appName:(NSString *)appName
                       bundleID:(NSString *)bundleID;

+ (NSURL *)applicationDataRootURL;
+ (NSArray<NSDictionary *> *)availableApplications;

@end