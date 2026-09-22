#import "CleanerViewController.h"
#import "FilesViewController.h"
#import "Localization.h"
#import <dirent.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

typedef struct {
    long long bytes;
    NSUInteger itemCount;
} ExternalCleanerUsage;

typedef struct {
    NSUInteger removedItemCount;
    NSUInteger failedItemCount;
} ExternalCleanerRemoval;

static NSString * const kExternalCleanerPublicPrefix =
    @"/var/mobile/Containers/Data/Application/";
static NSString * const kExternalCleanerPrivatePrefix =
    @"/private/var/mobile/Containers/Data/Application/";

static UIColor *ExternalCleanerAccentColor(void) {
    return EXThemeAccentColor();
}

static BOOL ExternalCleanerIsContainerPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    NSString *canonical = [path stringByStandardizingPath];
    if ([canonical hasPrefix:kExternalCleanerPrivatePrefix]) {
        canonical = [@"/var" stringByAppendingString:
                     [canonical substringFromIndex:@"/private/var".length]];
    }
    if (![canonical hasPrefix:kExternalCleanerPublicPrefix]) return NO;
    NSString *relative = [canonical substringFromIndex:kExternalCleanerPublicPrefix.length];
    NSArray<NSString *> *components = [relative componentsSeparatedByString:@"/"];
    if (components.count != 1) return NO;
    return [[NSUUID alloc] initWithUUIDString:components.firstObject] != nil;
}

static ExternalCleanerUsage ExternalCleanerScanDirectory(NSString *directoryPath) {
    ExternalCleanerUsage usage = {0, 0};
    DIR *directory = opendir(directoryPath.fileSystemRepresentation);
    if (!directory) return usage;

    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            continue;
        }
        NSString *childPath = [directoryPath stringByAppendingPathComponent:name];
        struct stat information;
        if (lstat(childPath.fileSystemRepresentation, &information) != 0) continue;

        if ((information.st_mode & S_IFMT) == S_IFREG) {
            usage.bytes += MAX(0, (long long)information.st_size);
            usage.itemCount += 1;
        } else if ((information.st_mode & S_IFMT) == S_IFDIR) {
            ExternalCleanerUsage nested = ExternalCleanerScanDirectory(childPath);
            usage.bytes += nested.bytes;
            usage.itemCount += nested.itemCount;
        }
    }
    closedir(directory);
    return usage;
}

static ExternalCleanerUsage ExternalCleanerScanContainer(NSString *containerPath) {
    if (!ExternalCleanerIsContainerPath(containerPath)) {
        ExternalCleanerUsage empty = {0, 0};
        return empty;
    }
    NSString *cachePath = [containerPath stringByAppendingPathComponent:@"Library/Caches"];
    NSString *temporaryPath = [containerPath stringByAppendingPathComponent:@"tmp"];
    ExternalCleanerUsage cache = ExternalCleanerScanDirectory(cachePath);
    ExternalCleanerUsage temporary = ExternalCleanerScanDirectory(temporaryPath);
    ExternalCleanerUsage total = {
        cache.bytes + temporary.bytes,
        cache.itemCount + temporary.itemCount
    };
    return total;
}

static void ExternalCleanerRemoveContents(
    NSString *directoryPath,
    ExternalCleanerRemoval *removal
) {
    DIR *directory = opendir(directoryPath.fileSystemRepresentation);
    if (!directory) return;

    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            continue;
        }
        NSString *childPath = [directoryPath stringByAppendingPathComponent:name];
        struct stat information;
        if (lstat(childPath.fileSystemRepresentation, &information) != 0) continue;

        mode_t type = information.st_mode & S_IFMT;
        if (type == S_IFREG) {
            if (unlink(childPath.fileSystemRepresentation) == 0) {
                removal->removedItemCount += 1;
            } else if (errno != ENOENT) {
                removal->failedItemCount += 1;
            }
        } else if (type == S_IFDIR) {
            ExternalCleanerRemoveContents(childPath, removal);
            if (rmdir(childPath.fileSystemRepresentation) != 0 &&
                errno != ENOENT && errno != ENOTEMPTY) {
                removal->failedItemCount += 1;
            }
        }
    }
    closedir(directory);
}

static BOOL ExternalCleanerCleanContainer(
    NSString *containerPath,
    ExternalCleanerRemoval *removal,
    ExternalCleanerUsage *after
) {
    if (!ExternalCleanerIsContainerPath(containerPath)) return NO;
    NSString *cachePath = [containerPath stringByAppendingPathComponent:@"Library/Caches"];
    NSString *temporaryPath = [containerPath stringByAppendingPathComponent:@"tmp"];
    ExternalCleanerRemoveContents(cachePath, removal);
    ExternalCleanerRemoveContents(temporaryPath, removal);
    *after = ExternalCleanerScanContainer(containerPath);
    return YES;
}

static NSString *ExternalCleanerSizeText(long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes
                                           countStyle:NSByteCountFormatterCountStyleFile];
}

@interface CleanerViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *records;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredRecords;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedBundleIDs;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UIBarButtonItem *selectAllBarButtonItem;
@property (nonatomic) BOOL cleaning;
- (void)updateSelectAllButton;
- (void)toggleSelectAll;
@end

@implementation CleanerViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _records = @[];
        _filteredRecords = @[];
        _selectedBundleIDs = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:0.20 alpha:1.0];
    self.tableView.rowHeight = 64.0;
    self.navigationItem.title = EXLocalizedString(@"cleaner.title");

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadCleaner)];
    self.navigationItem.rightBarButtonItem = refresh;
    UIBarButtonItem *cleanButton = [[UIBarButtonItem alloc]
        initWithTitle:EXLocalizedString(@"cleaner.confirm_action")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(confirmClean)];
    self.selectAllBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:EXLocalizedString(@"cleaner.select_all_button")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(toggleSelectAll)];
    self.navigationItem.leftBarButtonItems =
        @[self.selectAllBarButtonItem, cleanButton];

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 80)];
    footer.text = EXLocalizedString(@"cleaner.scope_footer");
    footer.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    footer.font = [UIFont systemFontOfSize:13.0];
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectInset(footer.frame, 16, 8);
    self.tableView.tableFooterView = footer;
    [self reloadCleaner];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.tintColor = ExternalCleanerAccentColor();
}

- (void)reloadCleaner {
    if (self.cleaning) return;
    self.cleaning = YES;
    [self.activityIndicator startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.activityIndicator];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
        for (NSDictionary *application in [FilesViewController availableApplications]) {
            NSString *path = application[@"path"];
            ExternalCleanerUsage usage = ExternalCleanerScanContainer(path);
            if (usage.bytes <= 0) continue;
            NSMutableDictionary *record = [application mutableCopy];
            record[@"bytes"] = @(usage.bytes);
            record[@"items"] = @(usage.itemCount);
            [records addObject:record];
        }
        [records sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSNumber *aBytes = a[@"bytes"];
            NSNumber *bBytes = b[@"bytes"];
            if (aBytes.longLongValue != bBytes.longLongValue) {
                return aBytes.longLongValue > bBytes.longLongValue
                    ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            CleanerViewController *self = weakSelf;
            if (!self) return;
            self.records = records;
            self.filteredRecords = records;
            [self.selectedBundleIDs removeAllObjects];
            self.cleaning = NO;
            [self updateSelectAllButton];
            [self.activityIndicator stopAnimating];
            self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                     target:self
                                     action:@selector(reloadCleaner)];
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.filteredRecords.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"CleanerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    }
    NSDictionary *record = self.filteredRecords[indexPath.row];
    cell.imageView.image = [UIImage systemImageNamed:@"trash.fill"];
    cell.imageView.tintColor = ExternalCleanerAccentColor();
    cell.textLabel.text = record[@"name"] ?: record[@"bundleID"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        ExternalCleanerSizeText([record[@"bytes"] longLongValue]),
        [NSString stringWithFormat:EXLocalizedString(@"cleaner.scanned_count"),
            (long long)[record[@"items"] unsignedIntegerValue]]];
    cell.accessoryType = [self.selectedBundleIDs containsObject:record[@"bundleID"]]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *record = self.filteredRecords[indexPath.row];
    NSString *bundleID = record[@"bundleID"];
    if ([self.selectedBundleIDs containsObject:bundleID]) {
        [self.selectedBundleIDs removeObject:bundleID];
    } else {
        [self.selectedBundleIDs addObject:bundleID];
    }
    [self updateSelectAllButton];
    [tableView reloadRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationNone];
}

- (void)confirmClean {
    if (self.cleaning || self.selectedBundleIDs.count == 0) return;
    long long selectedBytes = 0;
    for (NSDictionary *record in self.records) {
        if ([self.selectedBundleIDs containsObject:record[@"bundleID"]]) {
            selectedBytes += [record[@"bytes"] longLongValue];
        }
    }
    NSString *message = [NSString stringWithFormat:
        @"External will permanently delete Library/Caches and tmp from %lu selected apps (%@). Close those apps first. This cannot be undone.",
        (unsigned long)self.selectedBundleIDs.count,
        ExternalCleanerSizeText(selectedBytes)];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:EXLocalizedString(@"cleaner.confirm_title")
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"cleaner.confirm_action")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self cleanSelectedApps];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleSelectAll {
    if (self.filteredRecords.count == 0 || self.cleaning) return;
    BOOL allSelected = YES;
    for (NSDictionary *record in self.filteredRecords) {
        if (![self.selectedBundleIDs containsObject:record[@"bundleID"]]) {
            allSelected = NO;
            break;
        }
    }
    if (allSelected) {
        for (NSDictionary *record in self.filteredRecords) {
            [self.selectedBundleIDs removeObject:record[@"bundleID"]];
        }
    } else {
        for (NSDictionary *record in self.filteredRecords) {
            [self.selectedBundleIDs addObject:record[@"bundleID"]];
        }
    }
    [self updateSelectAllButton];
    [self.tableView reloadData];
}

- (void)updateSelectAllButton {
    BOOL allSelected = self.filteredRecords.count > 0;
    for (NSDictionary *record in self.filteredRecords) {
        if (![self.selectedBundleIDs containsObject:record[@"bundleID"]]) {
            allSelected = NO;
            break;
        }
    }
    self.selectAllBarButtonItem.title = EXLocalizedString(
        allSelected ? @"cleaner.deselect_all_button" : @"cleaner.select_all_button"
    );
    self.selectAllBarButtonItem.enabled =
        self.filteredRecords.count > 0 && !self.cleaning;
}

- (void)cleanSelectedApps {
    if (self.cleaning) return;
    NSArray<NSDictionary *> *selected = [self.records filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, NSDictionary *_) {
            return [self.selectedBundleIDs containsObject:record[@"bundleID"]];
        }]];
    if (selected.count == 0) return;

    self.cleaning = YES;
    [self.activityIndicator startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *remaining = [NSMutableArray array];
        NSUInteger removed = 0;
        NSUInteger failed = 0;
        long long freed = 0;
        for (NSDictionary *record in selected) {
            ExternalCleanerUsage before = {
                [record[@"bytes"] longLongValue],
                [record[@"items"] unsignedIntegerValue]
            };
            ExternalCleanerRemoval removal = {0, 0};
            ExternalCleanerUsage after = {0, 0};
            if (!ExternalCleanerCleanContainer(record[@"path"], &removal, &after)) {
                failed += 1;
                continue;
            }
            removed += removal.removedItemCount;
            failed += removal.failedItemCount;
            freed += MAX(0, before.bytes - after.bytes);
            if (after.bytes > 0) {
                NSMutableDictionary *updated = [record mutableCopy];
                updated[@"bytes"] = @(after.bytes);
                updated[@"items"] = @(after.itemCount);
                [remaining addObject:updated];
            }
        }
        NSPredicate *notSelected = [NSPredicate predicateWithBlock:^BOOL(
            NSDictionary *record, NSDictionary *_) {
            return ![weakSelf.selectedBundleIDs containsObject:record[@"bundleID"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            CleanerViewController *self = weakSelf;
            if (!self) return;
            NSMutableArray *updatedRecords = [NSMutableArray array];
            [updatedRecords addObjectsFromArray:
                [self.records filteredArrayUsingPredicate:notSelected]];
            [updatedRecords addObjectsFromArray:remaining];
            self.records = updatedRecords;
            self.filteredRecords = updatedRecords;
            [self.selectedBundleIDs removeAllObjects];
            self.cleaning = NO;
            [self.activityIndicator stopAnimating];
            self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                     target:self
                                     action:@selector(reloadCleaner)];
            [self.tableView reloadData];

            NSString *message = [NSString stringWithFormat:
                @"Freed %@ by removing %lu files. %lu items or apps could not be cleaned.",
                ExternalCleanerSizeText(freed),
                (unsigned long)removed,
                (unsigned long)failed];
            UIAlertController *result = [UIAlertController
                alertControllerWithTitle:EXLocalizedString(@"cleaner.result_title")
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:EXLocalizedString(@"common.done")
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
            [self presentViewController:result animated:YES completion:nil];
        });
    });
}

@end