#import <UIKit/UIKit.h>

@interface ViewController : UIViewController

- (instancetype)initWithHomeMode:(BOOL)homeMode;
- (void)addProtectedTabsIfNeeded;

@end