#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ExternalPatchErrorDomain;

typedef NS_ENUM(NSInteger, ExternalPatchErrorCode) {
    ExternalPatchErrorUnsupportedFormat = 1,
    ExternalPatchErrorUnsupportedVersion,
    ExternalPatchErrorInvalidPasswordOrCorruptedPackage,
    ExternalPatchErrorInvalidBundleIdentifier,
    ExternalPatchErrorUnsafeTargetPath,
    ExternalPatchErrorSizeLimitExceeded,
    ExternalPatchErrorDuplicateTarget,
    ExternalPatchErrorInvalidProject,
    ExternalPatchErrorKeychainFailed,
    ExternalPatchErrorTargetAppUnavailable,
    ExternalPatchErrorSymbolicLinkUnsupported,
    ExternalPatchErrorApplyFailed,
    ExternalPatchErrorRestoreFailed
};

/// The Objective-C representation deliberately uses the same Codable keys as
/// 3105's Swift PatchProject/PatchRule/PatchDirectory types. This lets the
/// IPA-bot build read and write the original .3105 package format.
@interface ExternalPatchPackageSummary : NSObject
@property(nonatomic, readonly) NSString *packageID;
@property(nonatomic, readonly) NSInteger schemaVersion;
@property(nonatomic, readonly) BOOL passwordProtected;
@property(nonatomic, readonly) NSData *keyFingerprint;
- (instancetype)initWithPackageID:(NSString *)packageID
                     schemaVersion:(NSInteger)schemaVersion
                 passwordProtected:(BOOL)passwordProtected
                    keyFingerprint:(NSData *)keyFingerprint;
@end

@interface ExternalPatchTransactionReceipt : NSObject
@property(nonatomic, readonly) NSString *transactionID;
@property(nonatomic, readonly) NSString *projectID;
@property(nonatomic, readonly) NSURL *journalURL;
- (instancetype)initWithTransactionID:(NSString *)transactionID
                            projectID:(NSString *)projectID
                          journalURL:(NSURL *)journalURL;
@end

/// Core services used by the UIKit compatibility UI. Projects are NSDictionary
/// values with the exact keys documented in PatchProjectModels.swift.
@interface ExternalPatchCore : NSObject

+ (NSURL *)patchesRootURL:(NSError **)error;
+ (NSURL *)packageRootURL:(NSError **)error;
+ (NSURL *)backupRootURL:(NSError **)error;

+ (nullable ExternalPatchPackageSummary *)inspectPackageData:(NSData *)data
                                                        error:(NSError **)error;
+ (nullable NSDictionary *)decodePackageData:(NSData *)data
                                    password:(nullable NSString *)password
                                       error:(NSError **)error;
+ (nullable NSData *)encodeProject:(NSDictionary *)project
                           password:(nullable NSString *)password
                              error:(NSError **)error;
+ (nullable NSData *)updatePackageData:(NSData *)originalData
                               project:(NSDictionary *)project
                           contentKey:(NSData *)contentKey
                      schemaVersion:(NSInteger)schemaVersion
                                error:(NSError **)error;

+ (NSArray<NSDictionary *> *)loadPackageItems;
+ (BOOL)installPackageData:(NSData *)data
                 overwrite:(BOOL)overwrite
          unlockedPassword:(nullable NSString *)password
                     error:(NSError **)error;
+ (BOOL)deletePackageItem:(NSDictionary *)item error:(NSError **)error;

+ (nullable NSURL *)ensureWorkspaceForProject:(NSDictionary *)project
                                        error:(NSError **)error;
+ (nullable NSURL *)replaceWorkspaceForProject:(NSDictionary *)project
                                         error:(NSError **)error;
+ (nullable NSDictionary *)snapshotWorkspace:(NSURL *)workspaceURL
                                baseProject:(NSDictionary *)baseProject
                                      error:(NSError **)error;

+ (nullable ExternalPatchTransactionReceipt *)applyProject:(NSDictionary *)project
                                                      error:(NSError **)error;
+ (BOOL)restoreReceipt:(ExternalPatchTransactionReceipt *)receipt
                 error:(NSError **)error;
+ (nullable ExternalPatchTransactionReceipt *)latestReceiptForProjectID:(NSString *)projectID;

+ (BOOL)storeContentKey:(NSData *)contentKey
                summary:(ExternalPatchPackageSummary *)summary
                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END