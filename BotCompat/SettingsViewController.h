#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UIKit settings used by the Makefile/BotCompat build.
/// Keep this screen in sync with ThreeOneOSFive/views/SettingsView.swift:
/// the Makefile does not compile the SwiftUI app entry point.
@interface SettingsViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END