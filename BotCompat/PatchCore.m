#import "PatchCore.h"
#import "CommonCryptoCompat.h"
#import "bad_query.h"
#import "mcm_bridge.h"
#import "SandboxAccessBridge.h"
#import "../ThreeOneOSFive/helpers/AppIconHelper.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const ExternalPatchErrorDomain = @"com.dts.external.patch";

static const NSInteger kLatestSchema = 3;
static const NSInteger kMinimumSchema = 1;
static const NSInteger kDefaultKDFIterations = 250000;
static const NSInteger kMinimumKDFIterations = 100000;
static const NSInteger kMaximumKDFIterations = 1000000;
static const NSUInteger kMaximumPathBytes = 4096;
static NSString * const kMagic = @"3105PATCH\0";
static NSString * const kJournalFilename = @"journal.plist";
static NSString * const kManifestFilename = @".3105-project.plist";
static NSString * const kKeychainService = @"com.apple.mobile.MobileHouseArrest.patch-keys";
/*
 * Keep this in the same spelling used by 3105's filesystem fallback.  iOS
 * may report the same location as either /var or /private/var; all security
 * checks below canonicalize both spellings before comparing them.
 */
static NSString * const kApplicationDataRoot = @"/var/mobile/Containers/Data/Application";

static NSError *PatchError(ExternalPatchErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ExternalPatchErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Patch operation failed."}];
}

static BOOL Fail(NSError **error, ExternalPatchErrorCode code, NSString *message) {
    if (error) *error = PatchError(code, message);
    return NO;
}

static NSString *UUIDString(void) {
    return [NSUUID UUID].UUIDString;
}

static BOOL IsUUID(NSString *value) {
    return value.length > 0 && [[NSUUID alloc] initWithUUIDString:value] != nil;
}

static NSData *SHA256Data(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (!ExternalCCSHA256(data.bytes, (CC_LONG)data.length, digest)) return nil;
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static BOOL RandomBytes(NSUInteger count, NSMutableData **result) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    if (SecRandomCopyBytes(kSecRandomDefault, count, data.mutableBytes) != errSecSuccess) {
        return NO;
    }
    *result = data;
    return YES;
}

static NSData *PBKDF2(NSString *password, NSData *salt, uint32_t iterations) {
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *result = [NSMutableData dataWithLength:32];
    int status = ExternalCCKeyDerivationPBKDF(kCCPBKDF2,
                                               passwordData.bytes,
                                               passwordData.length,
                                               salt.bytes,
                                               salt.length,
                                               kCCPRFHmacAlgSHA256,
                                               iterations,
                                               result.mutableBytes,
                                               result.length);
    return status == kCCSuccess ? result : nil;
}

/*
 * CryptoKit's AES.GCM combined representation is nonce(12) + ciphertext +
 * tag(16). CommonCrypto exposes the same primitive on iOS 15 through the
 * one-shot GCM functions, so packages made here remain byte-compatible with
 * the Swift 3105 implementation.
 */
static NSData *GCMSeal(NSData *plain, NSData *key, NSData *aad) {
    if (key.length != 32) return nil;
    NSMutableData *nonce = nil;
    if (!RandomBytes(12, &nonce)) return nil;
    NSMutableData *cipher = [NSMutableData dataWithLength:plain.length];
    NSMutableData *tag = [NSMutableData dataWithLength:16];
    CCCryptorStatus status = ExternalCCCryptorGCMOneshotEncrypt(
        kCCAlgorithmAES,
        key.bytes, key.length,
        nonce.bytes, nonce.length,
        aad.bytes, aad.length,
        plain.bytes, plain.length,
        cipher.mutableBytes,
        tag.mutableBytes, tag.length);
    if (status != kCCSuccess) return nil;
    NSMutableData *combined = [nonce mutableCopy];
    [combined appendData:cipher];
    [combined appendData:tag];
    return combined;
}

static NSData *GCMOpen(NSData *combined, NSData *key, NSData *aad) {
    if (key.length != 32 || combined.length < 28) return nil;
    NSData *nonce = [combined subdataWithRange:NSMakeRange(0, 12)];
    NSData *tag = [combined subdataWithRange:NSMakeRange(combined.length - 16, 16)];
    NSRange cipherRange = NSMakeRange(12, combined.length - 28);
    NSData *cipher = [combined subdataWithRange:cipherRange];
    NSMutableData *plain = [NSMutableData dataWithLength:cipher.length];
    CCCryptorStatus status = ExternalCCCryptorGCMOneshotDecrypt(
        kCCAlgorithmAES,
        key.bytes, key.length,
        nonce.bytes, nonce.length,
        aad.bytes, aad.length,
        cipher.bytes, cipher.length,
        plain.mutableBytes,
        tag.bytes, tag.length);
    return status == kCCSuccess ? plain : nil;
}

static NSData *PlistData(id object, NSError **error) {
    NSError *plistError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&plistError];
    if (!data && error) *error = plistError ?: PatchError(ExternalPatchErrorInvalidProject, @"Could not encode project.");
    return data;
}

static id PlistObject(NSData *data, NSError **error) {
    NSError *plistError = nil;
    id object = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:nil
                                                              error:&plistError];
    if (!object && error) *error = plistError ?: PatchError(ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Corrupted package.");
    return object;
}

static NSString *CanonicalBundle(NSString *raw, NSError **error) {
    if (![raw isKindOfClass:NSString.class]) {
        Fail(error, ExternalPatchErrorInvalidBundleIdentifier, @"Invalid bundle identifier.");
        return nil;
    }
    NSString *value = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0 || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 ||
        IsUUID(value) || [value containsString:@"/"] || [value containsString:@"\\"] ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        Fail(error, ExternalPatchErrorInvalidBundleIdentifier, @"Invalid bundle identifier.");
        return nil;
    }
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"."];
    if (parts.count < 2) {
        Fail(error, ExternalPatchErrorInvalidBundleIdentifier, @"Invalid bundle identifier.");
        return nil;
    }
    for (NSString *part in parts) {
        if (part.length == 0 || [part hasPrefix:@"-"] || [part hasSuffix:@"-"]) {
            Fail(error, ExternalPatchErrorInvalidBundleIdentifier, @"Invalid bundle identifier.");
            return nil;
        }
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
        if ([[part stringByTrimmingCharactersInSet:allowed] length] != 0) {
            Fail(error, ExternalPatchErrorInvalidBundleIdentifier, @"Invalid bundle identifier.");
            return nil;
        }
    }
    return value;
}

static NSString *CanonicalRelativePath(NSString *raw, NSError **error) {
    if (![raw isKindOfClass:NSString.class]) {
        Fail(error, ExternalPatchErrorUnsafeTargetPath, @"Unsafe target path.");
        return nil;
    }
    NSString *value = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0 || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kMaximumPathBytes ||
        [value hasPrefix:@"/"] || [value containsString:@"\\"] || [value containsString:@"//"] ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        Fail(error, ExternalPatchErrorUnsafeTargetPath, @"Unsafe target path.");
        return nil;
    }
    for (NSString *part in [value componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@"."] || [part isEqualToString:@".."]) {
            Fail(error, ExternalPatchErrorUnsafeTargetPath, @"Unsafe target path.");
            return nil;
        }
    }
    return value;
}

static NSString *CanonicalFilePath(NSString *path) {
    NSString *standard = [path stringByStandardizingPath];
    if ([standard isEqualToString:@"/var"] || [standard hasPrefix:@"/var/"]) {
        standard = [@"/private" stringByAppendingString:standard];
    }
    return [standard stringByStandardizingPath];
}

static NSString *ContainedPath(NSString *root, NSString *relative, NSError **error) {
    NSString *path = CanonicalRelativePath(relative, error);
    if (!path) return nil;
    NSString *canonicalRoot = CanonicalFilePath(root);
    NSString *target = canonicalRoot;
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        target = [target stringByAppendingPathComponent:component];
    }
    target = CanonicalFilePath(target);
    // CanonicalRelativePath rejects absolute paths, traversal, separators in
    // components, and control characters. Appending each safe component keeps
    // this newly-created workspace inside its bundle root without relying on
    // /var versus /private/var textual path equality.
    return target;
}

static NSString *TargetKey(NSString *bundle, NSString *path) {
    // Do not put the NUL directly in the format string.  In an Objective-C
    // string literal it terminates the C format string, so every path in the
    // same bundle would otherwise collapse to the same key.
    unichar nul = 0;
    NSString *separator = [NSString stringWithCharacters:&nul length:1];
    return [NSString stringWithFormat:@"%@%@%@", bundle, separator, path];
}

static NSArray<NSString *> *ProjectBundles(NSDictionary *project) {
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *bundle in project[@"bundleIdentifiers"] ?: @[]) {
        if (![seen containsObject:bundle]) {
            [seen addObject:bundle];
            [result addObject:bundle];
        }
    }
    for (NSDictionary *directory in project[@"directories"] ?: @[]) {
        NSString *bundle = directory[@"bundleID"];
        if (bundle && ![seen containsObject:bundle]) {
            [seen addObject:bundle];
            [result addObject:bundle];
        }
    }
    for (NSDictionary *rule in project[@"rules"] ?: @[]) {
        NSString *bundle = rule[@"bundleID"];
        if (bundle && ![seen containsObject:bundle]) {
            [seen addObject:bundle];
            [result addObject:bundle];
        }
    }
    return result;
}

static BOOL ValidateProject(NSDictionary *project, NSError **error) {
    if (![project isKindOfClass:NSDictionary.class] ||
        ![project[@"id"] isKindOfClass:NSString.class] || !IsUUID(project[@"id"]) ||
        ![project[@"name"] isKindOfClass:NSString.class] ||
        ![project[@"createdAt"] isKindOfClass:NSDate.class] ||
        ![project[@"updatedAt"] isKindOfClass:NSDate.class] ||
        ![project[@"bundleIdentifiers"] isKindOfClass:NSArray.class] ||
        ![project[@"directories"] isKindOfClass:NSArray.class] ||
        ![project[@"rules"] isKindOfClass:NSArray.class] ||
        [[project[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0 ||
        [project[@"name"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 120 ||
        ProjectBundles(project).count == 0) {
        return Fail(error, ExternalPatchErrorInvalidProject, @"Invalid patch project.");
    }
    NSMutableSet *bundles = [NSMutableSet set];
    for (NSString *rawBundle in project[@"bundleIdentifiers"] ?: @[]) {
        NSError *e = nil;
        NSString *bundle = CanonicalBundle(rawBundle, &e);
        if (!bundle || ![bundle isEqual:rawBundle] || [bundles containsObject:bundle]) {
            return Fail(error, ExternalPatchErrorInvalidProject, @"Invalid patch project.");
        }
        [bundles addObject:bundle];
    }
    NSMutableSet *directoryIDs = [NSMutableSet set];
    NSMutableSet *directoryTargets = [NSMutableSet set];
    for (NSDictionary *directory in project[@"directories"] ?: @[]) {
        NSError *e = nil;
        NSString *bundle = CanonicalBundle(directory[@"bundleID"], &e);
        NSString *path = CanonicalRelativePath(directory[@"relativePath"], &e);
        NSString *identifier = directory[@"id"];
        if (!bundle || !path || ![bundle isEqual:directory[@"bundleID"]] ||
            ![path isEqual:directory[@"relativePath"]] || !IsUUID(identifier) ||
            [directoryIDs containsObject:identifier]) {
            return Fail(error, ExternalPatchErrorInvalidProject, @"Invalid patch project.");
        }
        [directoryIDs addObject:identifier];
        if (bundles.count && ![bundles containsObject:bundle]) {
            return Fail(error, ExternalPatchErrorInvalidProject, @"Project references an undeclared bundle.");
        }
        NSString *directoryTarget = TargetKey(bundle, path);
        if ([directoryTargets containsObject:directoryTarget]) {
            return Fail(error, ExternalPatchErrorDuplicateTarget, @"Duplicate patch target.");
        }
        [directoryTargets addObject:directoryTarget];
    }
    NSMutableSet *ruleIDs = [NSMutableSet set];
    NSMutableSet *targets = [NSMutableSet set];
    for (NSDictionary *rule in project[@"rules"] ?: @[]) {
        NSError *e = nil;
        NSString *bundle = CanonicalBundle(rule[@"bundleID"], &e);
        NSString *path = CanonicalRelativePath(rule[@"relativePath"], &e);
        NSString *filename = rule[@"replacementFilename"];
        NSString *identifier = rule[@"id"];
        if (!bundle || !path || ![bundle isEqual:rule[@"bundleID"]] ||
            ![path isEqual:rule[@"relativePath"]] || !IsUUID(identifier) ||
            [ruleIDs containsObject:identifier] || ![filename isKindOfClass:NSString.class] ||
            filename.length == 0 || [filename lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 ||
            [filename containsString:@"/"] || [filename containsString:@"\\"] ||
            [filename rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            ![rule[@"replacementData"] isKindOfClass:NSData.class]) {
            return Fail(error, ExternalPatchErrorInvalidProject, @"Invalid patch rule.");
        }
        [ruleIDs addObject:identifier];
        if (bundles.count && ![bundles containsObject:bundle]) {
            return Fail(error, ExternalPatchErrorInvalidProject, @"Project references an undeclared bundle.");
        }
        NSString *key = TargetKey(bundle, path);
        if ([targets containsObject:key] || [directoryTargets containsObject:key]) {
            return Fail(error, ExternalPatchErrorDuplicateTarget, @"Duplicate patch target.");
        }
        [targets addObject:key];
    }
    return YES;
}

static NSData *AAD(NSString *kind, NSString *projectID, NSInteger version) {
    return [[NSString stringWithFormat:@"3105PATCH/v%ld/%@/%@", (long)version, kind, projectID]
            dataUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *EnvelopeFromData(NSData *data, NSError **error) {
    NSData *magic = [kMagic dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length <= magic.length ||
        ![[data subdataWithRange:NSMakeRange(0, magic.length)] isEqual:magic]) {
        Fail(error, ExternalPatchErrorUnsupportedFormat, @"Unsupported patch package format.");
        return nil;
    }
    NSError *plistError = nil;
    NSDictionary *envelope = PlistObject([data subdataWithRange:NSMakeRange(magic.length, data.length - magic.length)], &plistError);
    if (![envelope isKindOfClass:NSDictionary.class]) {
        if (error) *error = plistError ?: PatchError(ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Corrupted patch package.");
        return nil;
    }
    NSInteger version = [envelope[@"schemaVersion"] integerValue];
    if (version < kMinimumSchema || version > kLatestSchema) {
        Fail(error, ExternalPatchErrorUnsupportedVersion, @"Unsupported patch package version.");
        return nil;
    }
    if (![envelope[@"packageID"] isKindOfClass:NSString.class] || !IsUUID(envelope[@"packageID"]) ||
        ![envelope[@"keyFingerprint"] isKindOfClass:NSData.class] ||
        [envelope[@"keyFingerprint"] length] != 32 ||
        ![envelope[@"encryptedPayload"] isKindOfClass:NSData.class] ||
        [envelope[@"encryptedPayload"] length] < 28) {
        Fail(error, ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Corrupted patch package.");
        return nil;
    }
    BOOL protected = [envelope[@"isPasswordProtected"] boolValue];
    if (protected) {
        NSInteger iterations = [envelope[@"kdfIterations"] integerValue];
        if (envelope[@"publicContentKey"] || ![envelope[@"kdfSalt"] isKindOfClass:NSData.class] ||
            [envelope[@"kdfSalt"] length] != 16 || iterations < kMinimumKDFIterations ||
            iterations > kMaximumKDFIterations || ![envelope[@"wrappedContentKey"] isKindOfClass:NSData.class]) {
            Fail(error, ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Corrupted protected package.");
            return nil;
        }
    } else if (envelope[@"kdfSalt"] || envelope[@"kdfIterations"] || envelope[@"wrappedContentKey"] ||
               ![envelope[@"publicContentKey"] isKindOfClass:NSData.class] ||
               [envelope[@"publicContentKey"] length] != 32) {
        Fail(error, ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Corrupted patch package.");
        return nil;
    }
    return envelope;
}

static NSDictionary *MakeEnvelope(NSDictionary *project,
                                  NSData *contentKey,
                                  BOOL protected,
                                  NSData *salt,
                                  NSNumber *iterations,
                                  NSData *wrappedKey,
                                  NSInteger schemaVersion,
                                  NSError **error) {
    NSString *projectID = project[@"id"];
    NSMutableDictionary *digests = [NSMutableDictionary dictionary];
    for (NSDictionary *rule in project[@"rules"] ?: @[]) {
        digests[rule[@"id"]] = SHA256Data(rule[@"replacementData"]);
    }
    NSDictionary *payload = @{@"project": project, @"replacementDigests": digests};
    NSData *payloadData = PlistData(payload, error);
    if (!payloadData) return nil;
    NSData *encrypted = GCMSeal(payloadData, contentKey, AAD(@"payload", projectID, schemaVersion));
    if (!encrypted) {
        if (error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Could not encrypt patch package.");
        return nil;
    }
    NSMutableDictionary *envelope = [@{
        @"schemaVersion": @(schemaVersion),
        @"packageID": projectID,
        @"isPasswordProtected": @(protected),
        @"keyFingerprint": SHA256Data(contentKey),
        @"encryptedPayload": encrypted
    } mutableCopy];
    if (protected) {
        envelope[@"keyAADVersion"] = @(schemaVersion);
        envelope[@"kdfSalt"] = salt;
        envelope[@"kdfIterations"] = iterations;
        envelope[@"wrappedContentKey"] = wrappedKey;
    } else {
        envelope[@"publicContentKey"] = contentKey;
    }
    return envelope;
}

static NSData *SerializeEnvelope(NSDictionary *envelope, NSError **error) {
    NSData *body = PlistData(envelope, error);
    if (!body) return nil;
    NSMutableData *result = [[kMagic dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [result appendData:body];
    return result;
}

static NSDictionary *DecodeEnvelope(NSDictionary *envelope, NSString *password, NSData *knownKey, NSError **error) {
    NSData *contentKey = knownKey;
    if ([envelope[@"isPasswordProtected"] boolValue]) {
        if (password.length == 0 || [password lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024) {
            Fail(error, ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Wrong password or corrupted package.");
            return nil;
        }
        NSData *wrappingKey = PBKDF2(password, envelope[@"kdfSalt"], (uint32_t)[envelope[@"kdfIterations"] integerValue]);
        contentKey = GCMOpen(envelope[@"wrappedContentKey"], wrappingKey,
                             AAD(@"key", envelope[@"packageID"], [envelope[@"keyAADVersion"] integerValue] ?: [envelope[@"schemaVersion"] integerValue]));
    } else if (!contentKey) {
        contentKey = envelope[@"publicContentKey"];
    }
    if (contentKey.length != 32 || ![SHA256Data(contentKey) isEqual:envelope[@"keyFingerprint"]]) {
        Fail(error, ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Wrong password or corrupted package.");
        return nil;
    }
    NSData *payloadData = GCMOpen(envelope[@"encryptedPayload"], contentKey,
                                  AAD(@"payload", envelope[@"packageID"], [envelope[@"schemaVersion"] integerValue]));
    NSError *payloadError = nil;
    NSDictionary *payload = payloadData ? PlistObject(payloadData, &payloadError) : nil;
    NSDictionary *project = payload[@"project"];
    NSDictionary *digests = payload[@"replacementDigests"];
    NSError *validationError = nil;
    if (![project isKindOfClass:NSDictionary.class] || !ValidateProject(project, &validationError) ||
        ![digests isKindOfClass:NSDictionary.class] || digests.count != [project[@"rules"] count]) {
        if (error) *error = PatchError(ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Wrong password or corrupted package.");
        return nil;
    }
    for (NSDictionary *rule in project[@"rules"]) {
        NSData *expected = digests[rule[@"id"]];
        if (![expected isEqual:SHA256Data(rule[@"replacementData"])]) {
            if (error) *error = PatchError(ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Wrong password or corrupted package.");
            return nil;
        }
    }
    return @{@"project": project, @"contentKey": contentKey};
}

@implementation ExternalPatchPackageSummary
- (instancetype)initWithPackageID:(NSString *)packageID
                     schemaVersion:(NSInteger)schemaVersion
                 passwordProtected:(BOOL)passwordProtected
                    keyFingerprint:(NSData *)keyFingerprint {
    if ((self = [super init])) {
        _packageID = [packageID copy];
        _schemaVersion = schemaVersion;
        _passwordProtected = passwordProtected;
        _keyFingerprint = [keyFingerprint copy];
    }
    return self;
}
@end

@implementation ExternalPatchTransactionReceipt
- (instancetype)initWithTransactionID:(NSString *)transactionID
                            projectID:(NSString *)projectID
                          journalURL:(NSURL *)journalURL {
    if ((self = [super init])) {
        _transactionID = [transactionID copy];
        _projectID = [projectID copy];
        _journalURL = [journalURL copy];
    }
    return self;
}
@end

@implementation ExternalPatchCore

+ (NSURL *)documentsURL:(NSError **)error {
    NSURL *url = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory
                                                         inDomain:NSUserDomainMask
                                                appropriateForURL:nil
                                                           create:YES
                                                            error:error];
    return url;
}

+ (NSURL *)patchesRootURL:(NSError **)error {
    NSURL *documents = [self documentsURL:error];
    if (!documents) return nil;
    NSURL *root = [documents URLByAppendingPathComponent:@"Patches" isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return root;
}

+ (NSURL *)packageRootURL:(NSError **)error {
    NSURL *base = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil
                                                            create:YES
                                                             error:error];
    if (!base) return nil;
    NSURL *root = [base URLByAppendingPathComponent:@"PatchProjects" isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return root;
}

+ (NSURL *)backupRootURL:(NSError **)error {
    NSURL *root = [[self packageRootURL:error] URLByAppendingPathComponent:@"Backups" isDirectory:YES];
    if (!root) return nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return root;
}

+ (ExternalPatchPackageSummary *)inspectPackageData:(NSData *)data error:(NSError **)error {
    NSDictionary *envelope = EnvelopeFromData(data, error);
    if (!envelope) return nil;
    return [[ExternalPatchPackageSummary alloc]
            initWithPackageID:envelope[@"packageID"]
            schemaVersion:[envelope[@"schemaVersion"] integerValue]
            passwordProtected:[envelope[@"isPasswordProtected"] boolValue]
            keyFingerprint:envelope[@"keyFingerprint"]];
}

+ (NSDictionary *)decodePackageData:(NSData *)data password:(NSString *)password error:(NSError **)error {
    NSDictionary *envelope = EnvelopeFromData(data, error);
    if (!envelope) return nil;
    NSError *decodeError = nil;
    NSDictionary *decoded = DecodeEnvelope(envelope, password, nil, &decodeError);
    if (!decoded && error) *error = decodeError ?: PatchError(ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Wrong password or corrupted package.");
    return decoded;
}

+ (NSData *)encodeProject:(NSDictionary *)project password:(NSString *)password error:(NSError **)error {
    if (!ValidateProject(project, error)) return nil;
    NSInteger version = kLatestSchema;
    NSMutableData *contentKey = nil;
    if (!RandomBytes(32, &contentKey)) {
        if (error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Could not generate package key.");
        return nil;
    }
    BOOL protected = password.length > 0;
    NSData *salt = nil;
    NSData *wrapped = nil;
    NSNumber *iterations = nil;
    if (protected) {
        if ([password lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024) {
            Fail(error, ExternalPatchErrorInvalidProject, @"Password is too long.");
            return nil;
        }
        NSMutableData *saltData = nil;
        if (!RandomBytes(16, &saltData)) {
            if (error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Could not generate package salt.");
            return nil;
        }
        salt = saltData;
        iterations = @(kDefaultKDFIterations);
        NSData *wrappingKey = PBKDF2(password, salt, (uint32_t)iterations.integerValue);
        wrapped = GCMSeal(contentKey, wrappingKey, AAD(@"key", project[@"id"], version));
        if (!wrapped) {
            if (error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Could not encrypt package key.");
            return nil;
        }
    }
    NSDictionary *envelope = MakeEnvelope(project, contentKey, protected, salt, iterations, wrapped, version, error);
    return envelope ? SerializeEnvelope(envelope, error) : nil;
}

+ (NSData *)updatePackageData:(NSData *)originalData
                       project:(NSDictionary *)project
                   contentKey:(NSData *)contentKey
              schemaVersion:(NSInteger)schemaVersion
                        error:(NSError **)error {
    NSDictionary *old = EnvelopeFromData(originalData, error);
    if (!old || ![project[@"id"] isEqual:old[@"packageID"]] ||
        ![contentKey isKindOfClass:NSData.class] || ![SHA256Data(contentKey) isEqual:old[@"keyFingerprint"]] ||
        !ValidateProject(project, error)) {
        if (error && !*error) *error = PatchError(ExternalPatchErrorInvalidPasswordOrCorruptedPackage, @"Package key or project is invalid.");
        return nil;
    }
    NSDictionary *envelope = MakeEnvelope(project, contentKey,
                                           [old[@"isPasswordProtected"] boolValue],
                                           old[@"kdfSalt"], old[@"kdfIterations"], old[@"wrappedContentKey"],
                                           schemaVersion ?: [old[@"schemaVersion"] integerValue], error);
    return envelope ? SerializeEnvelope(envelope, error) : nil;
}

static NSString *SanitizedFilename(NSString *name) {
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ "];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        [result appendFormat:@"%C", (unichar)([allowed characterIsMember:c] ? c : '-')];
    }
    NSString *trim = [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length > 80) trim = [trim substringToIndex:80];
    return trim.length ? trim : @"Patch";
}

static NSString *SanitizedWorkspaceName(NSString *name) {
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@"/:\0"];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        [result appendFormat:@"%C", (unichar)(([forbidden characterIsMember:c] || [[NSCharacterSet controlCharacterSet] characterIsMember:c]) ? '-' : c)];
    }
    NSString *trim = [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length > 80) trim = [trim substringToIndex:80];
    return trim.length ? trim : @"Patch";
}

+ (NSURL *)workspaceForProjectID:(NSString *)projectID error:(NSError **)error {
    NSURL *root = [self patchesRootURL:error];
    if (!root) return nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:root
                                                     includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error:error];
    for (NSURL *candidate in items) {
        NSNumber *directory = nil, *symlink = nil;
        [candidate getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        [candidate getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!directory.boolValue || symlink.boolValue) continue;
        NSData *manifestData = [NSData dataWithContentsOfURL:[candidate URLByAppendingPathComponent:kManifestFilename]];
        NSDictionary *manifest = manifestData ? PlistObject(manifestData, nil) : nil;
        if ([manifest[@"projectID"] isEqual:projectID] && [manifest[@"schemaVersion"] integerValue] == 1) return candidate;
    }
    return nil;
}

+ (NSURL *)createWorkspaceForProject:(NSDictionary *)project
                               error:(NSError **)error {
    if (!ValidateProject(project, error)) return nil;
    NSURL *root = [self patchesRootURL:error];
    if (!root) return nil;
    NSURL *existing = [self workspaceForProjectID:project[@"id"] error:nil];
    if (existing) return existing;
    NSString *base = SanitizedWorkspaceName(project[@"name"]);
    NSURL *destination = [root URLByAppendingPathComponent:base isDirectory:YES];
    NSInteger suffix = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:destination.path]) {
        destination = [root URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %ld", base, (long)suffix++] isDirectory:YES];
    }
    NSURL *staging = [root URLByAppendingPathComponent:[NSString stringWithFormat:@".3105-workspace-%@", UUIDString()] isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:staging withIntermediateDirectories:NO attributes:nil error:error]) return nil;
    @try {
        for (NSString *bundle in ProjectBundles(project)) {
            if (!CanonicalBundle(bundle, error)) @throw [NSException exceptionWithName:@"Patch" reason:@"invalid bundle" userInfo:nil];
            if (![fm createDirectoryAtURL:[staging URLByAppendingPathComponent:bundle isDirectory:YES] withIntermediateDirectories:NO attributes:nil error:error]) @throw [NSException exceptionWithName:@"Patch" reason:@"bundle" userInfo:nil];
        }
        for (NSDictionary *directory in project[@"directories"] ?: @[]) {
            NSString *bundleRoot = [staging URLByAppendingPathComponent:directory[@"bundleID"] isDirectory:YES].path;
            NSString *target = ContainedPath(bundleRoot, directory[@"relativePath"], error);
            if (!target || ![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:error]) @throw [NSException exceptionWithName:@"Patch" reason:@"directory" userInfo:nil];
        }
        for (NSDictionary *rule in project[@"rules"] ?: @[]) {
            NSString *bundleRoot = [staging URLByAppendingPathComponent:rule[@"bundleID"] isDirectory:YES].path;
            NSString *target = ContainedPath(bundleRoot, rule[@"relativePath"], error);
            if (!target || ![fm createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:error] ||
                ![fm createFileAtPath:target contents:rule[@"replacementData"] attributes:nil]) {
                if (error && !*error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Could not create workspace.");
                @throw [NSException exceptionWithName:@"Patch" reason:@"file" userInfo:nil];
            }
        }
        NSDictionary *manifest = @{@"schemaVersion": @1, @"projectID": project[@"id"], @"displayName": project[@"name"]};
        NSData *manifestData = PlistData(manifest, error);
        if (!manifestData || ![manifestData writeToURL:[staging URLByAppendingPathComponent:kManifestFilename] options:NSDataWritingAtomic error:error] ||
            ![fm moveItemAtURL:staging toURL:destination error:error]) @throw [NSException exceptionWithName:@"Patch" reason:@"manifest" userInfo:nil];
    } @catch (__unused NSException *exception) {
        [fm removeItemAtURL:staging error:nil];
        if (error && !*error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Could not create workspace.");
        return nil;
    }
    return destination;
}

+ (NSURL *)ensureWorkspaceForProject:(NSDictionary *)project error:(NSError **)error {
    NSURL *workspace = [self workspaceForProjectID:project[@"id"] error:nil];
    return workspace ?: [self createWorkspaceForProject:project error:error];
}

+ (NSURL *)replaceWorkspaceForProject:(NSDictionary *)project error:(NSError **)error {
    NSURL *root = [self patchesRootURL:error];
    if (!root) return nil;
    NSURL *old = [self workspaceForProjectID:project[@"id"] error:nil];
    NSURL *displaced = [root URLByAppendingPathComponent:[NSString stringWithFormat:@".3105-displaced-%@", UUIDString()] isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (old && ![fm moveItemAtURL:old toURL:displaced error:error]) return nil;
    NSURL *newURL = [self createWorkspaceForProject:project error:error];
    if (newURL) {
        [fm removeItemAtURL:displaced error:nil];
        return newURL;
    }
    if (old && [fm fileExistsAtPath:displaced.path]) [fm moveItemAtURL:displaced toURL:old error:nil];
    return nil;
}

+ (NSDictionary *)snapshotWorkspace:(NSURL *)workspaceURL baseProject:(NSDictionary *)baseProject error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:workspaceURL.path isDirectory:&isDirectory] || !isDirectory) {
        Fail(error, ExternalPatchErrorInvalidProject, @"Workspace is unavailable.");
        return nil;
    }
    NSDictionary *manifest = PlistObject([NSData dataWithContentsOfURL:[workspaceURL URLByAppendingPathComponent:kManifestFilename]], error);
    if (![manifest[@"projectID"] isEqual:baseProject[@"id"]] || [manifest[@"schemaVersion"] integerValue] != 1) {
        Fail(error, ExternalPatchErrorInvalidProject, @"Invalid workspace manifest.");
        return nil;
    }
    NSMutableDictionary *oldRules = [NSMutableDictionary dictionary];
    for (NSDictionary *rule in baseProject[@"rules"] ?: @[]) oldRules[TargetKey(rule[@"bundleID"], rule[@"relativePath"])] = rule[@"id"];
    NSMutableDictionary *oldDirectories = [NSMutableDictionary dictionary];
    for (NSDictionary *directory in baseProject[@"directories"] ?: @[]) oldDirectories[TargetKey(directory[@"bundleID"], directory[@"relativePath"])] = directory[@"id"];
    NSArray *top = [fm contentsOfDirectoryAtURL:workspaceURL includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] options:0 error:error];
    NSMutableArray *bundles = [NSMutableArray array], *directories = [NSMutableArray array], *rules = [NSMutableArray array];
    for (NSURL *bundleURL in [top sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent]; }]) {
        if ([bundleURL.lastPathComponent isEqual:kManifestFilename]) continue;
        NSNumber *dir = nil, *link = nil, *regular = nil;
        [bundleURL getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        [bundleURL getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        [bundleURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!dir.boolValue || link.boolValue || regular.boolValue || !CanonicalBundle(bundleURL.lastPathComponent, error)) {
            Fail(error, link.boolValue ? ExternalPatchErrorSymbolicLinkUnsupported : ExternalPatchErrorInvalidProject, @"Invalid workspace bundle.");
            return nil;
        }
        [bundles addObject:bundleURL.lastPathComponent];
        __block NSError *enumerationError = nil;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:bundleURL
                                         includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey]
                                                            options:0
                                                       errorHandler:^BOOL(__unused NSURL *url, NSError *e) {
            if (!enumerationError) enumerationError = e;
            return NO;
        }];
        for (NSURL *item in enumerator) {
            NSNumber *itemDir = nil, *itemLink = nil, *itemRegular = nil;
            [item getResourceValue:&itemDir forKey:NSURLIsDirectoryKey error:nil];
            [item getResourceValue:&itemLink forKey:NSURLIsSymbolicLinkKey error:nil];
            [item getResourceValue:&itemRegular forKey:NSURLIsRegularFileKey error:nil];
            if (itemLink.boolValue) {
                Fail(error, ExternalPatchErrorSymbolicLinkUnsupported, @"Symbolic links are not supported in patch workspaces.");
                return nil;
            }
            NSString *relative = [item.path substringFromIndex:bundleURL.path.length + 1];
            if (!CanonicalRelativePath(relative, error)) return nil;
            NSString *key = TargetKey(bundleURL.lastPathComponent, relative);
            if (itemDir.boolValue) {
                [directories addObject:@{@"id": oldDirectories[key] ?: UUIDString(), @"bundleID": bundleURL.lastPathComponent, @"relativePath": relative}];
            } else if (itemRegular.boolValue) {
                NSData *contents = [NSData dataWithContentsOfURL:item options:NSDataReadingMappedIfSafe error:error];
                if (!contents) return nil;
                [rules addObject:@{@"id": oldRules[key] ?: UUIDString(), @"bundleID": bundleURL.lastPathComponent, @"relativePath": relative, @"replacementFilename": item.lastPathComponent, @"replacementData": contents}];
            } else {
                Fail(error, ExternalPatchErrorInvalidProject, @"Workspace contains an unsupported item.");
                return nil;
            }
        }
        if (enumerationError) {
            if (error && !*error) *error = enumerationError;
            return nil;
        }
    }
    NSMutableArray *orderedBundles = [NSMutableArray array];
    for (NSString *bundle in baseProject[@"bundleIdentifiers"] ?: @[]) {
        if ([bundles containsObject:bundle] && ![orderedBundles containsObject:bundle]) [orderedBundles addObject:bundle];
    }
    for (NSString *bundle in bundles) if (![orderedBundles containsObject:bundle]) [orderedBundles addObject:bundle];
    NSDictionary *project = @{@"id": baseProject[@"id"], @"name": manifest[@"displayName"] ?: baseProject[@"name"],
                              @"createdAt": baseProject[@"createdAt"] ?: [NSDate date],
                              @"updatedAt": [NSDate date], @"bundleIdentifiers": orderedBundles,
                              @"directories": [directories sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [TargetKey(a[@"bundleID"], a[@"relativePath"]) compare:TargetKey(b[@"bundleID"], b[@"relativePath"])]; }],
                              @"rules": [rules sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [TargetKey(a[@"bundleID"], a[@"relativePath"]) compare:TargetKey(b[@"bundleID"], b[@"relativePath"])]; }]};
    return ValidateProject(project, error) ? project : nil;
}

static NSString *KeychainAccount(ExternalPatchPackageSummary *summary) {
    const unsigned char *bytes = summary.keyFingerprint.bytes;
    NSMutableString *fingerprint = [NSMutableString string];
    for (NSUInteger i = 0; i < summary.keyFingerprint.length; i++) [fingerprint appendFormat:@"%02x", bytes[i]];
    return [NSString stringWithFormat:@"%@.%@", summary.packageID, fingerprint];
}

+ (BOOL)storeContentKey:(NSData *)contentKey summary:(ExternalPatchPackageSummary *)summary error:(NSError **)error {
    if (contentKey.length != 32 || ![SHA256Data(contentKey) isEqual:summary.keyFingerprint]) return Fail(error, ExternalPatchErrorKeychainFailed, @"Could not store package key.");
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: kKeychainService,
                            (__bridge id)kSecAttrAccount: KeychainAccount(summary)};
    NSDictionary *attributes = @{(__bridge id)kSecValueData: contentKey,
                                 (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecSuccess) return YES;
    if (status != errSecItemNotFound) return Fail(error, ExternalPatchErrorKeychainFailed, @"Could not store package key.");
    NSMutableDictionary *newItem = [query mutableCopy];
    [newItem addEntriesFromDictionary:attributes];
    return SecItemAdd((__bridge CFDictionaryRef)newItem, NULL) == errSecSuccess
        ? YES : Fail(error, ExternalPatchErrorKeychainFailed, @"Could not store package key.");
}

static NSData *LoadKey(ExternalPatchPackageSummary *summary) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: kKeychainService,
                            (__bridge id)kSecAttrAccount: KeychainAccount(summary),
                            (__bridge id)kSecReturnData: @YES,
                            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = status == errSecSuccess ? [(__bridge NSData *)result copy] : nil;
    if (result) CFRelease(result);
    return data.length == 32 && [SHA256Data(data) isEqual:summary.keyFingerprint] ? data : nil;
}

+ (NSArray<NSDictionary *> *)loadPackageItems {
    NSURL *root = [self packageRootURL:nil];
    NSArray *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:root
                                                     includingPropertiesForKeys:nil
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error:nil];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (![url.pathExtension.lowercaseString isEqual:@"3105"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        NSError *inspectError = nil;
        ExternalPatchPackageSummary *summary = [self inspectPackageData:data error:&inspectError];
        if (!summary) continue;
        // Hide the package that older builds seeded from the former bundled
        // cache resource. REMOVE AIMS is now an internal switch instead.
        if ([summary.packageID isEqualToString:@"E283D362-F988-4AFD-B9E0-151D67428A88"]) {
            continue;
        }
        NSData *key = LoadKey(summary);
        NSDictionary *decoded = key ? DecodeEnvelope(EnvelopeFromData(data, nil), nil, key, nil) : nil;
        if (!decoded && !summary.passwordProtected) decoded = [self decodePackageData:data password:nil error:nil];
        NSMutableDictionary *item = [@{@"summary": summary, @"packageURL": url} mutableCopy];
        if (decoded) {
            item[@"project"] = decoded[@"project"];
            item[@"contentKey"] = decoded[@"contentKey"];
            if (summary.schemaVersion >= 2) [self ensureWorkspaceForProject:decoded[@"project"] error:nil];
        }
        [items addObject:item];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *da = a[@"project"][@"updatedAt"] ?: [NSDate distantPast];
        NSDate *db = b[@"project"][@"updatedAt"] ?: [NSDate distantPast];
        return [db compare:da];
    }];
}

+ (BOOL)installPackageData:(NSData *)data overwrite:(BOOL)overwrite unlockedPassword:(NSString *)password error:(NSError **)error {
    ExternalPatchPackageSummary *summary = [self inspectPackageData:data error:error];
    if (!summary) return NO;
    NSDictionary *decoded = [self decodePackageData:data password:password error:error];
    if (!decoded) return NO;
    NSURL *root = [self packageRootURL:error];
    if (!root) return NO;
    NSURL *existing = nil;
    for (NSDictionary *item in [self loadPackageItems]) {
        ExternalPatchPackageSummary *existingSummary = item[@"summary"];
        if ([existingSummary.packageID isEqual:summary.packageID]) existing = item[@"packageURL"];
    }
    if (existing && !overwrite) return Fail(error, ExternalPatchErrorInvalidProject, @"A package with this ID already exists.");
    NSURL *destination = existing;
    if (!destination) {
        NSString *base = SanitizedFilename(decoded[@"project"][@"name"]);
        destination = [root URLByAppendingPathComponent:[base stringByAppendingPathExtension:@"3105"]];
        NSInteger suffix = 2;
        while ([[NSFileManager defaultManager] fileExistsAtPath:destination.path]) {
            destination = [root URLByAppendingPathComponent:[[NSString stringWithFormat:@"%@-%ld", base, (long)suffix] stringByAppendingPathExtension:@"3105"]];
            suffix++;
        }
    }
    NSData *old = existing ? [NSData dataWithContentsOfURL:existing] : nil;
    if (![data writeToURL:destination options:NSDataWritingAtomic error:error]) return NO;
    BOOL workspaceOK = YES;
    if (summary.schemaVersion >= 2) {
        workspaceOK = [self replaceWorkspaceForProject:decoded[@"project"] error:error] != nil;
    }
    if (!workspaceOK) {
        if (old) [old writeToURL:destination options:NSDataWritingAtomic error:nil];
        else [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
        return NO;
    }
    if (summary.passwordProtected) [self storeContentKey:decoded[@"contentKey"] summary:summary error:nil];
    return YES;
}

+ (BOOL)deletePackageItem:(NSDictionary *)item error:(NSError **)error {
    ExternalPatchPackageSummary *summary = item[@"summary"];
    NSURL *url = item[@"packageURL"];
    if (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path] &&
        ![[NSFileManager defaultManager] removeItemAtURL:url error:error]) return NO;
    NSURL *workspace = [self workspaceForProjectID:summary.packageID error:nil];
    if (workspace) [[NSFileManager defaultManager] removeItemAtURL:workspace error:nil];
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: kKeychainService,
                            (__bridge id)kSecAttrAccount: KeychainAccount(summary)};
    SecItemDelete((__bridge CFDictionaryRef)query);
    return YES;
}

static BOOL IsSafeRoot(NSString *root) {
    NSString *canonical = CanonicalFilePath(root);
    NSString *canonicalApplicationDataRoot = CanonicalFilePath(kApplicationDataRoot);
    return [canonical hasPrefix:[canonicalApplicationDataRoot stringByAppendingString:@"/"]] &&
           IsUUID(canonical.lastPathComponent);
}

static NSDictionary *ContainerMetadata(NSString *containerPath) {
    NSString *metadataPath = [containerPath
        stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];

    /*
     * Data(contentsOf:) can be denied by the app sandbox even after the
     * kernel-access stage has completed.  3105 reads this small metadata file
     * through a file descriptor first, then falls back to Foundation.
     */
    NSMutableData *data = [NSMutableData data];
    FILE *file = fopen(metadataPath.fileSystemRepresentation, "r");
    if (file) {
        uint8_t buffer[64 * 1024];
        while (YES) {
            size_t count = fread(buffer, 1, sizeof(buffer), file);
            if (count == 0) break;
            [data appendBytes:buffer length:count];
            if (data.length > 2 * 1024 * 1024) {
                data = nil;
                break;
            }
        }
        fclose(file);
    }
    if (!data.length) {
        data = [NSData dataWithContentsOfFile:metadataPath].mutableCopy;
    }
    if (!data.length) return nil;

    id object = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:nil
                                                              error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *MetadataBundleIdentifier(NSString *containerPath) {
    NSDictionary *metadata = ContainerMetadata(containerPath);
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = metadata[@"MCMMetadataIdentifier"];
    if ([identifier isKindOfClass:NSString.class] && identifier.length) return identifier;
    NSDictionary *info = metadata[@"MCMMetadataInfo"];
    NSString *bundleID = [info isKindOfClass:NSDictionary.class]
        ? info[@"CFBundleIdentifier"] : nil;
    return [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
}

static NSArray<NSString *> *ApplicationContainerPaths(void) {
    NSString *filesystemRoot = kApplicationDataRoot;
    NSString *root = CanonicalFilePath(filesystemRoot);
    NSArray<NSString *> *entries = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:filesystemRoot error:nil];
    NSMutableOrderedSet<NSString *> *uniquePaths = [NSMutableOrderedSet orderedSet];
    for (NSString *entry in entries) {
        if (IsUUID(entry)) {
            [uniquePaths addObject:[root stringByAppendingPathComponent:entry]];
        }
    }

    /*
     * On iOS versions where the host app sees only its own container,
     * 3105's inode walk still enumerates the application-data directory after
     * the access primitive is active.
     */
    /*
     * bad_query_list normalizes /private/var back to /var before comparing
     * paths, so pass the non-private spelling to it.
     */
    char *rootCString = strdup(filesystemRoot.fileSystemRepresentation);
    if (!rootCString) return uniquePaths.array;
    char *listed = bad_query_list(rootCString, 2 * 1000 * 1000);
    free(rootCString);
    if (!listed) return uniquePaths.array;

    for (NSString *line in [[NSString stringWithUTF8String:listed]
                             componentsSeparatedByString:@"\n"]) {
        NSString *candidate = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (candidate.length == 0 || !IsUUID(candidate.lastPathComponent)) continue;
        NSString *canonical = CanonicalFilePath(candidate);
        if (IsSafeRoot(canonical)) [uniquePaths addObject:canonical];
    }
    free(listed);
    return uniquePaths.array;
}

static NSString *ResolveContainer(NSString *bundleID) {
    if (!CanonicalBundle(bundleID, nil)) return nil;
    NSString *detail = nil;
    NSString *path = MCMActivateContainerPath(2, bundleID, NO, &detail);
    if (path && IsSafeRoot(path)) {
        /*
         * Never trust a path merely because MCM returned an application
         * container.  A custom host can receive its own container here when
         * the MCM query is scoped, which would make "Apply" target the host
         * instead of the selected app.
         */
        NSString *resolvedIdentifier = MetadataBundleIdentifier(path);
        if ([resolvedIdentifier isEqualToString:bundleID]) {
            return CanonicalFilePath(path);
        }
    }

    /*
     * LaunchServices exposes the data container for an installed app on
     * several iOS versions where the MCM query above is scoped to the host.
     * This is the same single-app lookup used by 3105's AppIconHelper.
     */
    NSDictionary *appInfo = appInfoForBundleID(bundleID);
    NSString *knownContainer = appInfo[@"container"];
    if ([knownContainer isKindOfClass:NSString.class] &&
        IsSafeRoot(knownContainer) &&
        [MetadataBundleIdentifier(knownContainer) isEqualToString:bundleID]) {
        return CanonicalFilePath(knownContainer);
    }

    for (NSString *candidate in ApplicationContainerPaths()) {
        if ([MetadataBundleIdentifier(candidate) isEqualToString:bundleID] &&
            IsSafeRoot(candidate)) {
            return CanonicalFilePath(candidate);
        }
    }
    return nil;
}

static NSData *FileDigest(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    CC_SHA256_CTX context;
    if (!ExternalCCSHA256Init(&context)) return nil;
    while (YES) {
        NSData *chunk = [handle readDataOfLength:1024 * 1024];
        if (!chunk.length) break;
        if (!ExternalCCSHA256Update(&context, chunk.bytes, (CC_LONG)chunk.length)) return nil;
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (!ExternalCCSHA256Final(digest, &context)) return nil;
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static BOOL ValidateFileTarget(NSString *target, NSString *relative, NSString *root, BOOL allowMissingParents, NSError **error) {
    NSArray *parts = [relative componentsSeparatedByString:@"/"];
    NSString *cursor = root;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        cursor = [cursor stringByAppendingPathComponent:parts[i]];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:cursor isDirectory:&isDir]) {
            if (allowMissingParents) break;
            return Fail(error, ExternalPatchErrorApplyFailed, @"Patch parent directory is missing.");
        }
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:cursor error:nil];
        if (attrs[NSFileType] == NSFileTypeSymbolicLink) return Fail(error, ExternalPatchErrorSymbolicLinkUnsupported, @"Symbolic links are not supported.");
        if (!isDir) return Fail(error, ExternalPatchErrorApplyFailed, @"Patch parent is not a directory.");
    }
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:target isDirectory:&isDir]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:target error:nil];
        if (attrs[NSFileType] == NSFileTypeSymbolicLink) return Fail(error, ExternalPatchErrorSymbolicLinkUnsupported, @"Symbolic links are not supported.");
        if (isDir) return Fail(error, ExternalPatchErrorApplyFailed, @"Patch target is a directory.");
    }
    return YES;
}

static BOOL ValidateDirectoryTarget(NSString *target, NSString *root, NSError **error) {
    NSString *cursor = root;
    for (NSString *part in [[target substringFromIndex:root.length + 1] pathComponents]) {
        cursor = [cursor stringByAppendingPathComponent:part];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:cursor isDirectory:&isDir]) break;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:cursor error:nil];
        if (attrs[NSFileType] == NSFileTypeSymbolicLink) return Fail(error, ExternalPatchErrorSymbolicLinkUnsupported, @"Symbolic links are not supported.");
        if (!isDir) return Fail(error, ExternalPatchErrorApplyFailed, @"Patch directory conflicts with a file.");
    }
    return YES;
}

static BOOL AtomicWrite(NSData *data, NSString *target, NSError **error) {
    NSString *staging = [[target stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@".3105-patch-%@", UUIDString()]];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:target error:nil] ?: @{};
    NSMutableDictionary *writeAttrs = [NSMutableDictionary dictionary];
    if (attrs[NSFilePosixPermissions]) writeAttrs[NSFilePosixPermissions] = attrs[NSFilePosixPermissions];
    if (![[NSFileManager defaultManager] createFileAtPath:staging contents:data attributes:writeAttrs]) {
        return Fail(error, ExternalPatchErrorApplyFailed, @"Could not stage replacement file.");
    }
    int result = rename(staging.fileSystemRepresentation, target.fileSystemRepresentation);
    [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];
    return result == 0 ? YES : Fail(error, ExternalPatchErrorApplyFailed, @"Could not replace target file.");
}

static BOOL AtomicCopy(NSString *source, NSString *target, NSError **error) {
    NSString *staging = [[target stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@".3105-restore-%@", UUIDString()]];
    if (![[NSFileManager defaultManager] copyItemAtPath:source toPath:staging error:error]) return NO;
    int result = rename(staging.fileSystemRepresentation, target.fileSystemRepresentation);
    [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];
    return result == 0 ? YES : Fail(error, ExternalPatchErrorRestoreFailed, @"Could not restore original file.");
}

static BOOL WriteJournal(NSDictionary *journal, NSURL *url, NSError **error) {
    NSData *data = PlistData(journal, error);
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

static NSDictionary *ReadJournal(NSURL *url) {
    return PlistObject([NSData dataWithContentsOfURL:url], nil);
}

static BOOL RestoreRecords(NSArray *records, NSURL *transactionDirectory, NSDictionary *roots, BOOL requirePatchedDigest, NSArray *createdDirectories, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    /*
     * Validate every record before changing anything. This is the important
     * restore guarantee from 3105: an external edit cannot be silently
     * overwritten by a restore.
     */
    for (NSDictionary *record in records) {
        NSString *root = roots[record[@"bundleID"]];
        NSString *target = ContainedPath(root, record[@"relativePath"], nil);
        if (!target) return Fail(error, ExternalPatchErrorRestoreFailed, @"Unsafe restore target.");
        if (requirePatchedDigest &&
            (![fm fileExistsAtPath:target] || ![FileDigest(target) isEqual:record[@"replacementDigest"]])) {
            return Fail(error, ExternalPatchErrorRestoreFailed, @"Target changed after patch application.");
        }
        if ([record[@"originalExisted"] boolValue]) {
            NSString *backup = [transactionDirectory.path stringByAppendingPathComponent:record[@"backupFilename"]];
            if (![fm fileExistsAtPath:backup] || ![FileDigest(backup) isEqual:record[@"originalDigest"]]) {
                return Fail(error, ExternalPatchErrorRestoreFailed, @"Patch backup is missing or corrupted.");
            }
        }
    }
    for (NSDictionary *record in [records reverseObjectEnumerator]) {
        NSString *root = roots[record[@"bundleID"]];
        NSString *target = ContainedPath(root, record[@"relativePath"], nil);
        if ([record[@"originalExisted"] boolValue]) {
            NSString *backup = [transactionDirectory.path stringByAppendingPathComponent:record[@"backupFilename"]];
            if (!AtomicCopy(backup, target, error)) return NO;
        } else if (target && [fm fileExistsAtPath:target]) {
            if (![fm removeItemAtPath:target error:error]) return NO;
        }
    }
    for (NSDictionary *directory in [createdDirectories reverseObjectEnumerator]) {
        NSString *root = roots[directory[@"bundleID"]];
        NSString *target = ContainedPath(root, directory[@"relativePath"], nil);
        BOOL isDir = NO;
        if (target && [fm fileExistsAtPath:target isDirectory:&isDir] && isDir &&
            [fm contentsOfDirectoryAtPath:target error:nil].count == 0 &&
            ![fm removeItemAtPath:target error:error]) return NO;
    }
    return YES;
}

+ (ExternalPatchTransactionReceipt *)applyProject:(NSDictionary *)project error:(NSError **)error {
    if (!ValidateProject(project, error) || (![project[@"rules"] count] && ![project[@"directories"] count])) {
        if (error && !*error) *error = PatchError(ExternalPatchErrorInvalidProject, @"Project has no patch entries.");
        return nil;
    }
    if (!ExternalEnsureSandboxAccess()) {
        Fail(error, ExternalPatchErrorTargetAppUnavailable,
             @"3105 filesystem access is unavailable on this device or iOS version. No files were changed.");
        return nil;
    }
    NSMutableDictionary *roots = [NSMutableDictionary dictionary];
    for (NSString *bundle in ProjectBundles(project)) {
        NSString *root = ResolveContainer(bundle);
        if (!root) {
            Fail(error, ExternalPatchErrorTargetAppUnavailable, [NSString stringWithFormat:@"Target app unavailable: %@", bundle]);
            return nil;
        }
        roots[bundle] = root;
    }
    NSMutableSet *requestedDirs = [NSMutableSet set];
    for (NSDictionary *directory in project[@"directories"] ?: @[]) [requestedDirs addObject:TargetKey(directory[@"bundleID"], directory[@"relativePath"])];
    for (NSDictionary *rule in project[@"rules"] ?: @[]) {
        NSArray *parts = [rule[@"relativePath"] componentsSeparatedByString:@"/"];
        for (NSUInteger i = 1; i < parts.count; i++) [requestedDirs addObject:TargetKey(rule[@"bundleID"], [[parts subarrayWithRange:NSMakeRange(0, i)] componentsJoinedByString:@"/"])];
    }
    NSArray *sortedDirs = [[requestedDirs allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger da = [a componentsSeparatedByString:@"/"].count, db = [b componentsSeparatedByString:@"/"].count;
        return da == db ? [a compare:b] : (da < db ? NSOrderedAscending : NSOrderedDescending);
    }];
    NSMutableArray *resolvedDirs = [NSMutableArray array];
    for (NSString *key in sortedDirs) {
        NSArray *parts = [key componentsSeparatedByString:@"\0"];
        if (parts.count != 2) {
            Fail(error, ExternalPatchErrorInvalidProject, @"Invalid directory target.");
            return nil;
        }
        NSString *root = roots[parts[0]], *target = ContainedPath(root, parts[1], error);
        if (!target || !ValidateDirectoryTarget(target, root, error)) return nil;
        [resolvedDirs addObject:@{@"bundleID": parts[0], @"relativePath": parts[1], @"root": root, @"target": target}];
    }
    NSMutableArray *resolvedRules = [NSMutableArray array];
    NSMutableSet *targetPaths = [NSMutableSet set];
    for (NSDictionary *rule in project[@"rules"] ?: @[]) {
        NSString *root = roots[rule[@"bundleID"]], *target = ContainedPath(root, rule[@"relativePath"], error);
        if (!target || [targetPaths containsObject:target] ||
            !ValidateFileTarget(target, rule[@"relativePath"], root, YES, error)) return nil;
        [targetPaths addObject:target];
        [resolvedRules addObject:@{@"rule": rule, @"root": root, @"target": target}];
    }
    NSError *rootError = nil;
    NSURL *backupRoot = [self backupRootURL:&rootError];
    if (!backupRoot) { if (error) *error = rootError; return nil; }
    NSString *transactionID = UUIDString();
    NSURL *directory = [[backupRoot URLByAppendingPathComponent:project[@"id"] isDirectory:YES] URLByAppendingPathComponent:transactionID isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSMutableArray *records = [NSMutableArray array];
    NSMutableArray *createdDirs = [NSMutableArray array];
    for (NSDictionary *resolved in resolvedDirs) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:resolved[@"target"]]) {
            [createdDirs addObject:@{@"bundleID": resolved[@"bundleID"], @"relativePath": resolved[@"relativePath"], @"containerFingerprint": SHA256Data([resolved[@"root"] dataUsingEncoding:NSUTF8StringEncoding])}];
        }
    }
    for (NSDictionary *resolved in resolvedRules) {
        NSDictionary *rule = resolved[@"rule"];
        BOOL existed = [[NSFileManager defaultManager] fileExistsAtPath:resolved[@"target"]];
        NSString *backupFilename = existed ? [rule[@"id"] stringByAppendingString:@".original"] : nil;
        NSData *originalDigest = nil;
        if (existed) {
            if (![[NSFileManager defaultManager] copyItemAtPath:resolved[@"target"] toPath:[directory.path stringByAppendingPathComponent:backupFilename] error:error]) {
                return nil;
            }
            originalDigest = FileDigest([directory.path stringByAppendingPathComponent:backupFilename]);
        }
        NSMutableDictionary *record = [@{@"ruleID": rule[@"id"], @"bundleID": rule[@"bundleID"], @"relativePath": rule[@"relativePath"],
                                          @"containerFingerprint": SHA256Data([resolved[@"root"] dataUsingEncoding:NSUTF8StringEncoding]),
                                          @"originalExisted": @(existed),
                                          @"replacementDigest": SHA256Data(rule[@"replacementData"])} mutableCopy];
        if (backupFilename) record[@"backupFilename"] = backupFilename;
        if (originalDigest) record[@"originalDigest"] = originalDigest;
        [records addObject:record];
    }
    NSMutableDictionary *journal = [@{@"schemaVersion": @1, @"transactionID": transactionID, @"projectID": project[@"id"],
                                      @"createdAt": [NSDate date], @"status": @"prepared", @"records": records,
                                      @"createdDirectories": createdDirs} mutableCopy];
    NSURL *journalURL = [directory URLByAppendingPathComponent:kJournalFilename];
    if (!WriteJournal(journal, journalURL, error)) return nil;
    @try {
        for (NSDictionary *resolved in resolvedDirs) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:resolved[@"target"]] &&
                ![[NSFileManager defaultManager] createDirectoryAtPath:resolved[@"target"] withIntermediateDirectories:NO attributes:nil error:error]) @throw [NSException exceptionWithName:@"Patch" reason:@"directory" userInfo:nil];
        }
        for (NSUInteger i = 0; i < resolvedRules.count; i++) {
            NSDictionary *resolved = resolvedRules[i];
            if (!AtomicWrite(resolved[@"rule"][@"replacementData"], resolved[@"target"], error) ||
                ![FileDigest(resolved[@"target"]) isEqual:records[i][@"replacementDigest"]]) @throw [NSException exceptionWithName:@"Patch" reason:@"write" userInfo:nil];
        }
        journal[@"status"] = @"applied";
        if (!WriteJournal(journal, journalURL, error)) @throw [NSException exceptionWithName:@"Patch" reason:@"journal" userInfo:nil];
    } @catch (__unused NSException *exception) {
        RestoreRecords(records, directory, roots, NO, createdDirs, nil);
        journal[@"status"] = @"rolledBack";
        WriteJournal(journal, journalURL, nil);
        if (error && !*error) *error = PatchError(ExternalPatchErrorApplyFailed, @"Patch application failed.");
        return nil;
    }
    return [[ExternalPatchTransactionReceipt alloc] initWithTransactionID:transactionID projectID:project[@"id"] journalURL:journalURL];
}

+ (BOOL)restoreReceipt:(ExternalPatchTransactionReceipt *)receipt error:(NSError **)error {
    NSDictionary *journal = ReadJournal(receipt.journalURL);
    if (![journal[@"transactionID"] isEqual:receipt.transactionID] || ![journal[@"projectID"] isEqual:receipt.projectID] ||
        (![journal[@"status"] isEqual:@"applied"] && ![journal[@"status"] isEqual:@"prepared"])) {
        return Fail(error, ExternalPatchErrorRestoreFailed, @"Invalid patch transaction.");
    }
    NSMutableDictionary *roots = [NSMutableDictionary dictionary];
    NSMutableArray *bundleEntries = [NSMutableArray arrayWithArray:journal[@"records"] ?: @[]];
    [bundleEntries addObjectsFromArray:journal[@"createdDirectories"] ?: @[]];
    for (NSDictionary *record in bundleEntries) {
        NSString *bundle = record[@"bundleID"];
        if (!roots[bundle]) {
            NSString *root = ResolveContainer(bundle);
            if (!root || ![SHA256Data([root dataUsingEncoding:NSUTF8StringEncoding]) isEqual:record[@"containerFingerprint"]]) return Fail(error, ExternalPatchErrorRestoreFailed, @"Target app changed or is unavailable.");
            roots[bundle] = root;
        }
    }
    if (!RestoreRecords(journal[@"records"] ?: @[], receipt.journalURL.URLByDeletingLastPathComponent, roots,
                        [journal[@"status"] isEqual:@"applied"], journal[@"createdDirectories"] ?: @[], error)) {
        return NO;
    }
    NSMutableDictionary *restoredJournal = [journal mutableCopy];
    restoredJournal[@"status"] = @"restored";
    if (!WriteJournal(restoredJournal, receipt.journalURL, error)) return NO;
    return YES;
}

+ (ExternalPatchTransactionReceipt *)latestReceiptForProjectID:(NSString *)projectID {
    NSURL *root = [self backupRootURL:nil];
    NSURL *projectRoot = [root URLByAppendingPathComponent:projectID isDirectory:YES];
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:projectRoot includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSDictionary *best = nil;
    NSURL *bestURL = nil;
    for (NSURL *dir in dirs) {
        NSURL *url = [dir URLByAppendingPathComponent:kJournalFilename];
        NSDictionary *journal = ReadJournal(url);
        if (([journal[@"status"] isEqual:@"applied"] || [journal[@"status"] isEqual:@"prepared"]) &&
            (!best || [journal[@"createdAt"] compare:best[@"createdAt"]] == NSOrderedDescending)) {
            best = journal; bestURL = url;
        }
    }
    return best ? [[ExternalPatchTransactionReceipt alloc] initWithTransactionID:best[@"transactionID"] projectID:best[@"projectID"] journalURL:bestURL] : nil;
}

@end