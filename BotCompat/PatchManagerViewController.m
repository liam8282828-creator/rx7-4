#import "PatchManagerViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kPatchManagerErrorDomain = @"com.external.patch-manager";

typedef NS_ENUM(NSInteger, PatchManagerErrorCode) {
    PatchManagerErrorInvalidSource = 1,
    PatchManagerErrorCopyFailed,
};

@interface PatchManagerViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSURL *directoryURL;
@property (nonatomic, strong) NSArray<NSURL *> *items;
@property (nonatomic, strong) NSArray<NSURL *> *pendingImports;
@property (nonatomic, strong) NSURL *pendingReplacementTarget;
@property (nonatomic) NSUInteger pendingImportIndex;
@property (nonatomic) BOOL replacingAllImports;
@property (nonatomic) BOOL pickingApplicationDataFolder;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) NSArray<UISwitch *> *moduleSwitches;
@end

@implementation PatchManagerViewController

+ (NSURL *)patchesRootURL {
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *root = [documents URLByAppendingPathComponent:@"Patches"
                                              isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:root
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return root;
}

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _directoryURL = directoryURL;
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 58.0;
    self.navigationItem.title = self.directoryURL.lastPathComponent ?: @"Patches";
    if (!self.tabBarController) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                 target:self
                                 action:@selector(close)];
    }
    self.tableView.tableHeaderView = [self modulesHeaderView];
    self.tableView.tableFooterView = [UIView new];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.tabBarController) {
        self.navigationItem.leftBarButtonItem = nil;
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadItems {
    NSArray<NSURLResourceKey> *keys = @[
        NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey
    ];
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:self.directoryURL
        includingPropertiesForKeys:keys
        options:NSDirectoryEnumerationSkipsHiddenFiles
        error:nil];
    self.items = [contents sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *aDirectory = nil;
        NSNumber *bDirectory = nil;
        [a getResourceValue:&aDirectory forKey:NSURLIsDirectoryKey error:nil];
        [b getResourceValue:&bDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (aDirectory.boolValue != bDirectory.boolValue) {
            return aDirectory.boolValue ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }];
    [self.tableView reloadData];
}

- (void)showAddMenu {
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:@"Patches"
                         message:@"Import a file or folder into the workspace."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Import Files or Folders"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self presentDocumentPickerAllowingMultiple:YES replacementTarget:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"New Folder"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self promptForNewFolder];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Apply This Folder to App Data"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self chooseApplicationDataFolder];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    menu.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)presentDocumentPickerAllowingMultiple:(BOOL)multiple
                             replacementTarget:(NSURL * _Nullable)target {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *packageType = [UTType typeWithTag:@"3105"
                                      tagClass:UTTagClassFilenameExtension
                                      conformingToType:UTTypeData];
    UTType *dataType = [UTType typeWithIdentifier:@"public.data"];
    UTType *folderType = [UTType typeWithIdentifier:@"public.folder"];
    if (packageType) [types addObject:packageType];
    if (dataType) [types addObject:dataType];
    if (folderType) [types addObject:folderType];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = multiple;
    self.pendingReplacementTarget = target;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.pickingApplicationDataFolder) {
        self.pickingApplicationDataFolder = NO;
        if (urls.count != 1) {
            [self showError:@"Select an application's data folder."];
            return;
        }
        [self confirmApplyCurrentFolderToApplicationData:urls.firstObject];
        return;
    }

    NSURL *replacementTarget = self.pendingReplacementTarget;
    self.pendingReplacementTarget = nil;
    if (replacementTarget) {
        if (urls.count != 1) {
            [self showError:@"Select one file or folder to replace."];
            return;
        }
        [self confirmReplacementFromURL:urls.firstObject target:replacementTarget];
        return;
    }
    self.pendingImports = urls;
    self.pendingImportIndex = 0;
    self.replacingAllImports = NO;
    [self processNextImport];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.pendingReplacementTarget = nil;
    self.pickingApplicationDataFolder = NO;
}

- (void)chooseApplicationDataFolder {
    NSURL *patchesRoot = [PatchManagerViewController patchesRootURL];
    if ([self.directoryURL.standardizedURL isEqual:patchesRoot.standardizedURL]) {
        [self showError:@"Open the patch folder you want to apply first."];
        return;
    }

    UTType *folderType = [UTType typeWithIdentifier:@"public.folder"];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[folderType] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    self.pickingApplicationDataFolder = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmApplyCurrentFolderToApplicationData:(NSURL *)applicationDataURL {
    BOOL isDirectory = NO;
    if (![self readIsDirectory:&isDirectory forURL:applicationDataURL] || !isDirectory) {
        [self showError:@"The selected location is not a valid data folder."];
        return;
    }

    NSArray<NSURL *> *files = [self regularFilesUnderDirectory:self.directoryURL];
    if (files.count == 0) {
        [self showError:@"This folder contains no files to replace."];
        return;
    }

    NSString *message = [NSString stringWithFormat:
        @"%lu file(s) inside the selected data folder will be replaced. "
        @"The original files will be kept temporarily during the operation.",
        (unsigned long)files.count];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Apply Patch"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self applyCurrentFolder:self.directoryURL toApplicationData:applicationDataURL];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyCurrentFolder:(NSURL *)sourceDirectory
      toApplicationData:(NSURL *)applicationDataURL {
    BOOL hasAccess = [applicationDataURL startAccessingSecurityScopedResource];
    [self.activityIndicator startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<NSURL *> *files = [self regularFilesUnderDirectory:sourceDirectory];
        BOOL success = YES;
        for (NSURL *sourceURL in files) {
            NSString *relativePath = [self relativePathForURL:sourceURL
                                                  underDirectory:sourceDirectory];
            if (relativePath.length == 0 ||
                [sourceURL.pathExtension.lowercaseString isEqualToString:@"3105"]) {
                continue;
            }
            NSURL *destinationURL = [applicationDataURL
                URLByAppendingPathComponent:relativePath isDirectory:NO];
            NSURL *parentURL = destinationURL.URLByDeletingLastPathComponent;
            if (![[NSFileManager defaultManager] createDirectoryAtURL:parentURL
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&error] ||
                ![self safelyInstallSource:sourceURL
                                destination:destinationURL
                                   replacing:YES
                                       error:&error]) {
                success = NO;
                break;
            }
        }
        if (hasAccess) [applicationDataURL stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (!success) {
                [self showError:error.localizedDescription ?: @"Could not apply the patch."];
            } else {
                [self showError:@"Patch applied successfully to the application's data."];
            }
        });
    });
}

- (NSArray<NSURL *> *)regularFilesUnderDirectory:(NSURL *)directoryURL {
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:directoryURL
        includingPropertiesForKeys:@[
            NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey
        ]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
            return NO;
        }];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        NSNumber *isDirectory = nil;
        NSNumber *isRegular = nil;
        NSNumber *isSymbolicLink = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!isSymbolicLink.boolValue && !isDirectory.boolValue && isRegular.boolValue) {
            [files addObject:url];
        }
    }
    return files;
}

- (NSString *)relativePathForURL:(NSURL *)url underDirectory:(NSURL *)directoryURL {
    NSString *root = directoryURL.standardizedURL.path;
    NSString *path = url.standardizedURL.path;
    if (![path hasPrefix:[root stringByAppendingString:@"/"]]) return @"";
    return [path substringFromIndex:root.length + 1];
}

- (void)processNextImport {
    if (self.pendingImportIndex >= self.pendingImports.count) {
        self.pendingImports = @[];
        self.replacingAllImports = NO;
        [self.activityIndicator stopAnimating];
        [self reloadItems];
        return;
    }

    NSURL *sourceURL = self.pendingImports[self.pendingImportIndex];
    self.pendingImportIndex += 1;
    BOOL isDirectory = NO;
    if (![self readIsDirectory:&isDirectory forURL:sourceURL] ||
        ![self sourceIsSupported:sourceURL isDirectory:isDirectory]) {
        [self showError:@"Only regular files or folders can be imported; symbolic links are not supported."];
        [self processNextImport];
        return;
    }

    NSURL *destinationURL = [self.directoryURL URLByAppendingPathComponent:sourceURL.lastPathComponent
                                                                  isDirectory:isDirectory];
    if ([[NSFileManager defaultManager] fileExistsAtPath:destinationURL.path] &&
        !self.replacingAllImports) {
        [self showImportConflictForSource:sourceURL destination:destinationURL];
        return;
    }
    [self copySourceURL:sourceURL toDestination:destinationURL replacing:YES];
}

- (void)showImportConflictForSource:(NSURL *)sourceURL destination:(NSURL *)destinationURL {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"The Item Already Exists"
                         message:[NSString stringWithFormat:@"Replace %@?",
                                  destinationURL.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Replace"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self copySourceURL:sourceURL toDestination:destinationURL replacing:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Replace All"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        self.replacingAllImports = YES;
        [self copySourceURL:sourceURL toDestination:destinationURL replacing:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Skip"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        [self processNextImport];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copySourceURL:(NSURL *)sourceURL
        toDestination:(NSURL *)destinationURL
            replacing:(BOOL)replacing {
    BOOL hasAccess = [sourceURL startAccessingSecurityScopedResource];
    [self.activityIndicator startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = [self safelyInstallSource:sourceURL
                                      destination:destinationURL
                                         replacing:replacing
                                             error:&error];
        if (hasAccess) [sourceURL stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (!success) {
                [self showError:error.localizedDescription ?: @"Could not import the item."];
            }
            [self reloadItems];
            [self processNextImport];
        });
    });
}

- (BOOL)safelyInstallSource:(NSURL *)sourceURL
                destination:(NSURL *)destinationURL
                   replacing:(BOOL)replacing
                       error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL sourceIsDirectory = NO;
    if (![self readIsDirectory:&sourceIsDirectory forURL:sourceURL] ||
        ![self sourceIsSupported:sourceURL isDirectory:sourceIsDirectory]) {
        if (error) *error = [self errorWithCode:PatchManagerErrorInvalidSource
                                           text:@"The source is not a supported file or folder."];
        return NO;
    }
    NSURL *parent = destinationURL.URLByDeletingLastPathComponent;
    NSURL *staging = [parent URLByAppendingPathComponent:
                      [NSString stringWithFormat:@".external-import-%@", NSUUID.UUID.UUIDString]
                                             isDirectory:sourceIsDirectory];
    NSURL *backup = [parent URLByAppendingPathComponent:
                     [NSString stringWithFormat:@".external-backup-%@", NSUUID.UUID.UUIDString]
                                            isDirectory:sourceIsDirectory];

    if (![fileManager copyItemAtURL:sourceURL toURL:staging error:error]) {
        return NO;
    }
    BOOL destinationExisted = [fileManager fileExistsAtPath:destinationURL.path];
    if (destinationExisted && !replacing) {
        [fileManager removeItemAtURL:staging error:nil];
        if (error) *error = [self errorWithCode:PatchManagerErrorCopyFailed
                                           text:@"The destination already exists."];
        return NO;
    }
    if (destinationExisted && ![fileManager moveItemAtURL:destinationURL toURL:backup error:error]) {
        [fileManager removeItemAtURL:staging error:nil];
        return NO;
    }
    if (![fileManager moveItemAtURL:staging toURL:destinationURL error:error]) {
        if (destinationExisted) [fileManager moveItemAtURL:backup toURL:destinationURL error:nil];
        [fileManager removeItemAtURL:staging error:nil];
        return NO;
    }
    if (destinationExisted) [fileManager removeItemAtURL:backup error:nil];
    return YES;
}

- (void)confirmReplacementFromURL:(NSURL *)sourceURL target:(NSURL *)targetURL {
    BOOL sourceDirectory = NO;
    BOOL targetDirectory = NO;
    if (![self readIsDirectory:&sourceDirectory forURL:sourceURL] ||
        ![self readIsDirectory:&targetDirectory forURL:targetURL] ||
        sourceDirectory != targetDirectory) {
        [self showError:@"The replacement must have the same type: file for file or folder for folder."];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Confirm Replacement"
                         message:[NSString stringWithFormat:@"%@ will be replaced with %@.",
                                  targetURL.lastPathComponent, sourceURL.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Replace"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        BOOL hasAccess = [sourceURL startAccessingSecurityScopedResource];
        [self.activityIndicator startAnimating];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            BOOL success = [self safelyInstallSource:sourceURL
                                          destination:targetURL
                                             replacing:YES
                                                 error:&error];
            if (hasAccess) [sourceURL stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.activityIndicator stopAnimating];
                if (!success) {
                    [self showError:error.localizedDescription ?: @"Could not replace the item."];
                }
                [self reloadItems];
            });
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptForNewFolder {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"New Folder"
                         message:@"Enter the folder name."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0 || [name containsString:@"/"] ||
            [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            [self showError:@"The folder name is invalid."];
            return;
        }
        NSURL *folderURL = [self.directoryURL URLByAppendingPathComponent:name
                                                               isDirectory:YES];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:folderURL
                                       withIntermediateDirectories:NO
                                                        attributes:nil
                                                             error:&error]) {
            [self showError:error.localizedDescription ?: @"Could not create the folder."];
        } else {
            [self reloadItems];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptForRename:(NSURL *)itemURL {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rename"
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = itemURL.lastPathComponent;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0 || [name containsString:@"/"] ||
            [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            [self showError:@"The name is invalid."];
            return;
        }
        NSURL *destination = [self.directoryURL URLByAppendingPathComponent:name
                                                                  isDirectory:itemURL.hasDirectoryPath];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:itemURL
                                                     toURL:destination
                                                     error:&error]) {
            [self showError:error.localizedDescription ?: @"Could not rename the item."];
        } else {
            [self reloadItems];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete:(NSURL *)itemURL {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete"
                         message:[NSString stringWithFormat:@"Delete %@?",
                                  itemURL.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:itemURL error:&error]) {
            [self showError:error.localizedDescription ?: @"Could not delete the item."];
        } else {
            [self reloadItems];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)readIsDirectory:(BOOL *)isDirectory forURL:(NSURL *)url {
    NSNumber *value = nil;
    NSError *error = nil;
    if (![url getResourceValue:&value forKey:NSURLIsDirectoryKey error:&error] ||
        !value) return NO;
    *isDirectory = value.boolValue;
    NSNumber *symbolicLink = nil;
    [url getResourceValue:&symbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
    return !symbolicLink.boolValue;
}

- (BOOL)sourceIsSupported:(NSURL *)url isDirectory:(BOOL)isDirectory {
    NSNumber *regularFile = nil;
    [url getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:nil];
    if (!isDirectory) return regularFile.boolValue;

    __block BOOL enumerationFailed = NO;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:url
        includingPropertiesForKeys:@[
            NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey
        ]
        options:0
        errorHandler:^BOOL(__unused NSURL *itemURL, __unused NSError *error) {
            enumerationFailed = YES;
            return NO;
        }];
    for (NSURL *childURL in enumerator) {
        NSNumber *childDirectory = nil;
        NSNumber *childRegularFile = nil;
        NSNumber *childSymbolicLink = nil;
        [childURL getResourceValue:&childDirectory forKey:NSURLIsDirectoryKey error:nil];
        [childURL getResourceValue:&childRegularFile forKey:NSURLIsRegularFileKey error:nil];
        [childURL getResourceValue:&childSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (childSymbolicLink.boolValue ||
            (!childDirectory.boolValue && !childRegularFile.boolValue)) {
            return NO;
        }
    }
    return !enumerationFailed;
}

- (NSError *)errorWithCode:(PatchManagerErrorCode)code text:(NSString *)text {
    return [NSError errorWithDomain:kPatchManagerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Patches"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Patch modules

- (UIView *)modulesHeaderView {
    NSArray<NSString *> *moduleNames = @[
        @"Assist", @"Drag", @"Neck", @"Chest", @"Body 100%"
    ];
    CGFloat width = CGRectGetWidth(self.view.bounds);
    if (width < 1.0) width = UIScreen.mainScreen.bounds.size.width;
    width = MAX(width, 280.0);

    CGFloat top = 12.0;
    CGFloat rowHeight = 56.0;
    CGFloat rowSpacing = 8.0;
    CGFloat height = top + 24.0 +
        moduleNames.count * rowHeight +
        (moduleNames.count - 1) * rowSpacing + 16.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    header.backgroundColor = UIColor.blackColor;

    UILabel *title = [[UILabel alloc] initWithFrame:
        CGRectMake(16, top, width - 32, 22)];
    title.text = @"Patch modules";
    title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    [header addSubview:title];

    NSMutableArray<UISwitch *> *switches =
        [NSMutableArray arrayWithCapacity:moduleNames.count];

    [moduleNames enumerateObjectsUsingBlock:^(NSString *name,
                                               NSUInteger index,
                                               __unused BOOL *stop) {
        CGFloat y = top + 28.0 + index * (rowHeight + rowSpacing);
        UIView *row = [[UIView alloc]
            initWithFrame:CGRectMake(16, y, width - 32, rowHeight)];
        row.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        row.layer.cornerRadius = 14.0;
        row.layer.borderColor = [UIColor colorWithWhite:0.24 alpha:1.0].CGColor;
        row.layer.borderWidth = 1.0;
        [header addSubview:row];

        UILabel *label = [[UILabel alloc]
            initWithFrame:CGRectMake(16, 0, width - 150, rowHeight)];
        label.text = name;
        label.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        [row addSubview:label];

        UISwitch *moduleSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        [moduleSwitch sizeToFit];
        // Keep the control inside the card with a visible trailing inset.
        // The previous position left the switch almost flush with the edge.
        moduleSwitch.center = CGPointMake(
            CGRectGetWidth(row.bounds) - 42.0,
            rowHeight / 2.0
        );
        moduleSwitch.onTintColor =
            [UIColor colorWithRed:0.12 green:0.72 blue:0.36 alpha:1.0];
        moduleSwitch.tag = index;
        moduleSwitch.accessibilityLabel = name;
        [moduleSwitch addTarget:self
                         action:@selector(toggleModule:)
               forControlEvents:UIControlEventValueChanged];
        [row addSubview:moduleSwitch];
        [switches addObject:moduleSwitch];
    }];

    self.moduleSwitches = [switches copy];
    return header;
}

- (void)toggleModule:(UISwitch *)sender {
    // The switch itself is the only visible state indicator.
    // Keep the handler in place for the module action wiring.
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Patches is intentionally a modules-only screen. File operations live
    // in Files, where they can operate on application containers.
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"PatchItemCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSURL *itemURL = self.items[indexPath.row];
    BOOL isDirectory = NO;
    [self readIsDirectory:&isDirectory forURL:itemURL];
    cell.imageView.image = [UIImage systemImageNamed:isDirectory ? @"folder.fill" : @"doc.fill"];
    cell.imageView.tintColor = isDirectory
        ? [UIColor colorWithRed:0.98 green:0.70 blue:0.18 alpha:1.0]
        : [UIColor colorWithRed:0.35 green:0.70 blue:1.0 alpha:1.0];
    cell.textLabel.text = itemURL.lastPathComponent;
    cell.detailTextLabel.text = isDirectory ? @"Folder" : @"File";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSURL *itemURL = self.items[indexPath.row];
    BOOL isDirectory = NO;
    if ([self readIsDirectory:&isDirectory forURL:itemURL] && isDirectory) {
        PatchManagerViewController *child = [[PatchManagerViewController alloc]
            initWithDirectoryURL:itemURL];
        [self.navigationController pushViewController:child animated:YES];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSURL *itemURL = self.items[indexPath.row];
    BOOL isDirectory = NO;
    [self readIsDirectory:&isDirectory forURL:itemURL];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *replace = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"Replace"
                          handler:^(__unused UIContextualAction *action,
                                    __unused UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
        __strong typeof(weakSelf) self = weakSelf;
        [self presentDocumentPickerAllowingMultiple:NO replacementTarget:itemURL];
        completionHandler(YES);
    }];
    replace.backgroundColor = [UIColor colorWithRed:0.25 green:0.52 blue:0.95 alpha:1.0];
    UIContextualAction *rename = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"Rename"
                          handler:^(__unused UIContextualAction *action,
                                    __unused UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
        __strong typeof(weakSelf) self = weakSelf;
        [self promptForRename:itemURL];
        completionHandler(YES);
    }];
    rename.backgroundColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    UIContextualAction *delete = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"Delete"
                          handler:^(__unused UIContextualAction *action,
                                    __unused UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
        __strong typeof(weakSelf) self = weakSelf;
        [self confirmDelete:itemURL];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, rename, replace]];
}

@end