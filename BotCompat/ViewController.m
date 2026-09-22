#import "ViewController.h"
#import "PatchProjectsViewController.h"
#import "CleanerViewController.h"
#import "HoloArmaViewController.h"
#import "SettingsViewController.h"
#import "FilesViewController.h"
#import "Localization.h"
#import "SandboxAccessBridge.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>

static UIColor *RX7Color(NSString *hex) {
    NSString *value = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned long long number = 0;
    [[NSScanner scannerWithString:value] scanHexLongLong:&number];
    return [UIColor colorWithRed:((number >> 16) & 0xFF) / 255.0
                           green:((number >> 8) & 0xFF) / 255.0
                            blue:(number & 0xFF) / 255.0
                           alpha:1.0];
}

// These values intentionally follow the live Venom Modz panel rather than
// the default iOS dark palette shown by the previous compatibility screen.
static UIColor *RX7Background(void) { return RX7Color(@"#12080D"); }
static UIColor *RX7Surface(void) { return RX7Color(@"#241018"); }
static UIColor *RX7Surface2(void) { return RX7Color(@"#351421"); }
static UIColor *RX7Border(void) { return RX7Color(@"#713149"); }
static UIColor *RX7Muted(void) { return RX7Color(@"#C09AAA"); }

@interface RX7GradientButton : UIButton
@property (nonatomic, strong) UIColor *rxStartColor;
@property (nonatomic, strong) UIColor *rxEndColor;
@end

@implementation RX7GradientButton

- (void)layoutSubviews {
    [super layoutSubviews];
    CAGradientLayer *gradient = nil;
    for (CALayer *layer in self.layer.sublayers) {
        if ([layer.name isEqualToString:@"RX7GradientLayer"]) {
            gradient = (CAGradientLayer *)layer;
            break;
        }
    }
    if (!gradient) {
        gradient = [CAGradientLayer layer];
        gradient.name = @"RX7GradientLayer";
        gradient.startPoint = CGPointMake(0.0, 0.1);
        gradient.endPoint = CGPointMake(1.0, 0.9);
        [self.layer insertSublayer:gradient atIndex:0];
    }
    gradient.frame = self.bounds;
    gradient.cornerRadius = 12.0;
    gradient.colors = @[
        (id)(self.rxStartColor ?: UIColor.clearColor).CGColor,
        (id)(self.rxEndColor ?: UIColor.clearColor).CGColor
    ];
}

@end

@interface ViewController () <UIDocumentPickerDelegate>
@property (nonatomic) BOOL homeMode;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UISegmentedControl *categoryControl;
@property (nonatomic, strong) UIStackView *actionStack;
@property (nonatomic, strong) UIView *assetCard;
@property (nonatomic, strong) UILabel *assetNameLabel;
@property (nonatomic, strong) UILabel *assetHintLabel;
@property (nonatomic, strong) UIView *statusCard;
@property (nonatomic, strong) UILabel *statusTitleLabel;
@property (nonatomic, strong) UILabel *statusDetailLabel;
@property (nonatomic, strong) UIActivityIndicatorView *activity;
@property (nonatomic, strong) UIView *drawerOverlay;
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) NSURL *assetURL;
@property (nonatomic, copy) NSString *pendingAction;
@property (nonatomic, copy) NSString *pendingRole;
@property (nonatomic, copy) NSString *oloFirstColor;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) UIButton *menuButton;
@end

@implementation ViewController

- (instancetype)initWithHomeMode:(BOOL)homeMode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) _homeMode = homeMode;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RX7Background();
    self.navigationController.navigationBarHidden = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshAppearance)
                                                 name:EXThemeDidChangeNotification
                                               object:nil];
    [self buildDashboard];
    [self buildDrawer];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Dashboard

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)card {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = RX7Color(@"#241018");
    card.layer.cornerRadius = 16.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = RX7Border().CGColor;
    return card;
}

- (void)buildDashboard {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIView *content = [[UIView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor]
    ]];

    self.contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 14.0;
    [content addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [self.contentStack.topAnchor constraintEqualToAnchor:content.safeAreaLayoutGuide.topAnchor constant:10.0],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-28.0]
    ]];

    [self buildHeader];
    [self buildTelegramBar];
    [self buildAssetCard];
    [self buildCategoryCard];
    [self buildStatusCard];
}

- (void)buildHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentStack addArrangedSubview:header];
    [header.heightAnchor constraintEqualToConstant:76.0].active = YES;

    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.menuButton setImage:[UIImage systemImageNamed:@"line.3.horizontal"] forState:UIControlStateNormal];
    self.menuButton.tintColor = UIColor.whiteColor;
    self.menuButton.backgroundColor = RX7Surface2();
    self.menuButton.layer.cornerRadius = 10.0;
    self.menuButton.accessibilityLabel = @"Abrir menú";
    [self.menuButton addTarget:self action:@selector(openDrawer) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.menuButton];

    UIImage *logoImage = [[UIImage imageNamed:@"ExternalIcon"]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *logo = [[UIImageView alloc] initWithImage:logoImage];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.tintColor = RX7Color(@"#FF315F");
    logo.layer.cornerRadius = 10.0;
    logo.clipsToBounds = YES;
    [header addSubview:logo];

    UILabel *title = [self label:@"RX7 MODZ" size:19.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];
    UILabel *subtitle = [self label:@"GUEBO XIT" size:9.0 weight:UIFontWeightSemibold color:RX7Muted()];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:subtitle];

    UILabel *offline = [self label:@"ACCESS PREMIUM" size:9.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    offline.translatesAutoresizingMaskIntoConstraints = NO;
    offline.textAlignment = NSTextAlignmentCenter;
    offline.backgroundColor = RX7Color(@"#F02A6B");
    offline.layer.cornerRadius = 8.0;
    offline.layer.borderWidth = 1.0;
    offline.layer.borderColor = RX7Color(@"#FF6D9B").CGColor;
    offline.clipsToBounds = YES;
    [header addSubview:offline];

    UILabel *online = [self label:@"● Online" size:12.0 weight:UIFontWeightRegular color:RX7Color(@"#9EE6B9")];
    online.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:online];

    [NSLayoutConstraint activateConstraints:@[
        [self.menuButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [self.menuButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.menuButton.widthAnchor constraintEqualToConstant:40.0],
        [self.menuButton.heightAnchor constraintEqualToConstant:40.0],
        [logo.leadingAnchor constraintEqualToAnchor:self.menuButton.trailingAnchor constant:10.0],
        [logo.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [logo.widthAnchor constraintEqualToConstant:40.0],
        [logo.heightAnchor constraintEqualToConstant:40.0],
        [title.leadingAnchor constraintEqualToAnchor:logo.trailingAnchor constant:10.0],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:8.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3.0],
        [online.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [online.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:5.0],
        [offline.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8.0],
        [offline.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [offline.topAnchor constraintEqualToAnchor:header.topAnchor constant:11.0],
        [offline.widthAnchor constraintEqualToConstant:121.0],
        [offline.heightAnchor constraintEqualToConstant:25.0],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:offline.leadingAnchor constant:-8.0]
    ]];
}

- (void)buildTelegramBar {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = RX7Color(@"#351421");
    bar.layer.borderColor = RX7Color(@"#713149").CGColor;
    bar.layer.borderWidth = 1.0;
    bar.layer.cornerRadius = 14.0;
    [self.contentStack addArrangedSubview:bar];
    [bar.heightAnchor constraintEqualToConstant:58.0].active = YES;

    UIButton *telegram = [UIButton buttonWithType:UIButtonTypeSystem];
    telegram.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.baseBackgroundColor = RX7Color(@"#ED2B74");
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.title = @"Telegram";
    configuration.image = [UIImage systemImageNamed:@"paperplane.fill"];
    configuration.imagePadding = 7.0;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(9.0, 18.0, 9.0, 18.0);
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    telegram.configuration = configuration;
    telegram.layer.shadowColor = RX7Color(@"#ED2B74").CGColor;
    telegram.layer.shadowOpacity = 0.35;
    telegram.layer.shadowRadius = 8.0;
    telegram.layer.shadowOffset = CGSizeMake(0, 3);
    [telegram addTarget:self action:@selector(openTelegram) forControlEvents:UIControlEventTouchUpInside];
    telegram.accessibilityLabel = @"Abrir Telegram";
    [bar addSubview:telegram];
    [NSLayoutConstraint activateConstraints:@[
        [telegram.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
        [telegram.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [telegram.heightAnchor constraintEqualToConstant:42.0]
    ]];
}

- (void)buildAssetCard {
    self.assetCard = [self card];
    self.assetCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.assetCard.backgroundColor = RX7Color(@"#241018");
    self.assetCard.layer.borderColor = RX7Color(@"#8C3D58").CGColor;
    [self.contentStack addArrangedSubview:self.assetCard];

    UILabel *title = [self label:@"ARCHIVO FREE FIRE" size:13.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.assetCard addSubview:title];
    UILabel *description = [self label:@"Arrastra o toca para subir" size:14.0 weight:UIFontWeightRegular color:RX7Muted()];
    description.translatesAutoresizingMaskIntoConstraints = NO;
    [self.assetCard addSubview:description];

    UIButton *pickerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    pickerButton.translatesAutoresizingMaskIntoConstraints = NO;
    pickerButton.backgroundColor = RX7Color(@"#38131F");
    pickerButton.layer.cornerRadius = 12.0;
    pickerButton.layer.borderWidth = 1.0;
    pickerButton.layer.borderColor = RX7Color(@"#9E3B5E").CGColor;
    pickerButton.tintColor = RX7Color(@"#FF4D74");
    [pickerButton setImage:[UIImage systemImageNamed:@"arrow.up.doc.fill"] forState:UIControlStateNormal];
    [pickerButton addTarget:self action:@selector(selectAsset) forControlEvents:UIControlEventTouchUpInside];
    [self.assetCard addSubview:pickerButton];

    self.assetNameLabel = [self label:@"Arrastra o toca para subir" size:14.0 weight:UIFontWeightRegular color:RX7Muted()];
    self.assetNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.assetNameLabel.textAlignment = NSTextAlignmentCenter;
    self.assetNameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.assetCard addSubview:self.assetNameLabel];
    self.assetHintLabel = [self label:@".assets / .bundle / cualquier extensión" size:12.0 weight:UIFontWeightRegular color:RX7Color(@"#FF4D74")];
    self.assetHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.assetHintLabel.textAlignment = NSTextAlignmentCenter;
    [self.assetCard addSubview:self.assetHintLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:self.assetCard.leadingAnchor constant:16.0],
        [title.trailingAnchor constraintEqualToAnchor:self.assetCard.trailingAnchor constant:-16.0],
        [title.topAnchor constraintEqualToAnchor:self.assetCard.topAnchor constant:15.0],
        [description.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [description.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [description.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5.0],
        [pickerButton.leadingAnchor constraintEqualToAnchor:self.assetCard.leadingAnchor constant:12.0],
        [pickerButton.trailingAnchor constraintEqualToAnchor:self.assetCard.trailingAnchor constant:-12.0],
        [pickerButton.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:10.0],
        [pickerButton.bottomAnchor constraintEqualToAnchor:self.assetCard.bottomAnchor constant:-12.0],
        [pickerButton.heightAnchor constraintGreaterThanOrEqualToConstant:120.0],
        [self.assetNameLabel.centerXAnchor constraintEqualToAnchor:pickerButton.centerXAnchor],
        [self.assetNameLabel.centerYAnchor constraintEqualToAnchor:pickerButton.centerYAnchor constant:19.0],
        [self.assetNameLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:pickerButton.leadingAnchor constant:35.0],
        [self.assetNameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:pickerButton.trailingAnchor constant:-12.0],
        [self.assetHintLabel.centerXAnchor constraintEqualToAnchor:pickerButton.centerXAnchor],
        [self.assetHintLabel.topAnchor constraintEqualToAnchor:self.assetNameLabel.bottomAnchor constant:6.0]
    ]];
    [pickerButton setTitle:@"  " forState:UIControlStateNormal];
    pickerButton.accessibilityLabel = @"Seleccionar archivo Free Fire";
}

- (void)buildCategoryCard {
    UIView *card = [self card];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentStack addArrangedSubview:card];

    UILabel *heading = [self label:@"HERRAMIENTAS" size:13.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:heading];
    self.categoryControl = [[UISegmentedControl alloc] initWithItems:@[@"IOS", @"TEXTURAS", @"IGUALADOR"]];
    self.categoryControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoryControl.selectedSegmentIndex = 0;
    self.categoryControl.backgroundColor = RX7Color(@"#351421");
    self.categoryControl.selectedSegmentTintColor = RX7Color(@"#F02A6B");
    [self.categoryControl setTitleTextAttributes:@{NSForegroundColorAttributeName: RX7Muted(),
                                                     NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold]}
                                          forState:UIControlStateNormal];
    [self.categoryControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                                     NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold]}
                                          forState:UIControlStateSelected];
    [self.categoryControl addTarget:self action:@selector(categoryChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:self.categoryControl];

    self.actionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.actionStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionStack.axis = UILayoutConstraintAxisVertical;
    self.actionStack.spacing = 9.0;
    [card addSubview:self.actionStack];
    [NSLayoutConstraint activateConstraints:@[
        [heading.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [heading.topAnchor constraintEqualToAnchor:card.topAnchor constant:15.0],
        [self.categoryControl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [self.categoryControl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [self.categoryControl.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:10.0],
        [self.categoryControl.heightAnchor constraintEqualToConstant:34.0],
        [self.actionStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [self.actionStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [self.actionStack.topAnchor constraintEqualToAnchor:self.categoryControl.bottomAnchor constant:14.0],
        [self.actionStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0]
    ]];
    [self rebuildActionStack];
}

- (NSArray<NSDictionary *> *)actionsForCategory:(NSInteger)category {
    if (category == 1) {
        return @[
            @{@"id": @"pared-gloo", @"title": @"PARED GLOO", @"subtitle": @"Texturas IceWall_Bunker", @"icon": @"square.grid.3x3.fill", @"color": @"#06B6D4", @"end": @"#2563EB"},
            @{@"id": @"olo-robotico", @"title": @"OLO ROBÓTICO", @"subtitle": @"Shader y textura robot", @"icon": @"cpu.fill", @"color": @"#8B5CF6", @"end": @"#DB2777"}
        ];
    }
    if (category == 2) {
        return @[
            @{@"id": @"weight", @"title": @"VER PESO MODIFICADO", @"subtitle": @"Revisa bytes y CRC32", @"icon": @"scalemass.fill", @"color": @"#0284C7", @"end": @"#2563EB"},
            @{@"id": @"lz4", @"title": @"COMPRIMIR LZ4", @"subtitle": @"Recomprime el bundle", @"icon": @"archivebox.fill", @"color": @"#2563EB", @"end": @"#4F46E5"},
            @{@"id": @"equalize", @"title": @"IGUALAR AL ORIGINAL", @"subtitle": @"Clona peso y CRC32 exactos", @"icon": @"arrow.left.arrow.right", @"color": @"#9333EA", @"end": @"#DB2777"},
            @{@"id": @"spoof", @"title": @"SPOOF CRC32", @"subtitle": @"Usa el archivo original", @"icon": @"checkmark.seal.fill", @"color": @"#DB2777", @"end": @"#BE185D"}
        ];
    }
    return @[
        @{@"id": @"holoarma", @"title": @"HOLOGRAMA ARMA", @"subtitle": @"BORDES o ROBÓTICO", @"icon": @"flame.fill", @"color": @"#F97316", @"end": @"#FBBF24"},
        @{@"id": @"avatar", @"title": @"AVATAR", @"subtitle": @"Con antena o sin antena", @"icon": @"person.crop.circle.badge.checkmark", @"color": @"#10B981", @"end": @"#06B6D4"},
        @{@"id": @"cache", @"title": @"CACHE", @"subtitle": @"Aimbot y bala mágica", @"icon": @"internaldrive.fill", @"color": @"#F59E0B", @"end": @"#F97316"},
        @{@"id": @"walkc", @"title": @"WALKC HACK", @"subtitle": @"Importación WalkC", @"icon": @"bolt.fill", @"color": @"#EF4444", @"end": @"#F97316"},
        @{@"id": @"olopersonaje", @"title": @"OLO PERSONAJE", @"subtitle": @"Elige dos colores", @"icon": @"paintpalette.fill", @"color": @"#A855F7", @"end": @"#DB2777"},
        @{@"id": @"cielo", @"title": @"CIELO MOD", @"subtitle": @"Cielo y ambiente", @"icon": @"cloud.sun.fill", @"color": @"#06B6D4", @"end": @"#2563EB"}
    ];
}

- (void)rebuildActionStack {
    for (UIView *view in [self.actionStack.arrangedSubviews copy]) {
        [self.actionStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray *actions = [self actionsForCategory:self.categoryControl.selectedSegmentIndex];
    for (NSDictionary *action in actions) {
        UIButton *button = [self actionButton:action];
        [self.actionStack addArrangedSubview:button];
        [button.heightAnchor constraintEqualToConstant:78.0].active = YES;
    }
}

- (UIButton *)actionButton:(NSDictionary *)action {
    RX7GradientButton *button = [RX7GradientButton buttonWithType:UIButtonTypeSystem];
    button.accessibilityIdentifier = action[@"id"];
    button.accessibilityLabel = action[@"title"];
    button.rxStartColor = RX7Color(action[@"color"]);
    button.rxEndColor = RX7Color(action[@"end"] ?: action[@"color"]);
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.baseBackgroundColor = UIColor.clearColor;
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.title = action[@"title"];
    configuration.subtitle = action[@"subtitle"];
    configuration.image = [UIImage systemImageNamed:action[@"icon"]];
    configuration.imagePlacement = NSDirectionalRectEdgeTop;
    configuration.imagePadding = 5.0;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(8.0, 5.0, 8.0, 5.0);
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = configuration;
    button.tintColor = UIColor.whiteColor;
    button.layer.shadowColor = RX7Color(action[@"color"]).CGColor;
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowRadius = 8.0;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    button.clipsToBounds = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [button addTarget:self action:@selector(actionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildStatusCard {
    self.statusCard = [self card];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentStack addArrangedSubview:self.statusCard];
    self.statusCard.backgroundColor = RX7Color(@"#111A20");
    self.statusCard.layer.borderColor = RX7Color(@"#34D399").CGColor;

    self.activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activity.translatesAutoresizingMaskIntoConstraints = NO;
    self.activity.color = RX7Color(@"#A855F7");
    [self.statusCard addSubview:self.activity];
    self.statusTitleLabel = [self label:@"LISTO PARA IMPORTAR" size:12.0 weight:UIFontWeightBold color:RX7Color(@"#A78BFA")];
    self.statusTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusCard addSubview:self.statusTitleLabel];
    self.statusDetailLabel = [self label:@"Selecciona un asset y después elige una herramienta." size:11.0 weight:UIFontWeightRegular color:RX7Muted()];
    self.statusDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusCard addSubview:self.statusDetailLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.activity.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:16.0],
        [self.activity.centerYAnchor constraintEqualToAnchor:self.statusCard.centerYAnchor],
        [self.statusTitleLabel.leadingAnchor constraintEqualToAnchor:self.activity.trailingAnchor constant:10.0],
        [self.statusTitleLabel.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-14.0],
        [self.statusTitleLabel.topAnchor constraintEqualToAnchor:self.statusCard.topAnchor constant:13.0],
        [self.statusDetailLabel.leadingAnchor constraintEqualToAnchor:self.statusTitleLabel.leadingAnchor],
        [self.statusDetailLabel.trailingAnchor constraintEqualToAnchor:self.statusTitleLabel.trailingAnchor],
        [self.statusDetailLabel.topAnchor constraintEqualToAnchor:self.statusTitleLabel.bottomAnchor constant:4.0],
        [self.statusDetailLabel.bottomAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:-13.0]
    ]];
}

- (void)categoryChanged:(UISegmentedControl *)sender {
    [self rebuildActionStack];
}

- (void)openTelegram {
    NSURL *url = [NSURL URLWithString:@"https://t.me/black_ios12"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - Drawer

- (void)buildDrawer {
    self.drawerOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.drawerOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawerOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    self.drawerOverlay.hidden = YES;
    [self.view addSubview:self.drawerOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [self.drawerOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.drawerOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawerOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawerOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeDrawer)];
    [self.drawerOverlay addGestureRecognizer:tap];

    self.drawer = [[UIView alloc] initWithFrame:CGRectZero];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = RX7Surface();
    self.drawer.layer.borderColor = RX7Border().CGColor;
    self.drawer.layer.borderWidth = 1.0;
    self.drawer.hidden = YES;
    [self.view addSubview:self.drawer];
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:290.0]
    ]];

    UILabel *drawerTitle = [self label:@"RX7 MODZ" size:18.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    drawerTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.drawer addSubview:drawerTitle];
    UILabel *drawerSubtitle = [self label:@"ACCESS PREMIUM  ·  ONLINE" size:9.0 weight:UIFontWeightSemibold color:RX7Muted()];
    drawerSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.drawer addSubview:drawerSubtitle];
    UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = RX7Border();
    [self.drawer addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [drawerTitle.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor constant:22.0],
        [drawerTitle.topAnchor constraintEqualToAnchor:self.drawer.safeAreaLayoutGuide.topAnchor constant:22.0],
        [drawerSubtitle.leadingAnchor constraintEqualToAnchor:drawerTitle.leadingAnchor],
        [drawerSubtitle.topAnchor constraintEqualToAnchor:drawerTitle.bottomAnchor constant:5.0],
        [line.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor constant:16.0],
        [line.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor constant:-16.0],
        [line.topAnchor constraintEqualToAnchor:drawerSubtitle.bottomAnchor constant:20.0],
        [line.heightAnchor constraintEqualToConstant:1.0]
    ]];

    NSArray *items = @[
        @{@"title": @"INICIO", @"icon": @"house.fill", @"selector": @"goHome"},
        @{@"title": @"ARCHIVOS", @"icon": @"folder.fill", @"selector": @"openFiles"},
        @{@"title": @"ALL MANUAL", @"icon": @"wrench.and.screwdriver.fill", @"selector": @"openPatches"},
        @{@"title": @"LIMPIADOR", @"icon": @"trash.fill", @"selector": @"openCleaner"},
        @{@"title": @"AJUSTES", @"icon": @"gearshape.fill", @"selector": @"openSettings"}
    ];
    UIStackView *menu = [[UIStackView alloc] initWithFrame:CGRectZero];
    menu.translatesAutoresizingMaskIntoConstraints = NO;
    menu.axis = UILayoutConstraintAxisVertical;
    menu.spacing = 5.0;
    [self.drawer addSubview:menu];
    [NSLayoutConstraint activateConstraints:@[
        [menu.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor constant:12.0],
        [menu.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor constant:-12.0],
        [menu.topAnchor constraintEqualToAnchor:line.bottomAnchor constant:13.0]
    ]];
    for (NSDictionary *item in items) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = item[@"selector"];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.backgroundColor = UIColor.clearColor;
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.baseForegroundColor = RX7Muted();
        configuration.image = [UIImage systemImageNamed:item[@"icon"]];
        configuration.title = item[@"title"];
        configuration.imagePadding = 12.0;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0.0, 13.0, 0.0, 10.0);
        button.configuration = configuration;
        button.layer.cornerRadius = 10.0;
        [button addTarget:self action:@selector(drawerItemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [menu addArrangedSubview:button];
        [button.heightAnchor constraintEqualToConstant:46.0].active = YES;
    }
}

- (void)openDrawer {
    self.drawerOverlay.hidden = NO;
    self.drawer.hidden = NO;
    self.drawerOverlay.alpha = 0.0;
    self.drawer.transform = CGAffineTransformMakeTranslation(-290.0, 0);
    [UIView animateWithDuration:0.22 animations:^{
        self.drawerOverlay.alpha = 1.0;
        self.drawer.transform = CGAffineTransformIdentity;
    }];
}

- (void)closeDrawer {
    [UIView animateWithDuration:0.18 animations:^{
        self.drawerOverlay.alpha = 0.0;
        self.drawer.transform = CGAffineTransformMakeTranslation(-290.0, 0);
    } completion:^(BOOL finished) {
        self.drawerOverlay.hidden = YES;
        self.drawer.hidden = YES;
    }];
}

- (void)drawerItemTapped:(UIButton *)sender {
    [self closeDrawer];
    NSString *selector = sender.accessibilityIdentifier;
    if ([selector isEqualToString:@"goHome"]) return;
    if ([selector isEqualToString:@"openFiles"]) return [self openFiles];
    if ([selector isEqualToString:@"openPatches"]) return [self openPatches];
    if ([selector isEqualToString:@"openCleaner"]) return [self openCleaner];
    if ([selector isEqualToString:@"openSettings"]) return [self openSettings];
}

#pragma mark - Asset and actions

- (void)selectAsset {
    self.pendingRole = @"asset";
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL || ![self.pendingRole isEqualToString:@"asset"]) return;
    BOOL access = [sourceURL startAccessingSecurityScopedResource];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *inbox = [documents URLByAppendingPathComponent:@"RX7Panel/Inbox" isDirectory:YES];
    [fm createDirectoryAtURL:inbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *target = [inbox URLByAppendingPathComponent:sourceURL.lastPathComponent ?: @"asset.bin"];
    [fm removeItemAtURL:target error:nil];
    NSError *error = nil;
    BOOL copied = [fm copyItemAtURL:sourceURL toURL:target error:&error];
    if (access) [sourceURL stopAccessingSecurityScopedResource];
    if (!copied) {
        [self showError:error.localizedDescription ?: @"No se pudo copiar el asset al espacio local."];
        return;
    }
    self.assetURL = target;
    self.assetNameLabel.text = target.lastPathComponent;
    self.assetNameLabel.textColor = RX7Color(@"#D8B4FE");
    self.assetHintLabel.text = @"Asset guardado en RX7Panel/Inbox";
    self.statusTitleLabel.text = @"ASSET LISTO";
    self.statusTitleLabel.textColor = RX7Color(@"#34D399");
    self.statusDetailLabel.text = @"Los dumps se incluyen automáticamente al iniciar una acción.";
    self.pendingRole = nil;
}

- (void)actionButtonTapped:(UIButton *)sender {
    [self handleAction:sender.accessibilityIdentifier];
}

- (void)handleAction:(NSString *)action {
    if ([action isEqualToString:@"holoarma"]) {
        if (!self.assetURL) {
            [self showAssetRequired];
            return;
        }
        HoloArmaViewController *holo = [[HoloArmaViewController alloc] initWithAssetURL:self.assetURL];
        [self.navigationController pushViewController:holo animated:YES];
        return;
    }
    if (!self.assetURL) {
        [self showAssetRequired];
        return;
    }
    self.pendingAction = action;
    if ([action isEqualToString:@"avatar"]) {
        [self presentChoice:@"AVATAR"
                    message:@"¿QUÉ DESEAS? Elige una variante. Los dumps male y female se cargan automáticamente."
                   choices:@[@"SIN ANTENA · AIMBOT PECHO",
                             @"SIN ANTENA · AIM DRAG",
                             @"SIN ANTENA · AIMBOT CABEZA",
                             @"SIN ANTENA · AIMBOT CUELLO",
                             @"SIN ANTENA · BALAS MÁGICA",
                             @"CON ANTENA · AIMBOT PECHO",
                             @"CON ANTENA · AIM DRAG",
                             @"CON ANTENA · AIMBOT CABEZA",
                             @"CON ANTENA · AIMBOT CUELLO",
                             @"CON ANTENA · BALAS MÁGICA"]];
        return;
    }
    if ([action isEqualToString:@"cache"]) {
        [self presentChoice:@"CACHE"
                    message:@"¿QUÉ DESEAS? Se eliminarán los CACHE viejos y se agregarán los nuevos desde Dumps."
                   choices:@[@"BALA MÁGICA · MEDIO ALCANCE",
                             @"BALA MÁGICA · LARGO ALCANCE",
                             @"BALA MÁGICA · BAJO ALCANCE",
                             @"AIMBOT PECHO",
                             @"AIMBOT PECTORAL 80%",
                             @"AIMBOT DRAG",
                             @"AIMBOT CUELLO",
                             @"AIMBOT BODY"]];
        return;
    }
    if ([action isEqualToString:@"olopersonaje"]) {
        self.oloFirstColor = nil;
        [self presentOloColorStep:1];
        return;
    }
    if ([action isEqualToString:@"pared-gloo"]) {
        [self presentChoice:@"PARED GLOO"
                    message:@"Se usarán automáticamente las texturas incluidas. ¿Procesar el asset?"
                   choices:@[@"PROCESAR"]];
        return;
    }
    if ([action isEqualToString:@"olo-robotico"]) {
        [self presentChoice:@"OLO ROBÓTICO"
                    message:@"Se incluirán el shader robótico y los Path ID de la web. ¿Continuar?"
                   choices:@[@"PROCESAR"]];
        return;
    }
    if ([action isEqualToString:@"cielo"]) {
        [self presentChoice:@"CIELO MOD"
                    message:@"El cielo se prepara con los dumps internos. ¿Continuar con este asset?"
                   choices:@[@"PROCESAR"]];
        return;
    }
    if ([action isEqualToString:@"walkc"]) {
        [self presentChoice:@"WALKC HACK"
                    message:@"Esta acción prepara el asset para el flujo WalkC local. ¿Continuar?"
                   choices:@[@"PROCESAR"]];
        return;
    }
    if ([action isEqualToString:@"weight"] || [action isEqualToString:@"lz4"] ||
        [action isEqualToString:@"equalize"] || [action isEqualToString:@"spoof"]) {
        [self presentChoice:@"IGUALADOR"
                    message:@"Elige la operación para el asset seleccionado."
                   choices:@[@"CONTINUAR"]];
        return;
    }
    [self stageCurrentAction:self.pendingAction option:nil];
}

- (void)presentChoice:(NSString *)title message:(NSString *)message choices:(NSArray<NSString *> *)choices {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *choice in choices) {
        [alert addAction:[UIAlertAction actionWithTitle:choice style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if ([self.pendingAction isEqualToString:@"avatar"] ||
                [self.pendingAction isEqualToString:@"cache"]) {
                [self confirmWebSelection:action.title];
            } else {
                [self stageCurrentAction:self.pendingAction option:action.title];
            }
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"CANCELAR" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmWebSelection:(NSString *)option {
    NSString *title = [NSString stringWithFormat:@"¿SEGURO DE GENERAR %@?", option];
    NSString *message = [self.pendingAction isEqualToString:@"cache"]
        ? @"Se eliminarán los CACHE viejos y se agregarán los nuevos desde la carpeta Dumps. Recuerda que estos productos son VIP; visita Telegram para recibir soporte."
        : @"Se usarán automáticamente los dumps male y female correspondientes. ¿Quieres continuar?";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"NO" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"SÍ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self stageCurrentAction:self.pendingAction option:option];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentOloColorStep:(NSUInteger)step {
    NSString *title = step == 1 ? @"¿DE QUÉ COLOR QUIERES TU PERSONAJE?"
                                : @"¿DE QUÉ COLOR QUIERES TU ROBÓTICO?";
    NSString *message = step == 1
        ? @"Paso 1 de 2 · Elige el color de OLO PERSONAJE."
        : @"Paso 2 de 2 · Elige el color del modo ROBÓTICO.";
    NSArray *colors = @[@"ROJO", @"AZUL", @"VERDE", @"MORADO",
                        @"ROSA", @"AMARILLO", @"BLANCO", @"NEGRO"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *color in colors) {
        [alert addAction:[UIAlertAction actionWithTitle:color style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (step == 1) {
                self.oloFirstColor = action.title;
                [self presentOloColorStep:2];
            } else {
                NSString *option = [NSString stringWithFormat:@"PERSONAJE: %@ · ROBÓTICO: %@",
                                    self.oloFirstColor ?: @"ROJO", action.title];
                [self confirmWebSelection:option];
            }
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"CANCELAR" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAssetRequired {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ARCHIVO FREE FIRE"
                                                                     message:@"Primero selecciona el asset o bundle. No necesitas subir ningún dump: el panel los incluye automáticamente."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"SELECCIONAR ASSET" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self selectAsset];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"CANCELAR" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)stageCurrentAction:(NSString *)action option:(NSString *)option {
    if (self.busy || !self.assetURL) return;
    self.busy = YES;
    self.statusTitleLabel.text = [NSString stringWithFormat:@"PREPARANDO %@", action.uppercaseString];
    self.statusTitleLabel.textColor = RX7Color(@"#FBBF24");
    self.statusDetailLabel.text = @"Copiando el asset y todos los dumps compatibles...";
    [self.activity startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *session = [self createSessionForAction:action option:option error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self.activity stopAnimating];
            if (!session) {
                self.statusTitleLabel.text = @"ERROR DE IMPORTACIÓN";
                self.statusTitleLabel.textColor = RX7Color(@"#F87171");
                self.statusDetailLabel.text = error.localizedDescription ?: @"No se pudo crear la sesión local.";
                [self showError:self.statusDetailLabel.text];
                return;
            }
            self.statusTitleLabel.text = @"SESIÓN PREPARADA";
            self.statusTitleLabel.textColor = RX7Color(@"#34D399");
            self.statusDetailLabel.text = [NSString stringWithFormat:@"Asset y dumps guardados en %@. Abre ARCHIVOS para revisarlos.", session.lastPathComponent];
            [self showStagedNotice:session action:action];
        });
    });
}

- (NSURL *)createSessionForAction:(NSString *)action option:(NSString *)option error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *safeAction = [[action stringByReplacingOccurrencesOfString:@"/" withString:@"-"] uppercaseString];
    NSURL *root = [documents URLByAppendingPathComponent:@"RX7Panel/Sessions" isDirectory:YES];
    NSURL *session = [root URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", safeAction, NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![fm createDirectoryAtURL:session withIntermediateDirectories:YES attributes:nil error:error]) return nil;

    NSString *extension = self.assetURL.pathExtension.length ? [@"." stringByAppendingString:self.assetURL.pathExtension] : @".bin";
    NSURL *input = [session URLByAppendingPathComponent:[@"input" stringByAppendingString:extension]];
    if (![fm copyItemAtURL:self.assetURL toURL:input error:error]) return nil;

    NSMutableArray *dumpFiles = [NSMutableArray array];
    NSMutableArray<NSString *> *resourcePaths =
        [[[NSBundle mainBundle] pathsForResourcesOfType:@"txt" inDirectory:nil] mutableCopy]
        ?: [NSMutableArray array];
    for (NSString *name in @[@"oloarma_dump1", @"oloarma_robotico_dump", @"oloarma_pared_dump"]) {
        NSString *path = [[NSBundle mainBundle] pathForResource:name
                                                           ofType:@"txt"
                                                      inDirectory:@"HoloArma"];
        if (path.length && ![resourcePaths containsObject:path]) [resourcePaths addObject:path];
    }
    for (NSString *path in resourcePaths) {
        NSString *name = path.lastPathComponent;
        if ([name hasPrefix:@"AVATAR_"] || [name hasPrefix:@"CACHE_"] || [name hasPrefix:@"avatar_"] ||
            [name hasPrefix:@"cache_"] || [name hasPrefix:@"olo_"] || [name hasPrefix:@"oloarma_"] ||
            [name hasSuffix:@"_README.txt"]) {
            NSURL *destination = [session URLByAppendingPathComponent:name];
            if ([fm copyItemAtPath:path toPath:destination.path error:nil]) [dumpFiles addObject:name];
        }
    }
    NSDictionary *manifest = @{
        @"action": action ?: @"",
        @"option": option ?: @"",
        @"createdAt": [NSDate date],
        @"sourceAsset": self.assetURL.lastPathComponent ?: @"",
        @"inputFile": input.lastPathComponent ?: @"",
        @"dumps": dumpFiles,
        @"processingStatus": @"staged-only",
        @"note": @"La interfaz local organiza asset y dumps. La transformación binaria Unity requiere un serializador AssetsTools nativo."
    };
    NSURL *manifestURL = [session URLByAppendingPathComponent:@"manifest.plist"];
    if (![manifest writeToURL:manifestURL atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"com.external.rx7"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"No se pudo escribir el manifiesto."}];
        return nil;
    }
    return session;
}

- (void)showStagedNotice:(NSURL *)session action:(NSString *)action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SESIÓN PREPARADA"
                                                                     message:[NSString stringWithFormat:@"%@ organizó el asset y los dumps disponibles. Esta compilación todavía no aplica cambios binarios Unity; la sesión queda lista para el motor AssetsTools nativo.", action.uppercaseString]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ABRIR ARCHIVOS" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        FilesViewController *files = [[FilesViewController alloc] initWithDirectoryURL:session appName:@"RX7 Panel" bundleID:nil];
        [self.navigationController pushViewController:files animated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"CERRAR" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Navigation

- (void)addProtectedTabsIfNeeded {
    // Kept for compatibility with the original no-login bootstrap. The
    // dashboard now exposes the protected tools through its side menu.
}

- (void)openFiles {
    self.navigationController.navigationBarHidden = NO;
    FilesViewController *files = [[FilesViewController alloc] initWithApplicationList];
    [self.navigationController pushViewController:files animated:YES];
}

- (void)openPatches {
    PatchProjectsViewController *patches = [[PatchProjectsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:patches];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openCleaner {
    CleanerViewController *cleaner = [[CleanerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cleaner];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openSettings {
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)refreshAppearance {
    self.view.backgroundColor = RX7Background();
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RX7 PANEL"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end