#import "AppDelegate.h"
#import "ViewController.h"
#import "Localization.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    ViewController *home = [[ViewController alloc] initWithHomeMode:YES];
    UINavigationController *homeNavigationController =
        [[UINavigationController alloc] initWithRootViewController:home];
    homeNavigationController.navigationBar.tintColor = EXThemeAccentColor();
    homeNavigationController.navigationBarHidden = YES;
    // The web-style RX7 panel is the only landing surface. Files remains
    // available from the side menu, matching the web navigation.
    self.window.rootViewController = homeNavigationController;
    [self.window makeKeyAndVisible];
    [home addProtectedTabsIfNeeded];
    return YES;
}

@end