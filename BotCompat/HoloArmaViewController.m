#import "HoloArmaViewController.h"
#import "FilesViewController.h"
#import "Localization.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kHoloArmaMainDump = @"oloarma_dump1.txt";
static NSString * const kHoloArmaRoboticoDump = @"oloarma_robotico_dump.txt";
static NSString * const kHoloArmaParedDump = @"oloarma_pared_dump.txt";

static NSArray<NSString *> *HoloArmaPathIDs(void) {
    return @[
        @"3504935391519681939  — Shader principal arma",
        @"-3333330928057165289 — Shader robotico / segundo dump",
        @"893500320385684910   — Textura o pared",
        @"-6752853195891321129 — Referencia holograma compartida"
    ];
}

@interface HoloArmaViewController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *stackView;
@property(nonatomic, strong) UILabel *assetStatusLabel;
@property(nonatomic, strong) UILabel *modeStatusLabel;
@property(nonatomic, strong) UIButton *roboticoModeButton;
@property(nonatomic, strong) UIButton *bordesModeButton;
@property(nonatomic, strong) UIButton *importButton;
@property(nonatomic, strong) UIButton *openButton;
@property(nonatomic, strong) NSURL *assetURL;
@property(nonatomic, strong) NSURL *mainDumpURL;
@property(nonatomic, strong) NSURL *roboticoDumpURL;
@property(nonatomic, strong) NSURL *paredDumpURL;
@property(nonatomic, copy) NSString *pendingRole;
@property(nonatomic, copy) NSString *selectedMode;
@property(nonatomic, strong) NSURL *lastSessionURL;
@property(nonatomic) BOOL busy;
@end

@implementation HoloArmaViewController

- (instancetype)initWithAssetURL:(NSURL *)assetURL {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _assetURL = assetURL;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Holograma Arma";
    self.view.backgroundColor = UIColor.blackColor;
    self.navigationController.navigationBar.tintColor = EXThemeAccentColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self buildInterface];
    [self loadBundledDumps];
    [self refreshState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = NO;
    self.navigationController.navigationBar.tintColor = EXThemeAccentColor();
}

- (void)buildInterface {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    self.stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 14.0;
    [self.scrollView addSubview:self.stackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:18.0],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-18.0],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:18.0],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-28.0],
        [self.stackView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-36.0]
    ]];

    UILabel *title = [self label:@"Importación local de Holograma Arma"
                              size:25.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    [self.stackView addArrangedSubview:title];

    UILabel *description = [self label:@"Elige ROBÓTICO o BORDES y después sube solamente el asset o bundle. Los dumps ya vienen incluidos."
                                    size:14.0 weight:UIFontWeightRegular
                                    color:[UIColor colorWithWhite:0.66 alpha:1.0]];
    description.numberOfLines = 0;
    [self.stackView addArrangedSubview:description];

    UIView *notice = [self cardView];
    UIStackView *noticeStack = [self verticalStackInView:notice spacing:5.0];
    UILabel *noticeTitle = [self label:@"Flujo nativo"
                                   size:14.0 weight:UIFontWeightBold color:EXThemeAccentColor()];
    UILabel *noticeText = [self label:@"El asset y los dumps se guardan juntos sin subirlos a internet. Los Path ID se conservan en el manifiesto de la sesión."
                                  size:13.0 weight:UIFontWeightRegular
                                  color:[UIColor colorWithWhite:0.72 alpha:1.0]];
    noticeText.numberOfLines = 0;
    [noticeStack addArrangedSubview:noticeTitle];
    [noticeStack addArrangedSubview:noticeText];
    [self.stackView addArrangedSubview:notice];

    UILabel *modeTitle = [self label:@"1. ELIGE EL TIPO DE HOLOGRAMA"
                                  size:13.0 weight:UIFontWeightBold color:EXThemeAccentColor()];
    [self.stackView addArrangedSubview:modeTitle];
    UIView *modeCard = [self cardView];
    UIStackView *modeStack = [self verticalStackInView:modeCard spacing:8.0];
    self.roboticoModeButton = [self actionButton:@"ROBÓTICO"
                                            color:[UIColor colorWithRed:0.86 green:0.25 blue:0.08 alpha:1.0]
                                           action:@selector(selectRoboticoMode)];
    self.bordesModeButton = [self actionButton:@"BORDES"
                                          color:[UIColor colorWithRed:0.24 green:0.44 blue:0.86 alpha:1.0]
                                         action:@selector(selectBordesMode)];
    [modeStack addArrangedSubview:self.roboticoModeButton];
    [modeStack addArrangedSubview:self.bordesModeButton];
    self.modeStatusLabel = [self label:@"No seleccionado" size:12.0
                                 weight:UIFontWeightSemibold
                                  color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    [modeStack addArrangedSubview:self.modeStatusLabel];
    [self.stackView addArrangedSubview:modeCard];

    UILabel *assetTitle = [self label:@"2. SUBE EL ASSET"
                                  size:13.0 weight:UIFontWeightBold color:EXThemeAccentColor()];
    [self.stackView addArrangedSubview:assetTitle];
    [self addFileRow:@"ARCHIVO ASSET" subtitle:@"Selecciona .assets, .bundle o cualquier archivo Unity."
              action:@selector(selectAsset) statusProperty:@"assetStatusLabel"];

    UILabel *pathTitle = [self label:@"PATH ID QUE USA EL FLUJO WEB"
                                   size:13.0 weight:UIFontWeightBold color:EXThemeAccentColor()];
    [self.stackView addArrangedSubview:pathTitle];
    UIView *paths = [self cardView];
    UIStackView *pathStack = [self verticalStackInView:paths spacing:8.0];
    for (NSString *path in HoloArmaPathIDs()) {
        UILabel *row = [self label:path size:12.0 weight:UIFontWeightRegular
                               color:[UIColor colorWithWhite:0.78 alpha:1.0]];
        row.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
        row.numberOfLines = 0;
        [pathStack addArrangedSubview:row];
    }
    [self.stackView addArrangedSubview:paths];

    self.importButton = [self actionButton:@"IMPORTAR SESIÓN LOCAL"
                                      color:EXThemeAccentColor()
                                     action:@selector(importSession)];
    self.importButton.enabled = NO;
    [self.stackView addArrangedSubview:self.importButton];

    self.openButton = [self actionButton:@"ABRIR EN FILES"
                                    color:[UIColor colorWithRed:0.16 green:0.68 blue:0.38 alpha:1.0]
                                   action:@selector(openLastSession)];
    self.openButton.enabled = NO;
    [self.stackView addArrangedSubview:self.openButton];
}

- (UILabel *)label:(NSString *)text
              size:(CGFloat)size
            weight:(UIFontWeight)weight
             color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 1;
    return label;
}

- (UIView *)cardView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    view.layer.cornerRadius = 14.0;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [UIColor colorWithWhite:0.24 alpha:1.0].CGColor;
    return view;
}

- (UIStackView *)verticalStackInView:(UIView *)view spacing:(CGFloat)spacing {
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = spacing;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-14.0],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:13.0],
        [stack.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-13.0]
    ]];
    return stack;
}

- (UIButton *)actionButton:(NSString *)title
                     color:(UIColor *)color
                    action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:0.45 alpha:1.0] forState:UIControlStateDisabled];
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(13.0, 14.0, 13.0, 14.0);
    configuration.baseBackgroundColor = color;
    configuration.baseForegroundColor = UIColor.whiteColor;
    button.configuration = configuration;
    button.layer.cornerRadius = 11.0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)addFileRow:(NSString *)title
          subtitle:(NSString *)subtitle
            action:(SEL)action
   statusProperty:(NSString *)statusProperty {
    UIView *card = [self cardView];
    UIStackView *stack = [self verticalStackInView:card spacing:8.0];
    UILabel *heading = [self label:title size:13.0 weight:UIFontWeightBold
                               color:[UIColor colorWithWhite:0.78 alpha:1.0]];
    UILabel *help = [self label:subtitle size:12.0 weight:UIFontWeightRegular
                                                   color:[UIColor colorWithWhite:0.56 alpha:1.0]];
    help.numberOfLines = 0;
    UILabel *status = [self label:@"No seleccionado" size:12.0 weight:UIFontWeightSemibold
                                                    color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    status.numberOfLines = 2;
    [stack addArrangedSubview:heading];
    [stack addArrangedSubview:help];
    [stack addArrangedSubview:status];

    UIButton *button = [self actionButton:[NSString stringWithFormat:@"ELEGIR %@", title]
                                    color:[UIColor colorWithWhite:0.22 alpha:1.0]
                                   action:action];
    [stack addArrangedSubview:button];
    [self.stackView addArrangedSubview:card];

    if ([statusProperty isEqualToString:@"assetStatusLabel"]) self.assetStatusLabel = status;
}

- (void)selectAsset {
    [self presentPickerForRole:@"asset"
                     extensions:@[@"assets", @"bundle", @"bin", @"bytes"]];
}

- (void)selectRoboticoMode {
    [self selectMode:@"robotico"];
}

- (void)selectBordesMode {
    [self selectMode:@"bordes"];
}

- (void)selectMode:(NSString *)mode {
    self.selectedMode = mode;
    BOOL robotico = [mode isEqualToString:@"robotico"];
    UIColor *selectedColor = robotico
        ? [UIColor colorWithRed:0.86 green:0.25 blue:0.08 alpha:1.0]
        : [UIColor colorWithRed:0.24 green:0.44 blue:0.86 alpha:1.0];
    UIColor *unselectedColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    UIButtonConfiguration *roboticoConfiguration = [self.roboticoModeButton.configuration copy];
    roboticoConfiguration.baseBackgroundColor = robotico ? selectedColor : unselectedColor;
    self.roboticoModeButton.configuration = roboticoConfiguration;
    UIButtonConfiguration *bordesConfiguration = [self.bordesModeButton.configuration copy];
    bordesConfiguration.baseBackgroundColor = robotico ? unselectedColor : selectedColor;
    self.bordesModeButton.configuration = bordesConfiguration;
    self.modeStatusLabel.text = robotico ? @"Modo seleccionado: ROBÓTICO" : @"Modo seleccionado: BORDES";
    self.modeStatusLabel.textColor = selectedColor;
    [self refreshState];
}

- (void)loadBundledDumps {
    self.mainDumpURL = [self copyBundledDump:kHoloArmaMainDump];
    self.roboticoDumpURL = [self copyBundledDump:kHoloArmaRoboticoDump];
    self.paredDumpURL = [self copyBundledDump:kHoloArmaParedDump];
}

- (NSURL *)copyBundledDump:(NSString *)filename {
    NSString *resourcePath = [[NSBundle mainBundle]
        pathForResource:filename.stringByDeletingPathExtension
                 ofType:filename.pathExtension
            inDirectory:@"HoloArma"];
    if (!resourcePath.length) return nil;

    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *defaults = [documents URLByAppendingPathComponent:@"HoloArma/Defaults"
                                                  isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:defaults withIntermediateDirectories:YES
                         attributes:nil error:nil]) return nil;
    NSURL *destination = [defaults URLByAppendingPathComponent:filename];
    if (![fm fileExistsAtPath:destination.path] &&
        ![fm copyItemAtPath:resourcePath toPath:destination.path error:nil]) {
        return nil;
    }
    return destination;
}

- (void)presentPickerForRole:(NSString *)role extensions:(NSArray<NSString *> *)extensions {
    self.pendingRole = role;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *extension in extensions) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type) [types addObject:type];
    }
    if ([role isEqualToString:@"asset"] || types.count == 0) [types addObject:UTTypeData];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                     asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL || self.pendingRole.length == 0) return;
    BOOL accessing = [sourceURL startAccessingSecurityScopedResource];
    NSURL *localURL = [self copyIntoInbox:sourceURL error:nil];
    if (accessing) [sourceURL stopAccessingSecurityScopedResource];
    if (!localURL) {
        [self showMessage:@"No se pudo copiar el archivo seleccionado al workspace local."];
        return;
    }
    if ([self.pendingRole isEqualToString:@"asset"]) self.assetURL = localURL;
    self.pendingRole = nil;
    [self refreshState];
}

- (NSURL *)copyIntoInbox:(NSURL *)sourceURL error:(NSError **)error {
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *inbox = [documents URLByAppendingPathComponent:@"HoloArma/Inbox"
                                               isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:inbox withIntermediateDirectories:YES
                         attributes:nil error:error]) return nil;
    NSString *safeName = sourceURL.lastPathComponent.length
        ? sourceURL.lastPathComponent : @"imported-file";
    NSURL *destination = [inbox URLByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, safeName]];
    if (![fm copyItemAtURL:sourceURL toURL:destination error:error]) return nil;
    return destination;
}

- (void)refreshState {
    self.assetStatusLabel.text = self.assetURL.lastPathComponent ?: @"No seleccionado";
    BOOL ready = self.assetURL && self.selectedMode.length > 0 &&
        self.mainDumpURL && self.roboticoDumpURL && self.paredDumpURL;
    self.importButton.enabled = ready && !self.busy;
    self.openButton.enabled = self.lastSessionURL != nil && !self.busy;
    UIColor *green = [UIColor colorWithRed:0.20 green:0.82 blue:0.40 alpha:1.0];
    self.assetStatusLabel.textColor = self.assetURL ? green
        : [UIColor colorWithWhite:0.58 alpha:1.0];
}

- (void)importSession {
    if (self.busy || !self.assetURL || !self.selectedMode.length ||
        !self.mainDumpURL ||
        !self.roboticoDumpURL || !self.paredDumpURL) return;
    self.busy = YES;
    [self refreshState];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *sessionURL = [self createSession:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!sessionURL) {
                [self refreshState];
                [self showMessage:error.localizedDescription ?: @"No se pudo importar la sesión."];
                return;
            }
            self.lastSessionURL = sessionURL;
            [self refreshState];
            [self showMessage:[NSString stringWithFormat:
                               @"Sesión %@ importada. El asset y los tres dumps incluidos quedaron guardados junto con sus Path ID.",
                               [self.selectedMode isEqualToString:@"robotico"] ? @"ROBÓTICO" : @"BORDES"]];
        });
    });
}

- (NSURL *)createSession:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *root = [documents URLByAppendingPathComponent:@"HoloArma/Sessions"
                                              isDirectory:YES];
    NSURL *session = [root URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"HoloArma-%@", NSUUID.UUID.UUIDString]
                                             isDirectory:YES];
    if (![fm createDirectoryAtURL:session withIntermediateDirectories:YES
                         attributes:nil error:error]) return nil;

    NSArray<NSURL *> *sources = @[self.assetURL, self.mainDumpURL,
                                  self.roboticoDumpURL, self.paredDumpURL];
    NSArray<NSString *> *names = @[@"asset", @"dump-principal",
                                   @"dump-robotico", @"dump-pared"];
    NSMutableArray *files = [NSMutableArray array];
    for (NSUInteger i = 0; i < sources.count; i++) {
        NSString *extension = sources[i].pathExtension.length
            ? [@"." stringByAppendingString:sources[i].pathExtension] : @"";
        NSURL *destination = [session URLByAppendingPathComponent:
                              [names[i] stringByAppendingString:extension]];
        if (![fm copyItemAtURL:sources[i] toURL:destination error:error]) return nil;
        [files addObject:destination.lastPathComponent];
    }
    NSDictionary *manifest = @{
        @"action": @"holoarma",
        @"mode": self.selectedMode ?: @"",
        @"createdAt": [NSDate date],
        @"files": files,
        @"pathIds": @[
            @(3504935391519681939LL),
            @(-3333330928057165289LL),
            @(893500320385684910LL),
            @(-6752853195891321129LL)
        ],
        @"sourceNames": @[
            self.assetURL.lastPathComponent ?: @"",
            self.mainDumpURL.lastPathComponent ?: @"",
            self.roboticoDumpURL.lastPathComponent ?: @"",
            self.paredDumpURL.lastPathComponent ?: @""
        ]
    };
    NSURL *manifestURL = [session URLByAppendingPathComponent:@"manifest.plist"];
    if (![manifest writeToURL:manifestURL atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"com.external.holoarma"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        @"No se pudo escribir el manifiesto de la sesión."}];
        return nil;
    }
    return session;
}

- (void)openLastSession {
    if (!self.lastSessionURL) return;
    FilesViewController *files = [[FilesViewController alloc]
        initWithDirectoryURL:self.lastSessionURL appName:@"Holograma Arma" bundleID:nil];
    [self.navigationController pushViewController:files animated:YES];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Holograma Arma"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end