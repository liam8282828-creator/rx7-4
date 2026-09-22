#import "FilesViewController.h"
#import "bad_query.h"
#import "mcm_bridge.h"
#import "SandboxAccessBridge.h"
#import "AppIconHelper.h"
#import "Localization.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kFilesMetadataFilename =
    @".com.apple.mobile_container_manager.metadata.plist";
static NSURL *sFilesClipboardURL;
static BOOL sFilesClipboardIsMove;

static BOOL ExternalFilesShouldUseTraversalGrant(void) {
    return [NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 26;
}

typedef NS_ENUM(NSInteger, FilesErrorCode) {
    FilesErrorInvalidSource = 1,
    FilesErrorTypeMismatch,
    FilesErrorReplaceFailed,
};

@interface FilesViewController () <UIDocumentPickerDelegate, UISearchResultsUpdating>
@property (nonatomic) BOOL applicationList;
@property (nonatomic, strong) NSURL *directoryURL;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) NSArray<NSDictionary *> *applications;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApplications;
@property (nonatomic, strong) NSArray<NSURL *> *items;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSURL *pendingReplacementTarget;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, copy) NSString *emptyMessage;
@end

@interface FilesViewController (PrivateHelpers)
- (NSArray<NSDictionary *> *)discoverApplications:(NSError **)error;
- (NSArray<NSURL *> *)sortedItems:(NSArray<NSURL *> *)items;
- (BOOL)isApplicationContainerPath:(NSString *)path;
@end

static void ExternalLoadLaunchServices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *frameworks[] = {
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices"
        };
        for (NSUInteger index = 0;
             index < sizeof(frameworks) / sizeof(frameworks[0]);
             index++) {
            if (dlopen(frameworks[index], RTLD_LAZY | RTLD_GLOBAL)) {
                return;
            }
        }
    });
}

static NSArray<NSDictionary *> *ExternalLaunchServicesApplications(void) {
    ExternalLoadLaunchServices();

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultWorkspaceSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass ||
        ![workspaceClass respondsToSelector:defaultWorkspaceSelector]) {
        return @[];
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(
        workspaceClass,
        defaultWorkspaceSelector
    );
    if (!workspace) return @[];

    NSArray *installedApplications = nil;
    for (NSString *selectorName in @[@"allApplications",
                                      @"allInstalledApplications"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:selector]) continue;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(workspace, selector);
        if ([candidate isKindOfClass:[NSArray class]] &&
            [candidate count] > 0) {
            installedApplications = candidate;
            break;
        }
    }
    if (installedApplications.count == 0) return @[];

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (id application in installedApplications) {
        @autoreleasepool {
            NSString *bundleID = nil;
            for (NSString *selectorName in @[@"bundleIdentifier",
                                              @"applicationIdentifier"]) {
                SEL selector = NSSelectorFromString(selectorName);
                if (![application respondsToSelector:selector]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(application, selector);
                if ([value isKindOfClass:[NSString class]] &&
                    [value length] > 0) {
                    bundleID = value;
                    break;
                }
            }
            if (bundleID.length == 0) continue;

            NSString *name = nil;
            for (NSString *selectorName in @[@"localizedName",
                                              @"localizedShortName"]) {
                SEL selector = NSSelectorFromString(selectorName);
                if (![application respondsToSelector:selector]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(application, selector);
                if ([value isKindOfClass:[NSString class]] &&
                    [value length] > 0) {
                    name = value;
                    break;
                }
            }
            [result addObject:@{
                @"bundleID": bundleID,
                @"name": name ?: bundleID
            }];
        }
    }
    return result;
}

@implementation FilesViewController

+ (NSURL *)applicationDataRootURL {
    return [NSURL fileURLWithPath:@"/var/mobile/Containers/Data/Application"
                       isDirectory:YES];
}

+ (NSArray<NSDictionary *> *)availableApplications {
    FilesViewController *browser = [[self alloc] initWithApplicationList];
    return [browser discoverApplications:nil] ?: @[];
}

- (instancetype)initWithApplicationList {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _applicationList = YES;
        _applications = @[];
        _filteredApplications = @[];
        _items = @[];
    }
    return self;
}

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL
                           appName:(NSString *)appName
                           bundleID:(NSString *)bundleID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _applicationList = NO;
        _directoryURL = directoryURL;
        _appName = [appName copy];
        _bundleID = [bundleID copy];
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 66.0;
    self.tableView.separatorColor = [UIColor colorWithWhite:0.20 alpha:1.0];

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.activityIndicator];

    if (self.applicationList) {
        self.navigationItem.title = EXLocalizedString(@"tab.files");
        self.navigationItem.leftBarButtonItem = nil;
        self.searchController = [[UISearchController alloc]
            initWithSearchResultsController:nil];
        self.searchController.searchResultsUpdater = self;
        self.searchController.obscuresBackgroundDuringPresentation = NO;
        self.searchController.searchBar.placeholder =
            EXLocalizedString(@"browser.search");
        self.navigationItem.searchController = self.searchController;
        self.definesPresentationContext = YES;
    } else {
        self.navigationItem.title = self.appName.length
            ? self.appName
            : self.directoryURL.lastPathComponent;
        self.navigationItem.prompt = self.bundleID.length ? self.bundleID : nil;
    }

    [self updateNavigationButtons];
    [self reloadContents];

    // The app list must be populated after the device-access chain has had
    // a chance to expose the other application containers. Without this
    // retry, MCM can return only this IPA's own container on first launch.
    if (self.applicationList && !ExternalSandboxAccessIsActive()) {
        __weak typeof(self) weakSelf = self;
        ExternalRunSandboxAccess(^(BOOL success) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !success) return;
            [self reloadContents];
        });
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNavigationButtons];
    if (self.isViewLoaded) [self reloadContents];
}

- (void)updateNavigationButtons {
    UIBarButtonItem *activityItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.activityIndicator];
    if (self.applicationList) {
        self.navigationItem.rightBarButtonItems = @[activityItem];
        return;
    }

    UIBarButtonItem *pasteItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"doc.on.clipboard"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(pasteClipboard)];
    pasteItem.accessibilityLabel = EXLocalizedString(@"browser.paste");
    pasteItem.enabled = sFilesClipboardURL != nil;
    self.navigationItem.rightBarButtonItems = @[activityItem, pasteItem];
}

- (void)reloadContents {
    [self.activityIndicator startAnimating];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSArray<NSDictionary *> *applications = @[];
        NSArray<NSURL *> *items = @[];
        NSString *message = nil;

        if (self.applicationList) {
            NSError *error = nil;
            applications = [self discoverApplications:&error];
            if (applications.count == 0) {
                message = error.localizedDescription.length
                    ? [NSString stringWithFormat:@"%@\n%@",
                       EXLocalizedString(@"browser.empty"),
                       error.localizedDescription]
                    : EXLocalizedString(@"browser.empty");
            }
        } else {
            // Keep the traversal grant alive while the directory is read.
            // This also covers containers found from the filesystem fallback
            // when MCM did not return the identifier directly.
            NSString *directoryPath = self.directoryURL.path;
            int64_t directoryHandle = -1;
            if (ExternalFilesShouldUseTraversalGrant()) {
                directoryHandle = bad_query(
                    (char *)directoryPath.fileSystemRepresentation,
                    true,
                    NULL,
                    false
                );
            }
            NSError *error = nil;
            NSArray<NSURLResourceKey> *keys = @[
                NSURLIsDirectoryKey,
                NSURLIsRegularFileKey,
                NSURLIsSymbolicLinkKey,
                NSURLFileSizeKey
            ];
            items = [[NSFileManager defaultManager]
                contentsOfDirectoryAtURL:self.directoryURL
                includingPropertiesForKeys:keys
                options:0
                error:&error];
            items = [self sortedItems:items];
            if (items.count == 0 && error) {
                message = [NSString stringWithFormat:@"%@\n%@",
                           EXLocalizedString(@"browser.error_import"),
                           error.localizedDescription];
            } else if (items.count == 0) {
                message = EXLocalizedString(@"browser.folder_empty");
            }
            if (directoryHandle >= 0) bad_query_release(directoryHandle);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.applications = applications;
            self.filteredApplications = applications;
            self.items = items;
            self.emptyMessage = message;
            [self.activityIndicator stopAnimating];
            [self updateEmptyFooter];
            [self.tableView reloadData];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if (!self.applicationList) return;
    NSString *query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) {
        self.filteredApplications = self.applications ?: @[];
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(
            NSDictionary *application, NSDictionary *_) {
            return [application[@"name"] localizedCaseInsensitiveContainsString:query]
                || [application[@"bundleID"] localizedCaseInsensitiveContainsString:query];
        }];
        self.filteredApplications =
            [self.applications filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

#pragma mark - Discovery

- (NSArray<NSDictionary *> *)discoverApplications:(NSError **)error {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSString *enumerationError = nil;
    // Do not start the kernel exploit as a side effect of selecting Files.
    // A failed attempt can terminate/restart the application on iOS 17/18,
    // and 3105 intentionally keeps that operation opt-in. MCM enumeration
    // remains safe without the exploit; the Home screen exposes the explicit
    // access action when filesystem traversal is required.
    BOOL sandboxReady = ExternalSandboxAccessIsActive();
    if (!sandboxReady) {
        NSLog(@"[External] sandbox access is not active; using safe MCM/LS fallbacks");
    }
    NSArray<NSString *> *mcmIdentifiers = MCMEnumerateIdentifiersForClass(
        2,
        4096,
        &enumerationError
    );
    NSMutableOrderedSet<NSString *> *identifierSet =
        [NSMutableOrderedSet orderedSet];
    [identifierSet addObjectsFromArray:mcmIdentifiers];

    // MCM can scope its enumeration to the host application. LaunchServices
    // supplies the complete installed-app identifier list; each identifier is
    // still validated and activated through MCM below.
    NSMutableDictionary<NSString *, NSString *> *launchServicesNames =
        [NSMutableDictionary dictionary];
    for (NSDictionary *application in ExternalLaunchServicesApplications()) {
        NSString *bundleID = application[@"bundleID"];
        if (![self isValidBundleIdentifier:bundleID]) continue;
        [identifierSet addObject:bundleID];
        launchServicesNames[bundleID] = application[@"name"] ?: bundleID;
    }

    // LaunchServices may be scoped to the host IPA. MobileInstallation
    // exposes the complete installed-application catalog on those builds,
    // including data-container paths when the installation database allows
    // them. Keep these records as the primary path source and retain MCM and
    // filesystem discovery as fallbacks.
    NSMutableDictionary<NSString *, NSDictionary *> *installationRecords =
        [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSDictionary *> *installationApps =
        installedAppInfo();
    [installationApps enumerateKeysAndObjectsUsingBlock:
        ^(NSString *bundleID, NSDictionary *info, BOOL *stop) {
        if (![self isValidBundleIdentifier:bundleID] ||
            ![info isKindOfClass:[NSDictionary class]]) return;
        installationRecords[bundleID] = info;
        [identifierSet addObject:bundleID];
        NSString *name = info[@"name"];
        if ([name isKindOfClass:[NSString class]] && name.length > 0) {
            launchServicesNames[bundleID] = name;
        }
    }];
    NSArray<NSString *> *identifiers = identifierSet.array;

    for (NSString *bundleID in identifiers) {
        if (![self isValidBundleIdentifier:bundleID]) continue;

        NSDictionary *installationInfo = installationRecords[bundleID];
        NSString *containerPath = installationInfo[@"container"];
        NSString *activationError = nil;
        if (![self isApplicationContainerPath:containerPath]) {
            containerPath = MCMActivateContainerPath(
                2,
                bundleID,
                NO,
                &activationError
            );
        }
        if (![self isApplicationContainerPath:containerPath]) continue;

        NSURL *containerURL = [NSURL fileURLWithPath:containerPath
                                         isDirectory:YES];
        NSDictionary *metadata = [self metadataForContainerURL:containerURL];
        NSString *name = metadata[@"displayName"];
        if (name.length == 0) name = launchServicesNames[bundleID] ?: bundleID;

        NSString *uuid = containerURL.lastPathComponent ?: @"";
        [result addObject:@{
            @"name": name,
            @"bundleID": bundleID,
            @"path": containerPath,
            @"uuid": uuid,
            @"version": metadata[@"version"] ?: @""
        }];
    }

    // MCM can return only a partial list when the app uses a custom bundle
    // identifier. Supplement it with a root traversal and confirm every UUID
    // through its metadata plist. Do not treat a non-empty FileManager result
    // as complete: on affected systems it can contain only External.
    NSMutableSet<NSString *> *knownBundleIDs = [NSMutableSet set];
    for (NSDictionary *application in result) {
        NSString *bundleID = application[@"bundleID"];
        if (bundleID.length) [knownBundleIDs addObject:bundleID];
    }

    {
        NSString *rootPath = [FilesViewController applicationDataRootURL].path;
        int64_t rootHandle = -1;
        if (ExternalFilesShouldUseTraversalGrant()) {
            rootHandle = bad_query(
                (char *)rootPath.fileSystemRepresentation,
                true,
                NULL,
                false
            );
        }
        NSArray<NSString *> *directNames = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:rootPath
                                error:nil];
        NSMutableOrderedSet<NSString *> *rootPaths =
            [NSMutableOrderedSet orderedSet];

        for (NSString *name in directNames) {
            if (name.length == 0) continue;
            NSString *path = [name hasPrefix:@"/"]
                ? name
                : [rootPath stringByAppendingPathComponent:name];
            [rootPaths addObject:path];
        }

        // Always ask bad_query for the root listing. A successful but partial
        // FileManager listing must be merged, not used as a replacement.
        char *listed = bad_query_list(
            (char *)rootPath.fileSystemRepresentation,
            2 * 1000 * 1000
        );
        if (listed) {
            NSString *listedString = [NSString stringWithUTF8String:listed];
            for (NSString *nameOrPath in
                 [listedString componentsSeparatedByString:@"\n"]) {
                if (nameOrPath.length == 0) continue;
                NSString *path = [nameOrPath hasPrefix:@"/"]
                    ? nameOrPath
                    : [rootPath stringByAppendingPathComponent:nameOrPath];
                [rootPaths addObject:path];
            }
            free(listed);
        }

        for (NSString *path in rootPaths) {
            if (![self isApplicationContainerPath:path]) continue;
            NSString *uuid = path.lastPathComponent;

            NSURL *containerURL = [NSURL fileURLWithPath:path
                                             isDirectory:YES];
            NSDictionary *metadata = [self metadataForContainerURL:containerURL];
            NSString *bundleID = metadata[@"bundleID"];
            if (![self isValidBundleIdentifier:bundleID] ||
                [knownBundleIDs containsObject:bundleID]) {
                continue;
            }

            // Activate every metadata-resolved container before exposing it
            // to the browser. If MCM cannot activate this identifier, retain
            // the filesystem path; the per-directory traversal grant above
            // will be retried when the user opens it.
            NSString *activationError = nil;
            NSString *activatedPath = MCMActivateContainerPath(
                2,
                bundleID,
                NO,
                &activationError
            );
            if (activatedPath.length == 0) {
                NSLog(@"[External] container activation failed for %@: %@",
                      bundleID,
                      activationError ?: @"sin detalle");
            }
            NSString *browserPath =
                [self isApplicationContainerPath:activatedPath]
                ? activatedPath
                : path;

            NSString *name = metadata[@"displayName"];
            if (name.length == 0) name = bundleID;
            [result addObject:@{
                @"name": name,
                @"bundleID": bundleID,
                @"path": browserPath,
                @"uuid": uuid,
                @"version": metadata[@"version"] ?: @""
            }];
            [knownBundleIDs addObject:bundleID];
        }
        if (rootHandle >= 0) bad_query_release(rootHandle);
    }

    if (result.count == 0 && error) {
        NSString *detail = enumerationError.length
            ? enumerationError
            : @"Could not activate any application container.";
        *error = [NSError errorWithDomain:@"com.external.files"
                                     code:2
                                 userInfo:@{
            NSLocalizedDescriptionKey: detail
        }];
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *aName = a[@"name"] ?: a[@"bundleID"];
        NSString *bName = b[@"name"] ?: b[@"bundleID"];
        return [aName localizedCaseInsensitiveCompare:bName];
    }];
    return result;
}

- (NSDictionary *)metadataForContainerURL:(NSURL *)containerURL {
    NSString *path = [containerURL.path
        stringByAppendingPathComponent:kFilesMetadataFilename];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![plist isKindOfClass:[NSDictionary class]]) return @{};

    NSString *bundleID = plist[@"MCMMetadataIdentifier"];
    NSDictionary *info = plist[@"MCMMetadataInfo"];
    if (![info isKindOfClass:[NSDictionary class]]) info = @{};

    NSString *displayName = info[@"CFBundleDisplayName"];
    if (![displayName isKindOfClass:[NSString class]] || displayName.length == 0) {
        displayName = info[@"CFBundleName"];
    }
    if (![displayName isKindOfClass:[NSString class]]) displayName = @"";

    NSString *version = info[@"CFBundleShortVersionString"];
    if (![version isKindOfClass:[NSString class]]) version = @"";

    return @{
        @"bundleID": [bundleID isKindOfClass:[NSString class]] ? bundleID : @"",
        @"displayName": displayName,
        @"version": version
    };
}

- (BOOL)isUUIDLike:(NSString *)value {
    if (value.length != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    return uuid != nil;
}

- (BOOL)isApplicationContainerPath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return NO;
    }

    NSString *canonicalPath = [path stringByStandardizingPath];
    NSString *privatePrefix =
        @"/private/var/mobile/Containers/Data/Application/";
    NSString *publicPrefix =
        @"/var/mobile/Containers/Data/Application/";
    if ([canonicalPath hasPrefix:privatePrefix]) {
        canonicalPath = [@"/var" stringByAppendingString:
                         [canonicalPath substringFromIndex:@"/private/var".length]];
    }

    if (![canonicalPath hasPrefix:publicPrefix]) return NO;
    NSString *relative =
        [canonicalPath substringFromIndex:publicPrefix.length];
    NSArray<NSString *> *components =
        [relative componentsSeparatedByString:@"/"];
    if (components.count != 1) return NO;
    return [self isUUIDLike:components.firstObject];
}

- (BOOL)isValidBundleIdentifier:(NSString *)value {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    if (![value containsString:@"."] ||
        [value hasPrefix:@"."] ||
        [value hasSuffix:@"."] ||
        [value containsString:@"/"]) {
        return NO;
    }
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
         @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [value rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.applicationList
        ? self.filteredApplications.count
        : self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"FilesCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
        cell.detailTextLabel.numberOfLines = 2;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    if (self.applicationList) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSDictionary *application = self.filteredApplications[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:@"app.fill"];
        cell.imageView.tintColor =
            [UIColor colorWithRed:0.35 green:0.70 blue:1.0 alpha:1.0];
        cell.textLabel.text = application[@"name"];
        NSString *bundleID = application[@"bundleID"];
        NSString *uuid = application[@"uuid"];
        NSString *version = application[@"version"];
        NSString *versionText = version.length
            ? [NSString stringWithFormat:@" · %@", version]
            : @"";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@\n%@: %@",
                                     bundleID, versionText,
                                     EXLocalizedString(@"browser.app_data"), uuid];
        return cell;
    }

    NSURL *itemURL = self.items[indexPath.row];
    UIButton *actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    actionButton.frame = CGRectMake(0, 0, 32, 32);
    [actionButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                  forState:UIControlStateNormal];
    actionButton.tintColor = [UIColor colorWithWhite:0.76 alpha:1.0];
    actionButton.tag = indexPath.row;
    [actionButton addTarget:self
                     action:@selector(showItemMenu:)
           forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = actionButton;
    BOOL isDirectory = NO;
    BOOL isSymbolicLink = NO;
    NSNumber *size = nil;
    NSNumber *directoryValue = nil;
    NSNumber *symbolicLinkValue = nil;
    [itemURL getResourceValue:&directoryValue
                        forKey:NSURLIsDirectoryKey
                         error:nil];
    [itemURL getResourceValue:&symbolicLinkValue
                        forKey:NSURLIsSymbolicLinkKey
                         error:nil];
    isDirectory = directoryValue.boolValue;
    isSymbolicLink = symbolicLinkValue.boolValue;
    [itemURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];

    cell.imageView.image = [UIImage systemImageNamed:isDirectory
        ? @"folder.fill"
        : (isSymbolicLink ? @"link" : @"doc.fill")];
    cell.imageView.tintColor = isDirectory
        ? [UIColor colorWithRed:0.98 green:0.70 blue:0.18 alpha:1.0]
        : [UIColor colorWithRed:0.35 green:0.70 blue:1.0 alpha:1.0];
    cell.textLabel.text = itemURL.lastPathComponent;
    if (isDirectory) {
        cell.detailTextLabel.text = EXLocalizedString(@"browser.folder_item");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (isSymbolicLink) {
        cell.detailTextLabel.text = EXLocalizedString(@"browser.symlink_item");
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.detailTextLabel.text = size
            ? [NSByteCountFormatter stringFromByteCount:size.longLongValue
                                             countStyle:NSByteCountFormatterCountStyleFile]
            : EXLocalizedString(@"browser.size_unavailable");
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.applicationList) {
        NSDictionary *application = self.filteredApplications[indexPath.row];
        NSString *containerPath = application[@"path"];
        if (![self isApplicationContainerPath:containerPath]) {
            [self showError:EXLocalizedString(@"browser.invalid_container")];
            return;
        }
        FilesViewController *browser = [[FilesViewController alloc]
            initWithDirectoryURL:[NSURL fileURLWithPath:containerPath
                                            isDirectory:YES]
                       appName:application[@"name"]
                       bundleID:application[@"bundleID"]];
        [self.navigationController pushViewController:browser animated:YES];
        return;
    }

    NSURL *itemURL = self.items[indexPath.row];
    NSNumber *isDirectory = nil;
    NSNumber *isSymbolicLink = nil;
    [itemURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    [itemURL getResourceValue:&isSymbolicLink
                        forKey:NSURLIsSymbolicLinkKey
                         error:nil];
    if (isDirectory.boolValue && !isSymbolicLink.boolValue) {
        FilesViewController *browser = [[FilesViewController alloc]
            initWithDirectoryURL:itemURL
                       appName:itemURL.lastPathComponent
                       bundleID:self.bundleID];
        [self.navigationController pushViewController:browser animated:YES];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Keep the row uncluttered. All file actions live in the ellipsis button
    // so they remain usable on narrow iPhone screens.
    return nil;
}

#pragma mark - File actions

- (void)showItemMenu:(UIButton *)sender {
    if (self.applicationList || sender.tag >= self.items.count) return;

    NSURL *itemURL = self.items[sender.tag];
    NSString *itemName = itemURL.lastPathComponent ?: @"item";
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:itemName
                         message:@"Select an action"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:@"Copy"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self setClipboard:itemURL move:NO];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Move"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self setClipboard:itemURL move:YES];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Replace"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self presentReplacementPickerForTarget:itemURL];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Rename"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self presentRenameForItem:itemURL];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self confirmDeleteItem:itemURL];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    menu.popoverPresentationController.sourceView = sender;
    menu.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)setClipboard:(NSURL *)itemURL move:(BOOL)move {
    sFilesClipboardURL = itemURL;
    sFilesClipboardIsMove = move;
    [self updateNavigationButtons];
}

- (void)pasteClipboard {
    NSURL *sourceURL = sFilesClipboardURL;
    if (!sourceURL || !self.directoryURL) return;

    NSURL *targetURL = [self.directoryURL
        URLByAppendingPathComponent:sourceURL.lastPathComponent
                        isDirectory:NO];
    NSString *sourcePath = sourceURL.standardizedURL.path;
    NSString *targetPath = targetURL.standardizedURL.path;
    if ([sourcePath isEqualToString:targetPath] ||
        [targetPath hasPrefix:[sourcePath stringByAppendingString:@"/"]]) {
        [self showError:@"An item cannot be pasted inside itself."];
        return;
    }

    BOOL targetExists = [[NSFileManager defaultManager]
        fileExistsAtPath:targetURL.path];
    if (targetExists) {
        NSString *operation = sFilesClipboardIsMove ? @"move" : @"copy";
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"The Destination Already Exists"
                             message:[NSString stringWithFormat:
                                      @"Replace %@ for %@?",
                                      targetURL.lastPathComponent, operation]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Replace"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [self performPasteFrom:sourceURL
                                 to:targetURL
                               replace:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self performPasteFrom:sourceURL to:targetURL replace:NO];
}

- (void)performPasteFrom:(NSURL *)sourceURL
                       to:(NSURL *)targetURL
                 replace:(BOOL)replace {
    BOOL move = sFilesClipboardIsMove;
    [self.activityIndicator startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *error = nil;
        NSURL *backupURL = nil;
        BOOL success = YES;

        if (replace && [fileManager fileExistsAtPath:targetURL.path]) {
            backupURL = [targetURL.URLByDeletingLastPathComponent
                URLByAppendingPathComponent:
                    [NSString stringWithFormat:@".external-paste-backup-%@",
                                               NSUUID.UUID.UUIDString]];
            success = [fileManager moveItemAtURL:targetURL
                                           toURL:backupURL
                                           error:&error];
        }
        if (success) {
            success = move
                ? [fileManager moveItemAtURL:sourceURL toURL:targetURL error:&error]
                : [fileManager copyItemAtURL:sourceURL toURL:targetURL error:&error];
        }
        if (!success && backupURL) {
            [fileManager moveItemAtURL:backupURL toURL:targetURL error:nil];
        } else if (success && backupURL) {
            [fileManager removeItemAtURL:backupURL error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.activityIndicator stopAnimating];
            if (!success) {
                [self showError:error.localizedDescription ?: @"Could not paste the item."];
                return;
            }
            if (move) {
                sFilesClipboardURL = nil;
                sFilesClipboardIsMove = NO;
            }
            [self updateNavigationButtons];
            [self reloadContents];
        });
    });
}

- (void)presentRenameForItem:(NSURL *)itemURL {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rename"
                         message:@"Enter the new name"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = itemURL.lastPathComponent;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *rawName = alert.textFields.firstObject.text ?: @"";
        NSString *name = [rawName
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0 || [name containsString:@"/"] ||
            [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            [self showError:@"The name is invalid."];
            return;
        }
        NSURL *targetURL = [itemURL.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:targetURL.path]) {
            [self showError:@"An item with that name already exists."];
            return;
        }
        NSError *error = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:itemURL
                                                     toURL:targetURL
                                                     error:&error]) {
            [self showError:error.localizedDescription ?: @"Could not rename the item."];
        } else {
            [self reloadContents];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteItem:(NSURL *)itemURL {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete"
                         message:[NSString stringWithFormat:
                                  @"Delete %@ permanently?",
                                  itemURL.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:itemURL error:&error]) {
            [self showError:error.localizedDescription ?: @"Could not delete the item."];
        } else {
            [self reloadContents];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Replacement

- (void)presentReplacementPickerForTarget:(NSURL *)targetURL {
    self.pendingReplacementTarget = targetURL;

    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *dataType = [UTType typeWithIdentifier:@"public.data"];
    UTType *folderType = [UTType typeWithIdentifier:@"public.folder"];
    if (dataType) [types addObject:dataType];
    if (folderType) [types addObject:folderType];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    NSURL *targetURL = self.pendingReplacementTarget;
    self.pendingReplacementTarget = nil;
    if (!sourceURL || !targetURL) return;

    BOOL hasAccess = [sourceURL startAccessingSecurityScopedResource];
    [self.activityIndicator startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        NSError *error = nil;
        BOOL success = self && [self safelyReplaceTarget:targetURL
                                             withSource:sourceURL
                                                   error:&error];
        if (hasAccess) [sourceURL stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.activityIndicator stopAnimating];
            if (!success) {
                [self showError:error.localizedDescription
                    ?: @"Could not replace the item."];
            }
            [self reloadContents];
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.pendingReplacementTarget = nil;
}

- (BOOL)safelyReplaceTarget:(NSURL *)targetURL
                 withSource:(NSURL *)sourceURL
                       error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSNumber *sourceDirectory = nil;
    NSNumber *sourceLink = nil;
    NSNumber *targetDirectory = nil;
    NSNumber *targetLink = nil;
    [sourceURL getResourceValue:&sourceDirectory
                          forKey:NSURLIsDirectoryKey
                           error:nil];
    [sourceURL getResourceValue:&sourceLink
                          forKey:NSURLIsSymbolicLinkKey
                           error:nil];
    [targetURL getResourceValue:&targetDirectory
                          forKey:NSURLIsDirectoryKey
                           error:nil];
    [targetURL getResourceValue:&targetLink
                          forKey:NSURLIsSymbolicLinkKey
                           error:nil];

    if (!sourceDirectory || !targetDirectory || sourceLink.boolValue ||
        targetLink.boolValue) {
        if (error) *error = [self filesError:FilesErrorInvalidSource
                                        text:@"Symbolic links are not supported."];
        return NO;
    }
    if (sourceDirectory.boolValue != targetDirectory.boolValue) {
        if (error) *error = [self filesError:FilesErrorTypeMismatch
                                        text:@"The source and destination must both be files or both be folders."];
        return NO;
    }
    if ([sourceURL.standardizedURL.path isEqualToString:
         targetURL.standardizedURL.path]) {
        if (error) *error = [self filesError:FilesErrorInvalidSource
                                        text:@"An item cannot replace itself."];
        return NO;
    }

    NSURL *parentURL = targetURL.URLByDeletingLastPathComponent;
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSURL *stagingURL = [parentURL
        URLByAppendingPathComponent:[NSString stringWithFormat:@".external-files-staging-%@",
                                     nonce]
                        isDirectory:sourceDirectory.boolValue];
    NSURL *backupURL = [parentURL
        URLByAppendingPathComponent:[NSString stringWithFormat:@".external-files-backup-%@",
                                     nonce]
                        isDirectory:targetDirectory.boolValue];

    NSError *operationError = nil;
    if (![fileManager copyItemAtURL:sourceURL toURL:stagingURL error:&operationError]) {
        if (error) *error = operationError ?: [self filesError:FilesErrorReplaceFailed
                                                           text:@"Could not prepare the replacement."];
        return NO;
    }

    if (![fileManager moveItemAtURL:targetURL toURL:backupURL error:&operationError]) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (error) *error = operationError ?: [self filesError:FilesErrorReplaceFailed
                                                           text:@"Could not move the original destination aside."];
        return NO;
    }

    if (![fileManager moveItemAtURL:stagingURL toURL:targetURL error:&operationError]) {
        [fileManager moveItemAtURL:backupURL toURL:targetURL error:nil];
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (error) *error = operationError ?: [self filesError:FilesErrorReplaceFailed
                                                           text:@"Could not install the replacement."];
        return NO;
    }

    [fileManager removeItemAtURL:backupURL error:nil];
    return YES;
}

- (NSError *)filesError:(FilesErrorCode)code text:(NSString *)text {
    return [NSError errorWithDomain:@"com.external.files"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:EXLocalizedString(@"tab.files")
                         message:message.length ? message : EXLocalizedString(@"browser.error_unknown")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Sorting and file metadata

- (NSArray<NSURL *> *)sortedItems:(NSArray<NSURL *> *)items {
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *aDirectory = nil;
        NSNumber *bDirectory = nil;
        [a getResourceValue:&aDirectory
                     forKey:NSURLIsDirectoryKey
                      error:nil];
        [b getResourceValue:&bDirectory
                     forKey:NSURLIsDirectoryKey
                      error:nil];
        if (aDirectory.boolValue != bDirectory.boolValue) {
            return aDirectory.boolValue ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }];
}

#pragma mark - Empty state

- (void)updateEmptyFooter {
    if (self.applicationList && self.applications.count > 0) {
        self.tableView.tableFooterView = [UIView new];
        return;
    }
    if (!self.applicationList && self.items.count > 0) {
        self.tableView.tableFooterView = [UIView new];
        return;
    }

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 120)];
    label.text = self.emptyMessage ?: EXLocalizedString(@"browser.no_data");
    label.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    label.font = [UIFont systemFontOfSize:15.0];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableFooterView = label;
}

@end