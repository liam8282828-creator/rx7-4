#import "mcm_bridge.h"
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <unistd.h>
// Theos' public iPhoneOS SDK does not ship the private xpc/xpc.h header.
// Keep the object opaque and resolve the required XPC function at runtime.
typedef void *xpc_object_t;
typedef xpc_object_t (*MCMXPCStringCreate)(const char *);
typedef void (*MCMXPCRelease)(xpc_object_t);

typedef void *(*MCMQueryCreate)(void);
typedef void (*MCMQuerySetU64)(void *, uint64_t);
typedef void (*MCMQuerySetXPC)(void *, xpc_object_t);
typedef void *(*MCMQueryGetPointer)(void *);
typedef bool (*MCMQueryIterate)(void *, bool (^)(void *));
typedef char *(*MCMCopyToken)(void *);
typedef const char *(*MCMGetPath)(void *);
typedef const char *(*MCMGetIdentifier)(void *);
typedef void *(*MCMObjectCopy)(void *);
typedef bool (*MCMObjectActivate)(void *, bool);
typedef void (*MCMObjectFree)(void *);
typedef int (*MCMErrorGetInt)(void *);
typedef const char *(*MCMErrorGetString)(void *);
typedef void (*MCMQueryFree)(void *);

typedef struct {
    void *handle;
    MCMQueryCreate queryCreate;
    MCMQuerySetU64 querySetClass;
    MCMQuerySetXPC querySetIdentifiers;
    MCMQuerySetXPC querySetGroupIdentifiers;
    MCMQuerySetU64 querySetFlags;
    MCMQuerySetU64 querySetPart;
    MCMQueryGetPointer queryGetSingle;
    MCMQueryGetPointer queryGetLastError;
    MCMQueryIterate queryIterate;
    MCMQueryFree queryFree;
    MCMGetPath objectGetPath;
    MCMGetIdentifier objectGetIdentifier;
    MCMObjectCopy objectCopy;
    MCMCopyToken objectCopyToken;
    MCMObjectActivate objectActivate;
    MCMObjectFree objectFree;
    MCMErrorGetInt errorGetPOSIX;
    MCMErrorGetString errorGetMessage;
} MCMAPI;

static MCMAPI *MCMSharedAPI(void) {
    static MCMAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL
        );
        void *handle = api.handle ?: RTLD_DEFAULT;
#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(handle, symbol)
        LOAD(queryCreate, "container_query_create");
        LOAD(querySetClass, "container_query_set_class");
        LOAD(querySetIdentifiers, "container_query_set_identifiers");
        LOAD(querySetGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(querySetFlags, "container_query_operation_set_flags");
        LOAD(querySetPart, "container_query_operation_set_part");
        LOAD(queryGetSingle, "container_query_get_single_result");
        LOAD(queryGetLastError, "container_query_get_last_error");
        LOAD(queryIterate, "container_query_iterate_results_sync");
        LOAD(queryFree, "container_query_free");
        LOAD(objectGetPath, "container_object_get_path");
        LOAD(objectGetIdentifier, "container_object_get_identifier");
        LOAD(objectCopy, "container_object_copy");
        LOAD(objectCopyToken, "container_copy_sandbox_token");
        LOAD(objectActivate, "container_object_sandbox_extension_activate");
        LOAD(objectFree, "container_object_free");
        LOAD(errorGetPOSIX, "container_error_get_posix_errno");
        LOAD(errorGetMessage, "container_error_get_message");
#undef LOAD
    });
    return &api;
}

static xpc_object_t MCMCreateXPCString(const char *value) {
    static MCMXPCStringCreate createString;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *xpcHandle = dlopen(
            "/usr/lib/system/libxpc.dylib",
            RTLD_NOW | RTLD_LOCAL
        );
        createString = (MCMXPCStringCreate)dlsym(
            xpcHandle ?: RTLD_DEFAULT,
            "xpc_string_create"
        );
    });
    return createString ? createString(value) : NULL;
}

static void MCMReleaseXPCObject(xpc_object_t object) {
    if (!object) return;
    static MCMXPCRelease releaseObject;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *xpcHandle = dlopen(
            "/usr/lib/system/libxpc.dylib",
            RTLD_NOW | RTLD_LOCAL
        );
        releaseObject = (MCMXPCRelease)dlsym(
            xpcHandle ?: RTLD_DEFAULT,
            "xpc_release"
        );
    });
    if (releaseObject) releaseObject(object);
}

BOOL MCMBridgeAvailable(void) {
    MCMAPI *api = MCMSharedAPI();
    return api->queryCreate && api->querySetClass &&
        api->querySetIdentifiers && api->querySetGroupIdentifiers &&
        api->querySetFlags && api->queryGetSingle && api->queryFree &&
        api->objectGetPath && api->objectCopy && api->objectCopyToken &&
        api->objectActivate && api->objectFree;
}

NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t cls,
    NSUInteger limit,
    NSString **error
) {
    MCMAPI *api = MCMSharedAPI();
    if (!api->queryCreate || !api->querySetClass || !api->querySetFlags ||
        !api->queryIterate || !api->objectGetIdentifier || !api->queryFree ||
        limit == 0) {
        if (error) *error = @"Container Manager is unavailable.";
        return @[];
    }

    void *query = api->queryCreate();
    if (!query) {
        if (error) *error = @"Could not create the container query.";
        return @[];
    }

    api->querySetClass(query, cls);
    api->querySetFlags(query, 0x100000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);

    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    BOOL iterated = api->queryIterate(query, ^bool(void *object) {
        const char *raw = object ? api->objectGetIdentifier(object) : NULL;
        NSString *identifier = raw ? [NSString stringWithUTF8String:raw] : nil;
        if (identifier.length) [identifiers addObject:identifier];
        return identifiers.count < limit;
    });

    if (!iterated && identifiers.count < limit && error) {
        void *queryError = api->queryGetLastError
            ? api->queryGetLastError(query)
            : NULL;
        int posix = queryError && api->errorGetPOSIX
            ? api->errorGetPOSIX(queryError)
            : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError)
            : NULL;
        *error = [NSString stringWithFormat:
            @"Enumeration denied (errno=%d, %s).",
            posix, message ?: "no details"];
    }

    api->queryFree(query);
    return identifiers.array;
}

static BOOL MCMSafeIdentifier(NSString *identifier) {
    if (identifier.length == 0 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier isEqualToString:@"."] &&
        ![identifier isEqualToString:@".."];
}

@interface MCMRetainedLease : NSObject {
    void *_query;
    void *_activation;
}
@property(nonatomic, copy) NSString *rootPath;
@property(nonatomic) BOOL activated;
+ (nullable instancetype)leaseForClass:(uint64_t)cls
                             identifier:(NSString *)identifier
                                  group:(BOOL)group
                                  error:(NSString **)error;
- (BOOL)activate:(NSString **)error;
@end

@implementation MCMRetainedLease

+ (instancetype)leaseForClass:(uint64_t)cls
                    identifier:(NSString *)identifier
                         group:(BOOL)group
                         error:(NSString **)error {
    MCMAPI *api = MCMSharedAPI();
    if (!MCMBridgeAvailable() || !MCMSafeIdentifier(identifier)) {
        if (error) *error = @"MCM is unavailable or the identifier is invalid.";
        return nil;
    }

    void *query = api->queryCreate();
    if (!query) {
        if (error) *error = @"Could not create the query.";
        return nil;
    }

    api->querySetClass(query, cls);
    xpc_object_t value = MCMCreateXPCString(identifier.UTF8String);
    if (!value) {
        if (error) *error = @"Could not create the XPC identifier.";
        api->queryFree(query);
        return nil;
    }
    if (group) api->querySetGroupIdentifiers(query, value);
    else api->querySetIdentifiers(query, value);
    MCMReleaseXPCObject(value);
    api->querySetFlags(query, 0x900000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);

    void *result = api->queryGetSingle(query);
    if (!result) {
        void *queryError = api->queryGetLastError
            ? api->queryGetLastError(query)
            : NULL;
        int posix = queryError && api->errorGetPOSIX
            ? api->errorGetPOSIX(queryError)
            : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError)
            : NULL;
        if (error) *error = [NSString stringWithFormat:
            @"Query denied (errno=%d, %s).",
            posix, message ?: "sin detalle"];
        api->queryFree(query);
        return nil;
    }

    const char *rawPath = api->objectGetPath(result);
    NSString *rootPath = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    if (rootPath.length == 0 || !rootPath.isAbsolutePath) {
        if (error) *error = @"Container Manager did not return an absolute path.";
        api->queryFree(query);
        return nil;
    }
    if ([rootPath isEqualToString:@"/var"] || [rootPath hasPrefix:@"/var/"]) {
        rootPath = [@"/private" stringByAppendingString:rootPath];
    }

    MCMRetainedLease *lease = [MCMRetainedLease new];
    lease->_query = query;
    lease.rootPath = rootPath;
    return lease;
}

- (BOOL)activate:(NSString **)error {
    if (self.activated) return YES;
    if (!_query) {
        if (error) *error = @"The access grant is no longer valid.";
        return NO;
    }

    MCMAPI *api = MCMSharedAPI();
    void *result = api->queryGetSingle(_query);
    _activation = result ? api->objectCopy(result) : NULL;
    char *token = _activation ? api->objectCopyToken(_activation) : NULL;
    BOOL tokenPresent = token && token[0] != '\0';
    free(token);
    self.activated = tokenPresent && api->objectActivate(_activation, false);
    if (!self.activated && error) {
        *error = tokenPresent
            ? @"Sandbox access activation failed."
            : @"The container did not provide a sandbox token.";
    }
    return self.activated;
}

- (void)dealloc {
    MCMAPI *api = MCMSharedAPI();
    if (_activation) api->objectFree(_activation);
    if (_query) api->queryFree(_query);
}

@end

static NSMutableDictionary<NSString *, MCMRetainedLease *> *MCMActiveLeases(void) {
    static NSMutableDictionary<NSString *, MCMRetainedLease *> *leases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        leases = [NSMutableDictionary dictionary];
    });
    return leases;
}

NSString *MCMActivateContainerPath(
    uint64_t cls,
    NSString *identifier,
    BOOL group,
    NSString **error
) {
    if (!MCMSafeIdentifier(identifier)) {
        if (error) *error = @"The identifier contains invalid characters.";
        return nil;
    }

    NSMutableDictionary *leases = MCMActiveLeases();
    NSString *key = [NSString stringWithFormat:@"%llu:%d:%@",
                     cls, group, identifier];
    @synchronized (leases) {
        MCMRetainedLease *existing = leases[key];
        if (existing.rootPath.length) return existing.rootPath;

        NSString *detail = nil;
        MCMRetainedLease *lease = [MCMRetainedLease
            leaseForClass:cls
            identifier:identifier
            group:group
            error:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"The MCM query failed.";
            return nil;
        }
        [lease activate:&detail];

        int descriptor = open(
            lease.rootPath.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        );
        if (descriptor < 0) {
            if (error) {
                *error = detail ?: [NSString stringWithFormat:
                    @"Could not open the container (errno=%d).", errno];
            }
            return nil;
        }
        close(descriptor);
        leases[key] = lease;
        return lease.rootPath;
    }
}