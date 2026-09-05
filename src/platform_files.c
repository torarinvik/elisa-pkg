#define _XOPEN_SOURCE 700

#include <errno.h>
#include <ftw.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/*
 * This is deliberately only a filesystem enumeration seam. Selection,
 * archive policy, ordering, and serialization stay in Elisa. The walker never
 * follows links and refuses special files so an archive cannot turn a source
 * tree into an implicit device or link traversal primitive.
 */

struct file_entry {
    char *path;
};

struct walk_state {
    struct file_entry *entries;
    size_t count;
    size_t capacity;
    int error;
};

static struct walk_state *active_state;

static const char *relative_path(const char *path) {
    if (path[0] == '.' && path[1] == '/') {
        return path + 2;
    }
    return path;
}

static int path_component(const char *path, const char *component) {
    const size_t length = strlen(component);
    const char *cursor = path;
    while (*cursor != '\0') {
        while (*cursor == '/') {
            cursor++;
        }
        const char *end = cursor;
        while (*end != '\0' && *end != '/') {
            end++;
        }
        if ((size_t)(end - cursor) == length && memcmp(cursor, component, length) == 0) {
            return 1;
        }
        cursor = end;
    }
    return 0;
}

static int forbidden_leaf(const char *path) {
    const char *leaf = strrchr(path, '/');
    leaf = leaf == NULL ? path : leaf + 1;
    if (strcmp(leaf, "IMPLEMENTATION_PLAN.md") == 0 || strcmp(leaf, ".netrc") == 0 ||
        strcmp(leaf, "credentials") == 0 || strcmp(leaf, "credentials.json") == 0 ||
        strcmp(leaf, "id_rsa") == 0 || strcmp(leaf, "id_ed25519") == 0) {
        return 1;
    }
    const size_t length = strlen(leaf);
    if ((length >= 4 && strcmp(leaf + length - 4, ".pem") == 0) ||
        (length >= 4 && strcmp(leaf + length - 4, ".key") == 0) ||
        (length >= 4 && strncmp(leaf, ".env", 4) == 0)) {
        return 1;
    }
    return 0;
}

static int skip_directory(const char *path) {
    const char *relative = relative_path(path);
    return path_component(relative, ".git") || path_component(relative, ".hg") ||
           path_component(relative, ".svn") || path_component(relative, ".elisapkg") ||
           path_component(relative, "build") || path_component(relative, "target");
}

static int collect_entry(const char *path) {
    if (active_state == NULL || active_state->error != 0) {
        return 1;
    }
    const char *relative = relative_path(path);
    if (relative[0] == '\0' || strlen(relative) > 4096 || forbidden_leaf(relative)) {
        return 0;
    }
    if (active_state->count == active_state->capacity) {
        size_t next = active_state->capacity == 0 ? 64 : active_state->capacity * 2;
        if (next < active_state->capacity || next > 4096) {
            active_state->error = EOVERFLOW;
            return 1;
        }
        struct file_entry *grown = realloc(active_state->entries, next * sizeof(*grown));
        if (grown == NULL) {
            active_state->error = ENOMEM;
            return 1;
        }
        active_state->entries = grown;
        active_state->capacity = next;
    }
    active_state->entries[active_state->count].path = strdup(relative);
    if (active_state->entries[active_state->count].path == NULL) {
        active_state->error = ENOMEM;
        return 1;
    }
    active_state->count++;
    return 0;
}

static int walk_callback(const char *path, const struct stat *st, int type, struct FTW *info) {
    (void)st;
    (void)info;
    if (skip_directory(path)) {
        return 0;
    }
    if (type == FTW_D) {
        return 0;
    }
    if (type != FTW_F) {
        if (active_state != NULL) {
            active_state->error = ELOOP;
        }
        return 1;
    }
    return collect_entry(path);
}

static int compare_entries(const void *left, const void *right) {
    const struct file_entry *a = left;
    const struct file_entry *b = right;
    return strcmp(a->path, b->path);
}

long long elisapkg_collect_files(const char *root, unsigned char *output, size_t capacity) {
    if (root == NULL || output == NULL || capacity == 0) {
        return -EINVAL;
    }
    struct walk_state state = {0};
    active_state = &state;
    const int walk_status = nftw(root, walk_callback, 32, FTW_PHYS | FTW_MOUNT);
    active_state = NULL;
    if (walk_status != 0 && state.error == 0) {
        state.error = errno == 0 ? EIO : errno;
    }
    if (state.error != 0) {
        for (size_t index = 0; index < state.count; index++) {
            free(state.entries[index].path);
        }
        free(state.entries);
        return -(long long)state.error;
    }
    qsort(state.entries, state.count, sizeof(*state.entries), compare_entries);
    size_t used = 0;
    for (size_t index = 0; index < state.count; index++) {
        const size_t length = strlen(state.entries[index].path) + 1;
        if (length > capacity - used) {
            for (size_t cleanup = 0; cleanup < state.count; cleanup++) {
                free(state.entries[cleanup].path);
            }
            free(state.entries);
            return -E2BIG;
        }
        memcpy(output + used, state.entries[index].path, length);
        used += length;
    }
    for (size_t index = 0; index < state.count; index++) {
        free(state.entries[index].path);
    }
    free(state.entries);
    return (long long)used;
}
