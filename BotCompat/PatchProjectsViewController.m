#import "PatchProjectsViewController.h"
#import "BuiltInAIM.h"
#import "PatchCore.h"
#import "FilesViewController.h"
#import "Localization.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface PatchProjectsViewController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSArray<NSDictionary *> *filteredItems;
@property(nonatomic, strong) UISegmentedControl *injectionSectionControl;
@property(nonatomic, strong) UIButton *injectButton;
@property(nonatomic, strong) UILabel *injectionStatusLabel;
@property(nonatomic) NSInteger selectedInjectionSection;
@property(nonatomic) BOOL busy;
@end

@interface ExternalPatchDetailViewController : UITableViewController
- (instancetype)initWithItem:(NSDictionary *)item
                       reload:(void (^)(void))reload;
@end

static NSString *DisplayDate(NSDate *date) {
    if (![date isKindOfClass:NSDate.class]) return @"";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

static NSString *ErrorText(NSError *error) {
    return error.localizedDescription.length
        ? error.localizedDescription
        : EXLocalizedString(@"common.failed");
}

static NSString *BuiltInSelectionDefaultsKey(NSDictionary *definition) {
    return [@"ExternalBuiltInSelection." stringByAppendingString:definition[@"projectID"] ?: @""];
}

@implementation PatchProjectsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshAppearance)
                                                 name:EXThemeDidChangeNotification
                                               object:nil];
    self.title = EXLocalizedString(@"tab.patches");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    // Built-in patches are managed from this screen.  Keep the navigation
    // bar clear so there is no misleading "+" action above the patch list.
    self.navigationItem.rightBarButtonItem = nil;
    self.tableView.tableFooterView = [UIView new];
    self.tableView.scrollEnabled = NO;
    self.tableView.alwaysBounceVertical = NO;
    self.tableView.bounces = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;
    self.selectedInjectionSection = 0; // FF 2022 is the first section.
    [self configureInjectionSectionControl];
    [self configureInjectionFooter];
    [self refreshAppearance];
    [self reloadItems];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refreshAppearance {
    UIColor *accent = EXThemeAccentColor();
    self.tableView.tintColor = accent;
    self.view.tintColor = accent;
    self.injectionSectionControl.tintColor = accent;
    self.injectionSectionControl.selectedSegmentTintColor = accent;
    [self.injectButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.injectButton.backgroundColor = accent;
    [self.injectionSectionControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: UIColor.labelColor
    } forState:UIControlStateNormal];
    [self.injectionSectionControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: UIColor.whiteColor
    } forState:UIControlStateSelected];
    self.navigationController.navigationBar.tintColor = accent;
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: accent
    };
    self.navigationController.navigationBar.largeTitleTextAttributes = @{
        NSForegroundColorAttributeName: accent
    };
    if (@available(iOS 13.0, *)) {
        UINavigationBar *navigationBar = self.navigationController.navigationBar;
        UINavigationBarAppearance *standard =
            [navigationBar.standardAppearance copy];
        standard.titleTextAttributes = @{
            NSForegroundColorAttributeName: accent
        };
        standard.largeTitleTextAttributes = @{
            NSForegroundColorAttributeName: accent
        };
        navigationBar.standardAppearance = standard;

        UINavigationBarAppearance *scrollEdge =
            [navigationBar.scrollEdgeAppearance copy] ?: [standard copy];
        scrollEdge.titleTextAttributes = standard.titleTextAttributes;
        scrollEdge.largeTitleTextAttributes = standard.largeTitleTextAttributes;
        navigationBar.scrollEdgeAppearance = scrollEdge;
    }
    [self.tableView reloadData];
}

- (void)configureInjectionSectionControl {
    NSArray<NSString *> *sectionNames = @[@"FF 2022", @"FF"];
    UISegmentedControl *control =
        [[UISegmentedControl alloc] initWithItems:sectionNames];
    control.selectedSegmentIndex = self.selectedInjectionSection;
    control.accessibilityLabel = @"Injection section";
    [control addTarget:self
                action:@selector(injectionSectionChanged:)
      forControlEvents:UIControlEventValueChanged];
    self.injectionSectionControl = control;

    UIView *header = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, self.view.bounds.size.width, 58.0)];
    header.backgroundColor = UIColor.clearColor;
    control.frame = CGRectMake(16.0, 10.0,
                               MAX(0.0, header.bounds.size.width - 32.0),
                               38.0);
    control.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:control];
    self.tableView.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    if (!header) return;
    header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 58.0);
    self.injectionSectionControl.frame = CGRectMake(
        16.0, 10.0, MAX(0.0, header.bounds.size.width - 32.0), 38.0);
}

- (void)configureInjectionFooter {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(
        0, 0, self.view.bounds.size.width, 104.0)];
    footer.backgroundColor = UIColor.clearColor;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 12.0;
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [button setTitle:@"Inject" forState:UIControlStateNormal];
    [button addTarget:self
               action:@selector(injectSelectedPatches)
     forControlEvents:UIControlEventTouchUpInside];
    self.injectButton = button;

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    status.textColor = UIColor.secondaryLabelColor;
    self.injectionStatusLabel = status;

    [footer addSubview:button];
    [footer addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16.0],
        [button.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16.0],
        [button.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8.0],
        [button.heightAnchor constraintEqualToConstant:50.0],
        [status.topAnchor constraintEqualToAnchor:button.bottomAnchor constant:6.0],
        [status.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16.0],
        [status.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16.0],
        [status.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-4.0]
    ]];
    self.tableView.tableFooterView = footer;
}

- (void)injectionSectionChanged:(UISegmentedControl *)control {
    self.selectedInjectionSection = control.selectedSegmentIndex;
    self.injectionStatusLabel.text = @"";
    self.injectionStatusLabel.textColor = UIColor.secondaryLabelColor;
    [UIView transitionWithView:self.tableView
                      duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self.tableView reloadData];
                    }
                    completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshAppearance];
    [self reloadItems];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.tableView.alpha = 0.0;
    self.tableView.transform = CGAffineTransformMakeScale(0.985, 0.985);
    [UIView animateWithDuration:0.24
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.15
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.tableView.alpha = 1.0;
                         self.tableView.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
}

- (void)reloadItems {
    self.items = [ExternalPatchCore loadPackageItems];
    self.filteredItems = self.items ?: @[];
    [UIView transitionWithView:self.tableView
                      duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self.tableView reloadData];
                    }
                    completion:nil];
}

- (void)beginNewProject {
    [self prompt:EXLocalizedString(@"patch.project_name") defaultValue:@"My Patch" secure:NO completion:^(NSString *name) {
        [self prompt:EXLocalizedString(@"patch.target_bundle") defaultValue:@"com.example.app" secure:NO completion:^(NSString *bundle) {
            [self prompt:EXLocalizedString(@"patch.target_path") defaultValue:@"Library/Preferences/example.plist" secure:NO completion:^(NSString *path) {
                [self prompt:EXLocalizedString(@"patch.replacement_text") defaultValue:@"" secure:NO completion:^(NSString *contents) {
                    NSDictionary *rule = @{@"id": [NSUUID UUID].UUIDString,
                                           @"bundleID": bundle,
                                           @"relativePath": path,
                                             @"replacementFilename": path.lastPathComponent.length ? path.lastPathComponent : @"replacement",
                                           @"replacementData": [contents dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]};
                    NSDictionary *project = @{@"id": [NSUUID UUID].UUIDString,
                                              @"name": name,
                                              @"createdAt": [NSDate date],
                                              @"updatedAt": [NSDate date],
                                              @"bundleIdentifiers": @[bundle],
                                              @"directories": @[],
                                              @"rules": @[rule]};
                    [self saveNewProject:project];
                }];
            }];
        }];
    }];
}

- (void)saveNewProject:(NSDictionary *)project {
    [self runBusy:^{
        NSError *error = nil;
        NSData *data = [ExternalPatchCore encodeProject:project password:nil error:&error];
        if (!data || ![ExternalPatchCore installPackageData:data overwrite:NO unlockedPassword:nil error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                 [self showError:error ?: [NSError errorWithDomain:ExternalPatchErrorDomain code:ExternalPatchErrorInvalidProject userInfo:@{NSLocalizedDescriptionKey:EXLocalizedString(@"patch.create_failed")}]];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadItems];
        });
    }];
}

- (void)importPackage {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]
                                                                                                          asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    NSError *error = nil;
    ExternalPatchPackageSummary *summary = [ExternalPatchCore inspectPackageData:data error:&error];
    if (!summary) {
        [self showError:error];
    } else if (summary.passwordProtected) {
        [self askForPasswordForData:data summary:summary];
    } else {
        [self installImportedData:data password:nil];
    }
}

- (void)askForPasswordForData:(NSData *)data summary:(ExternalPatchPackageSummary *)summary {
     UIAlertController *alert = [UIAlertController alertControllerWithTitle:EXLocalizedString(@"patch.unlock")
                                                                      message:EXLocalizedString(@"patch.password_protected")
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
         field.placeholder = EXLocalizedString(@"patch.password");
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
     [alert addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
     [alert addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"patch.unlock") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *password = alert.textFields.firstObject.text ?: @"";
        [weakSelf installImportedData:data password:password];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)installImportedData:(NSData *)data password:(NSString *)password {
    [self runBusy:^{
        NSError *error = nil;
        BOOL ok = [ExternalPatchCore installPackageData:data overwrite:NO unlockedPassword:password error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) [self showError:error];
            else [self reloadItems];
        });
    }];
}

- (void)prompt:(NSString *)title
  defaultValue:(NSString *)defaultValue
         secure:(BOOL)secure
      completion:(void (^)(NSString *value))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = defaultValue;
        field.secureTextEntry = secure;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
     [alert addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
     [alert addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"common.next") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *value = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (value.length) completion(value);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runBusy:(void (^)(void))operation {
    if (self.busy) return;
    self.busy = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        operation();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.navigationItem.rightBarButtonItem.enabled = YES;
        });
    });
}

- (void)showError:(NSError *)error {
    if (!error) error = [NSError errorWithDomain:ExternalPatchErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Patch operation failed."}];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed"
                                                                     message:ErrorText(error)
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self definitionsForSection:self.selectedInjectionSection].count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSArray<NSDictionary *> *)definitionsForSection:(NSInteger)section {
    NSString *sectionName = section == 0 ? @"FF 2022" : @"FF";
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *definition,
                                                                    __unused NSDictionary *bindings) {
        return [definition[@"section"] isEqualToString:sectionName];
    }];
    return [ExternalBuiltInPatchDefinitions() filteredArrayUsingPredicate:predicate];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"PatchProjectCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    NSDictionary *definition =
        [self definitionsForSection:self.selectedInjectionSection][indexPath.row];
    NSDictionary *project = [ExternalBuiltInPatchProject(definition) copy];
    BOOL active = [self isBuiltInDefinitionSelected:definition];

    cell.textLabel.text = definition[@"name"];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = definition[@"warning"];
    cell.detailTextLabel.numberOfLines = definition[@"warning"] ? 0 : 1;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.detailTextLabel.textColor = [self warningColorForDefinition:definition];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = active;
    toggle.onTintColor = EXThemeAccentColor();
    toggle.enabled = project != nil && !self.busy;
    toggle.tag = [ExternalBuiltInPatchDefinitions() indexOfObject:definition];
    toggle.accessibilityLabel = definition[@"name"];
    [toggle addTarget:self
               action:@selector(builtInPatchSwitchChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // Only the switch is actionable.  Do not toggle a patch when the user
    // taps its name, detail text, or any other part of the row.
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return nil;
}

- (UIColor *)warningColorForDefinition:(NSDictionary *)definition {
    NSString *color = definition[@"warningColor"];
    if ([color isEqualToString:@"green"]) {
        return [UIColor colorWithRed:0.20 green:0.82 blue:0.40 alpha:1.0];
    }
    if ([color isEqualToString:@"red"]) {
        return [UIColor colorWithRed:1.0 green:0.30 blue:0.30 alpha:1.0];
    }
    if ([color isEqualToString:@"yellow"]) {
        return [UIColor colorWithRed:1.0 green:0.68 blue:0.16 alpha:1.0];
    }
    return UIColor.secondaryLabelColor;
}

- (BOOL)isBuiltInDefinitionSelected:(NSDictionary *)definition {
    NSString *key = BuiltInSelectionDefaultsKey(definition);
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (stored != nil) return stored.boolValue;
    // Preserve the selected state for transactions created by an older build
    // until the user explicitly changes that switch.
    return [ExternalPatchCore latestReceiptForProjectID:definition[@"projectID"]] != nil;
}

- (void)setBuiltInDefinitionSelected:(NSDictionary *)definition selected:(BOOL)selected {
    [[NSUserDefaults standardUserDefaults] setBool:selected
                                            forKey:BuiltInSelectionDefaultsKey(definition)];
}

- (BOOL)deactivateConflictsForDefinition:(NSDictionary *)definition
                    deactivatedDefinitions:(NSMutableArray<NSDictionary *> *)deactivated {
    NSString *group = definition[@"group"];
    BOOL isAimChoice = [group isEqualToString:@"aim"] ||
        [group isEqualToString:@"ff2022-aim"];
    BOOL isRemoveAims = [definition[@"key"] rangeOfString:@"remove_aims"].location != NSNotFound;
    for (NSDictionary *candidate in ExternalBuiltInPatchDefinitions()) {
        if ([candidate[@"projectID"] isEqual:definition[@"projectID"]]) {
            continue;
        }
        BOOL sameGroup = [candidate[@"group"] isEqual:group];
        BOOL aimResetConflict = isAimChoice && isRemoveAims
            ? [candidate[@"group"] isEqualToString:group]
            : isAimChoice && [candidate[@"key"] rangeOfString:@"remove_aims"].location != NSNotFound;
        BOOL removeAimsConflict = isRemoveAims &&
            [candidate[@"group"] isEqualToString:group];
        if (!sameGroup && !aimResetConflict && !removeAimsConflict) {
            continue;
        }
        if (![self isBuiltInDefinitionSelected:candidate]) continue;
        [self setBuiltInDefinitionSelected:candidate selected:NO];
        [deactivated addObject:candidate];
    }
    return YES;
}

- (BOOL)applyBuiltInDefinition:(NSDictionary *)definition
                        enabling:(BOOL)enabling
                           error:(NSError **)error {
    // Turning a switch off only changes the selected state.  It deliberately
    // does not restore files; REMOVE FPS and REMOVE AIMS are the explicit
    // patches that perform those changes when they are enabled.
    if (!enabling) {
        [self setBuiltInDefinitionSelected:definition selected:NO];
        return YES;
    }

    NSMutableArray<NSDictionary *> *deactivated = [NSMutableArray array];
    [self deactivateConflictsForDefinition:definition
                    deactivatedDefinitions:deactivated];

    NSDictionary *project = ExternalBuiltInPatchProject(definition);
    ExternalPatchTransactionReceipt *receipt =
        project ? [ExternalPatchCore applyProject:project error:error] : nil;
    if (receipt) {
        [self setBuiltInDefinitionSelected:definition selected:YES];
        return YES;
    }

    // Restore only the switch-selection state after an apply failure.  No
    // device file is restored or rewritten here.
    for (NSDictionary *previous in deactivated) {
        [self setBuiltInDefinitionSelected:previous selected:YES];
    }
    return NO;
}

- (void)builtInPatchSwitchChanged:(UISwitch *)control {
    if (self.busy) return;
    NSArray<NSDictionary *> *definitions = ExternalBuiltInPatchDefinitions();
    if (control.tag < 0 || control.tag >= definitions.count) {
        control.on = NO;
        return;
    }

    NSDictionary *definition = definitions[control.tag];
    BOOL enable = control.isOn;
    [self setBuiltInDefinitionSelected:definition selected:enable];
    if (enable) {
        NSMutableArray<NSDictionary *> *deactivated = [NSMutableArray array];
        [self deactivateConflictsForDefinition:definition
                        deactivatedDefinitions:deactivated];
    }
    self.injectionStatusLabel.text = @"";
    self.injectionStatusLabel.textColor = UIColor.secondaryLabelColor;
    [self.tableView reloadData];
}

- (void)injectSelectedPatches {
    if (self.busy) return;

    NSArray<NSDictionary *> *definitions = [self definitionsForSection:self.selectedInjectionSection];
    NSMutableArray<NSDictionary *> *selected = [NSMutableArray array];
    for (NSDictionary *definition in definitions) {
        if ([self isBuiltInDefinitionSelected:definition]) {
            [selected addObject:definition];
        }
    }
    if (!selected.count) {
        self.injectionStatusLabel.text = @"Select at least one option.";
        self.injectionStatusLabel.textColor = UIColor.secondaryLabelColor;
        return;
    }

    self.busy = YES;
    self.injectButton.enabled = NO;
    self.injectionStatusLabel.text = @"Injecting…";
    self.injectionStatusLabel.textColor = UIColor.secondaryLabelColor;
    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.injectButton.transform = CGAffineTransformMakeScale(0.97, 0.97);
                         self.injectionStatusLabel.alpha = 0.72;
                     }
                     completion:nil];

    NSDate *injectionStartedAt = [NSDate date];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = YES;
        for (NSDictionary *definition in selected) {
            if (![self applyBuiltInDefinition:definition enabling:YES error:&error]) {
                ok = NO;
                break;
            }
        }
        NSTimeInterval remaining = 2.0 -
            [[NSDate date] timeIntervalSinceDate:injectionStartedAt];
        if (remaining > 0) {
            [NSThread sleepForTimeInterval:remaining];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.injectButton.enabled = YES;
            self.injectButton.transform = CGAffineTransformIdentity;
            self.injectionStatusLabel.alpha = 1.0;
            if (ok) {
                self.injectionStatusLabel.text = @"Success";
                self.injectionStatusLabel.textColor = [UIColor colorWithRed:0.15
                                                                        green:0.65
                                                                         blue:0.25
                                                                        alpha:1.0];
            } else {
                self.injectionStatusLabel.text = @"Injection failed";
                self.injectionStatusLabel.textColor = UIColor.systemRedColor;
                NSLog(@"[External] injection failed: %@", error);
                [self showError:error];
            }
            [self.tableView reloadData];
        });
    });
}

@end

@interface ExternalPatchDetailViewController ()
@property(nonatomic, strong) NSDictionary *item;
@property(nonatomic, copy) void (^reloadBlock)(void);
@end

@implementation ExternalPatchDetailViewController

- (instancetype)initWithItem:(NSDictionary *)item reload:(void (^)(void))reload {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _item = item;
        _reloadBlock = [reload copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.item[@"project"][@"name"] ?: @"Patch";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Export"
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(exportTapped)];
    self.tableView.tableFooterView = [UIView new];
}

- (ExternalPatchPackageSummary *)summary {
    return self.item[@"summary"];
}

- (NSDictionary *)project {
    return self.item[@"project"];
}

- (void)exportTapped {
    NSURL *url = self.item[@"packageURL"];
    if (!url) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:share animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSDictionary *project = self.project;
    if (section == 0) return project ? 4 : 1;
    if (section == 1) return project ? MAX(1, [project[@"rules"] count] + [project[@"directories"] count]) : 1;
    return project ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Project", @"Patch entries", @"Actions"][section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *project = self.project;
    ExternalPatchPackageSummary *summary = self.summary;
    if (!project) {
        cell.textLabel.text = @"Unlock package";
        cell.detailTextLabel.text = @"This package needs its password before it can be used.";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.section == 0) {
        NSArray *labels = @[@"Bundle identifiers", @"Schema version", @"Created", @"Updated"];
        cell.textLabel.text = labels[indexPath.row];
        if (indexPath.row == 0) cell.detailTextLabel.text = [project[@"bundleIdentifiers"] componentsJoinedByString:@", "];
        if (indexPath.row == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%@", (long)summary.schemaVersion, summary.passwordProtected ? @"  •  password protected" : @""];
        if (indexPath.row == 2) cell.detailTextLabel.text = DisplayDate(project[@"createdAt"]);
        if (indexPath.row == 3) cell.detailTextLabel.text = DisplayDate(project[@"updatedAt"]);
    } else if (indexPath.section == 1) {
        NSMutableArray *entries = [NSMutableArray array];
        for (NSDictionary *directory in project[@"directories"] ?: @[]) [entries addObject:[NSString stringWithFormat:@"Folder  %@/%@", directory[@"bundleID"], directory[@"relativePath"]]];
        for (NSDictionary *rule in project[@"rules"] ?: @[]) [entries addObject:[NSString stringWithFormat:@"File  %@/%@", rule[@"bundleID"], rule[@"relativePath"]]];
        if (!entries.count) {
            cell.textLabel.text = @"No entries";
        } else {
            cell.textLabel.text = entries[indexPath.row];
            cell.detailTextLabel.text = indexPath.row < [project[@"rules"] count] ? @"Replacement file" : @"Workspace directory";
        }
    } else {
        NSArray *labels = @[@"Apply to app data", @"Restore latest transaction", @"Open workspace", @"Sync workspace"];
        cell.textLabel.text = labels[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:@[@"arrow.down.doc", @"arrow.uturn.backward", @"folder", @"arrow.triangle.2.circlepath"][indexPath.row]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 1 && ![ExternalPatchCore latestReceiptForProjectID:summary.packageID]) {
            cell.textLabel.textColor = UIColor.tertiaryLabelColor;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.project) {
        [self unlockExistingPackage];
        return;
    }
    if (indexPath.section != 2) return;
    switch (indexPath.row) {
        case 0: [self confirmApply]; break;
        case 1: [self confirmRestore]; break;
        case 2: [self openWorkspace]; break;
        case 3: [self syncWorkspace]; break;
    }
}

- (void)unlockExistingPackage {
    NSData *data = [NSData dataWithContentsOfURL:self.item[@"packageURL"] options:NSDataReadingMappedIfSafe error:nil];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unlock package" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.secureTextEntry = YES; field.placeholder = @"Password"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unlock" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSError *error = nil;
        NSDictionary *decoded = [ExternalPatchCore decodePackageData:data password:alert.textFields.firstObject.text error:&error];
        if (!decoded) { [self showError:error]; return; }
        [ExternalPatchCore storeContentKey:decoded[@"contentKey"] summary:self.summary error:nil];
        if (self.reloadBlock) self.reloadBlock();
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmApply {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply patch?"
                                                                     message:@"This replaces the selected files in the target app containers. Originals are backed up and the transaction can be restored later."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            ExternalPatchTransactionReceipt *receipt = [ExternalPatchCore applyProject:self.project error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!receipt) [self showError:error];
                else {
                    [self.tableView reloadData];
                    [self showMessage:@"Applied" text:@"Patch applied and backed up transactionally."];
                }
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRestore {
    ExternalPatchTransactionReceipt *receipt = [ExternalPatchCore latestReceiptForProjectID:self.summary.packageID];
    if (!receipt) { [self showMessage:@"Restore unavailable" text:@"There is no prepared or applied transaction for this project."]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore original files?"
                                                                     message:@"Restore verifies that targets still contain the patch before putting the backed-up originals back. If files changed externally, it refuses to overwrite them."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            BOOL ok = [ExternalPatchCore restoreReceipt:receipt error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) [self showError:error];
                else { [self.tableView reloadData]; [self showMessage:@"Restored" text:@"The backed-up originals were restored."]; }
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openWorkspace {
    NSError *error = nil;
    NSURL *workspace = [ExternalPatchCore ensureWorkspaceForProject:self.project error:&error];
    if (!workspace) { [self showError:error]; return; }
    FilesViewController *files = [[FilesViewController alloc] initWithDirectoryURL:workspace appName:self.project[@"name"] bundleID:nil];
    [self.navigationController pushViewController:files animated:YES];
}

- (void)syncWorkspace {
    NSData *key = self.item[@"contentKey"];
    if (!key) { [self showMessage:@"Unlock required" text:@"Unlock the package before synchronizing its workspace."]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *workspace = [ExternalPatchCore ensureWorkspaceForProject:self.project error:&error];
        NSDictionary *project = workspace ? [ExternalPatchCore snapshotWorkspace:workspace baseProject:self.project error:&error] : nil;
        NSData *oldData = [NSData dataWithContentsOfURL:self.item[@"packageURL"] options:NSDataReadingMappedIfSafe error:&error];
        NSData *newData = project && oldData ? [ExternalPatchCore updatePackageData:oldData project:project contentKey:key schemaVersion:2 error:&error] : nil;
        BOOL ok = newData && [newData writeToURL:self.item[@"packageURL"] options:NSDataWritingAtomic error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) [self showError:error];
            else { if (self.reloadBlock) self.reloadBlock(); [self showMessage:@"Workspace synced" text:@"The .3105 package now matches the workspace files."]; [self.tableView reloadData]; }
        });
    });
}

- (void)showMessage:(NSString *)title text:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSError *)error {
    [self showMessage:@"Failed" text:ErrorText(error)];
}

@end