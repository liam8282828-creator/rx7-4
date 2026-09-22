#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// Returns a string from the app's English-only resource bundle.
FOUNDATION_EXPORT NSString *EXLocalizedString(NSString *key);

/// Posted after the in-app accent color changes so existing UIKit screens can
/// apply the new appearance immediately.
FOUNDATION_EXPORT NSNotificationName const EXThemeDidChangeNotification;

/// Preset accent colors exposed by Settings.  The system color picker can
/// additionally persist any custom UIColor selected by the user.
FOUNDATION_EXPORT NSArray<NSString *> *EXThemeAccentNames(void);
FOUNDATION_EXPORT NSString *EXThemeAccentName(void);
FOUNDATION_EXPORT UIColor *EXThemeAccentColor(void);
FOUNDATION_EXPORT void EXSetThemeAccentName(NSString *name);
FOUNDATION_EXPORT void EXSetThemeAccentColor(UIColor *color);