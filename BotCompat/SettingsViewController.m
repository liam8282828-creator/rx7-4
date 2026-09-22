#import "SettingsViewController.h"
#import "ExploitCompatibility.h"
#import "Localization.h"

static void EXOpenURL(NSString *string);

@interface SettingsViewController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@property (nonatomic, strong) UIColor *accentColor;
@end

@implementation SettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _accentColor = EXThemeAccentColor();
        [self buildSections];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshAppearance)
                                                 name:EXThemeDidChangeNotification
                                               object:nil];
    self.title = EXLocalizedString(@"settings.title");
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:EXLocalizedString(@"common.done")
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(done)];
    self.tableView.tintColor = self.accentColor;
    self.view.tintColor = self.accentColor;
    [self refreshAppearance];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54.0;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.accentColor = EXThemeAccentColor();
    self.tableView.tintColor = self.accentColor;
    self.view.tintColor = self.accentColor;
    [self refreshAppearance];
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refreshAppearance {
    self.accentColor = EXThemeAccentColor();
    self.tableView.tintColor = self.accentColor;
    self.view.tintColor = self.accentColor;

    UINavigationBar *navigationBar = self.navigationController.navigationBar;
    navigationBar.tintColor = self.accentColor;
    navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: self.accentColor
    };
    navigationBar.largeTitleTextAttributes = @{
        NSForegroundColorAttributeName: self.accentColor
    };
    self.navigationItem.rightBarButtonItem.tintColor = self.accentColor;

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *standard =
            [navigationBar.standardAppearance copy];
        standard.titleTextAttributes = @{
            NSForegroundColorAttributeName: self.accentColor
        };
        standard.largeTitleTextAttributes = @{
            NSForegroundColorAttributeName: self.accentColor
        };
        navigationBar.standardAppearance = standard;

        UINavigationBarAppearance *scrollEdge =
            [navigationBar.scrollEdgeAppearance copy] ?: [standard copy];
        scrollEdge.titleTextAttributes = standard.titleTextAttributes;
        scrollEdge.largeTitleTextAttributes = standard.largeTitleTextAttributes;
        navigationBar.scrollEdgeAppearance = scrollEdge;
    }
}

- (void)buildSections {
    self.sections = @[
        @[
            @{@"kind": @"theme"}
        ],
        @[
            @{@"kind": @"device"}
        ],
        @[
            @{@"kind": @"support"}
        ]
    ];
}

- (void)done {
    UIViewController *presenting = self.navigationController.presentingViewController;
    if ([presenting isKindOfClass:[UINavigationController class]]) {
        UINavigationController *homeNavigationController =
            (UINavigationController *)presenting;
        homeNavigationController.navigationBar.tintColor = self.accentColor;
        homeNavigationController.tabBarController.tabBar.tintColor = self.accentColor;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return EXLocalizedString(@"settings.appearance");
        case 1: return EXLocalizedString(@"common.device");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.sections[indexPath.section][indexPath.row];
    NSString *kind = item[@"kind"];

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"SettingsCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:@"SettingsCell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.imageView.image = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if ([kind isEqualToString:@"theme"]) {
        cell.textLabel.text = EXLocalizedString(@"settings.accent_color");
        cell.detailTextLabel.text = [self localizedThemeName:EXThemeAccentName()];
        cell.accessoryView = [self colorSwatch];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if ([kind isEqualToString:@"device"]) {
        [self configureDeviceCell:cell];
    } else if ([kind isEqualToString:@"support"]) {
        cell.textLabel.text = EXLocalizedString(@"settings.support");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = self.accentColor;
        cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        cell.imageView.image = [UIImage systemImageNamed:@"lifepreserver.fill"];
        cell.imageView.tintColor = self.accentColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (UIView *)colorSwatch {
    UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    swatch.backgroundColor = self.accentColor;
    swatch.layer.cornerRadius = 13.0;
    swatch.layer.borderWidth = 1.0;
    swatch.layer.borderColor = [UIColor colorWithWhite:0.45 alpha:0.45].CGColor;
    return swatch;
}

- (NSString *)localizedThemeName:(NSString *)name {
    if ([name isEqualToString:@"custom"]) {
        return EXLocalizedString(@"settings.color.custom");
    }
    return EXLocalizedString([@"settings.color." stringByAppendingString:name]);
}

- (void)showThemeColorPicker {
    UIColorPickerViewController *picker =
        [[UIColorPickerViewController alloc] init];
    picker.delegate = self;
    picker.selectedColor = EXThemeAccentColor();
    picker.supportsAlpha = NO;
    picker.title = EXLocalizedString(@"settings.accent_color");
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)colorPickerViewControllerDidSelectColor:
    (UIColorPickerViewController *)viewController {
    EXSetThemeAccentColor(viewController.selectedColor);
    self.accentColor = EXThemeAccentColor();
    [self.tableView reloadData];
}

- (void)colorPickerViewControllerDidFinish:
    (UIColorPickerViewController *)viewController {
    self.accentColor = EXThemeAccentColor();
    [self.tableView reloadData];
}

- (void)configureDeviceCell:(UITableViewCell *)cell {
    ExternalExploitCompatibility *status =
        [ExternalExploitCompatibility currentStatus];
    cell.textLabel.text = [NSString stringWithFormat:@"%@\n%@",
        status.hardwareName,
        [NSString stringWithFormat:@"%@ (%@)", status.osVersion, status.osBuild]];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@: %@",
        EXLocalizedString(@"settings.compatibility"),
        status.policySupported
            ? EXLocalizedString(@"settings.supported")
            : EXLocalizedString(@"settings.unsupported")];
    cell.detailTextLabel.textColor = status.policySupported
        ? [UIColor colorWithRed:0.20 green:0.68 blue:0.32 alpha:1.0]
        : UIColor.systemRedColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.sections[indexPath.section][indexPath.row];
    NSString *kind = item[@"kind"];
    if ([kind isEqualToString:@"theme"]) {
        [self showThemeColorPicker];
    } else if ([kind isEqualToString:@"support"]) {
        EXOpenURL(@"https://linktr.ee/llenoderencor");
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end

static void EXOpenURL(NSString *string) {
    NSURL *url = [NSURL URLWithString:string];
    if (url) {
        [[UIApplication sharedApplication] openURL:url
                                           options:@{}
                                 completionHandler:nil];
    }
}