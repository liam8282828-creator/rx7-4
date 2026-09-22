#import "Localization.h"

NSNotificationName const EXThemeDidChangeNotification = @"EXThemeDidChangeNotification";

static NSString * const kEXThemeAccentName = @"ExternalAccentColorName";
static NSString * const kEXThemeAccentColor = @"ExternalAccentColorRGB";
static NSString * const kEXDefaultThemeAccentName = @"green";

static NSDictionary<NSString *, NSString *> *EXThemeHexValues(void) {
    return @{
        @"blue": @"#0A84FF",
        @"red": @"#FF375F",
        @"purple": @"#BF5AF2",
        @"pink": @"#FF2D55",
        @"orange": @"#FF9F0A",
        @"yellow": @"#FFD60A",
        @"green": @"#64D841",
        @"mint": @"#63E6BE",
        @"teal": @"#40C8E0",
        @"cyan": @"#64D2FF",
        @"indigo": @"#5E5CE6",
        @"white": @"#FFFFFF",
        @"lightgray": @"#D1D1D6",
        @"gray": @"#8E8E93",
        @"darkgray": @"#48484A",
        @"black": @"#000000"
    };
}

NSString *EXLocalizedString(NSString *key) {
    NSString *englishPath = [[NSBundle mainBundle] pathForResource:@"en"
                                                              ofType:@"lproj"];
    NSBundle *english = englishPath.length
        ? [NSBundle bundleWithPath:englishPath]
        : [NSBundle mainBundle];
    NSString *value = [english localizedStringForKey:key value:nil table:nil];
    if (!value.length || [value isEqualToString:key]) {
        value = [english localizedStringForKey:key value:key table:nil];
    }
    return value.length ? value : key;
}

NSArray<NSString *> *EXThemeAccentNames(void) {
    return @[@"blue", @"red", @"purple", @"pink", @"orange", @"yellow",
             @"green", @"mint", @"teal", @"cyan", @"indigo", @"white",
             @"lightgray", @"gray", @"darkgray", @"black"];
}

NSString *EXThemeAccentName(void) {
    NSDictionary *custom = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kEXThemeAccentColor];
    if ([custom[@"red"] isKindOfClass:NSNumber.class] &&
        [custom[@"green"] isKindOfClass:NSNumber.class] &&
        [custom[@"blue"] isKindOfClass:NSNumber.class]) {
        return @"custom";
    }
    NSString *stored = [[NSUserDefaults standardUserDefaults]
        stringForKey:kEXThemeAccentName].lowercaseString;
    return [EXThemeHexValues()[stored] isKindOfClass:NSString.class]
        ? stored
        : kEXDefaultThemeAccentName;
}

UIColor *EXThemeAccentColor(void) {
    NSDictionary *custom = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kEXThemeAccentColor];
    NSNumber *red = custom[@"red"];
    NSNumber *green = custom[@"green"];
    NSNumber *blue = custom[@"blue"];
    NSNumber *alpha = custom[@"alpha"];
    if ([red isKindOfClass:NSNumber.class] &&
        [green isKindOfClass:NSNumber.class] &&
        [blue isKindOfClass:NSNumber.class]) {
        return [UIColor colorWithRed:MAX(0.0, MIN(1.0, red.doubleValue))
                               green:MAX(0.0, MIN(1.0, green.doubleValue))
                                blue:MAX(0.0, MIN(1.0, blue.doubleValue))
                               alpha:[alpha isKindOfClass:NSNumber.class]
                                   ? MAX(0.0, MIN(1.0, alpha.doubleValue))
                                   : 1.0];
    }
    NSString *hex = EXThemeHexValues()[EXThemeAccentName()];
    unsigned long long number = 0;
    [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexLongLong:&number];
    return [UIColor colorWithRed:((number >> 16) & 0xFF) / 255.0
                           green:((number >> 8) & 0xFF) / 255.0
                            blue:(number & 0xFF) / 255.0
                           alpha:1.0];
}

void EXSetThemeAccentName(NSString *name) {
    NSString *normalized = name.lowercaseString;
    if (![EXThemeHexValues()[normalized] isKindOfClass:NSString.class]) {
        normalized = kEXDefaultThemeAccentName;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kEXThemeAccentColor];
    [defaults setObject:normalized forKey:kEXThemeAccentName];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EXThemeDidChangeNotification
                      object:nil];
}

void EXSetThemeAccentColor(UIColor *color) {
    if (!color) return;
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 1.0;
    BOOL converted = [color getRed:&red green:&green blue:&blue alpha:&alpha];
    if (!converted) {
        CGFloat white = 0.0;
        converted = [color getWhite:&white alpha:&alpha];
        red = green = blue = white;
    }
    if (!converted) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:@{
        @"red": @(red),
        @"green": @(green),
        @"blue": @(blue),
        @"alpha": @(alpha)
    } forKey:kEXThemeAccentColor];
    [defaults setObject:@"custom" forKey:kEXThemeAccentName];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EXThemeDidChangeNotification
                      object:nil];
}