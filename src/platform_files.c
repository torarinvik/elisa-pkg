#define _DARWIN_C_SOURCE
#define _XOPEN_SOURCE 700

#include <errno.h>
#include <ftw.h>
#include <fcntl.h>
#include <unistd.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

/*
 * This is deliberately only a filesystem seam. Serialization and manifest selection stay in Elisa;
 * this binding supplies traversal, sorting and conservative file exclusions. The walker never
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

static _Thread_local struct walk_state *active_state;
static unsigned long temp_counter;

static int open_directory_path(const char *path);

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
    if (strlen(relative) > 4096) { active_state->error = ENAMETOOLONG; return 1; }
    if (relative[0] == '\0' || forbidden_leaf(relative)) {
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
    if (info->level > 64) { active_state->error = EOVERFLOW; return 1; }
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
    if (root == NULL || strcmp(root, ".") != 0 || output == NULL || capacity == 0) {
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

/* Open every component relative to an already opened directory. A rename or
 * symlink swap cannot redirect the read outside this directory chain. */
static int open_package_file(const char *path) {
    if (path == NULL || strlen(path) > 4096) return -EINVAL;
    char *copy = strdup(path);
    if (copy == NULL) return -ENOMEM;
    const int absolute = path[0] == '/';
    int directory = open(absolute ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) { free(copy); return -EIO; }
    char *part = copy;
    while (absolute && *part == '/') part++;
    int file = -1;
    while (1) {
        char *slash = strchr(part, '/');
        if (slash != NULL) *slash = '\0';
        if (*part == '\0') {
            close(directory);
            free(copy);
            return -EINVAL;
        }
        if (strcmp(part, "..") == 0) {
            close(directory);
            free(copy);
            return -EINVAL;
        }
        if (strcmp(part, ".") == 0) {
            if (slash == NULL) {
                close(directory);
                free(copy);
                return -EINVAL;
            }
            part = slash + 1;
            continue;
        }
        int next = openat(directory, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (slash != NULL ? O_DIRECTORY : 0));
        if (next < 0) {
            const int error = errno;
            close(directory);
            free(copy);
            return error == 0 ? -EIO : -error;
        }
        if (slash == NULL) { file = next; break; }
        close(directory);
        directory = next;
        part = slash + 1;
    }
    close(directory);
    free(copy);
    return file;
}

/* Read-mode and exclusive-create streams are routed through the same
 * descriptor-relative no-follow walk as the byte-buffer helpers. Other modes
 * are rejected because this seam does not need an unbounded libc path API. */
FILE *elisapkg_fopen(const char *path, const char *mode) {
    if (path == NULL || mode == NULL) return NULL;
    if (strcmp(mode, "wxb") == 0) {
        char *copy = strdup(path);
        if (copy == NULL) return NULL;
        char *slash = strrchr(copy, '/');
        char *leaf = copy;
        char *parent = ".";
        if (slash != NULL) {
            leaf = slash + 1;
            if (*leaf == '\0') { free(copy); return NULL; }
            if (slash == copy) {
                slash[1] = '\0';
                parent = copy;
            } else {
                *slash = '\0';
                parent = copy;
            }
        }
        if (strcmp(leaf, ".") == 0 || strcmp(leaf, "..") == 0 || strchr(leaf, '/') != NULL) {
            free(copy);
            return NULL;
        }
        int directory = open_directory_path(parent);
        if (directory < 0) { free(copy); return NULL; }
        int file = openat(directory, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        close(directory);
        free(copy);
        if (file < 0) return NULL;
        FILE *stream = fdopen(file, "wb");
        if (stream == NULL) close(file);
        return stream;
    }
    if (strcmp(mode, "rb") != 0) return NULL;
    int file = open_package_file(path);
    if (file < 0) return NULL;
    FILE *stream = fdopen(file, "rb");
    if (stream == NULL) close(file);
    return stream;
}

long long elisapkg_package_file_size(const char *path) {
    int file = open_package_file(path);
    if (file < 0) return file;
    struct stat info;
    if (fstat(file, &info) != 0) {
        close(file);
        return -EIO;
    }
    close(file);
    if (!S_ISREG(info.st_mode) || info.st_size < 0) return -EIO;
    return (long long)info.st_size;
}

static int open_directory_path(const char *path) {
    if (path == NULL || path[0] == '\0' || strlen(path) > 4096) return -EINVAL;
    char *copy = strdup(path);
    if (copy == NULL) return -ENOMEM;
    const int absolute = path[0] == '/';
    int directory = open(absolute ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) { free(copy); return -errno; }
    char *part = copy;
    while (absolute && *part == '/') part++;
    while (*part != '\0') {
        char *slash = strchr(part, '/');
        if (slash != NULL) *slash = '\0';
        if (strcmp(part, "..") == 0) {
            close(directory);
            free(copy);
            return -EINVAL;
        }
        if (*part != '\0' && strcmp(part, ".") != 0) {
            int next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (next < 0) {
                const int error = errno;
                close(directory);
                free(copy);
                return error == 0 ? -EIO : -error;
            }
            close(directory);
            directory = next;
        }
        if (slash == NULL) break;
        part = slash + 1;
        while (*part == '/') part++;
    }
    free(copy);
    return directory;
}

long long elisapkg_mkdir(const char *path, unsigned short mode) {
    if (path == NULL || path[0] == '\0' || strlen(path) > 4096) return -EINVAL;
    char *copy = strdup(path);
    if (copy == NULL) return -ENOMEM;
    char *slash = strrchr(copy, '/');
    char *leaf = copy;
    char *parent = ".";
    if (slash != NULL) {
        leaf = slash + 1;
        if (*leaf == '\0') {
            free(copy);
            return -EINVAL;
        }
        if (slash == copy) {
            slash[1] = '\0';
            parent = copy;
        } else {
            *slash = '\0';
            parent = copy;
        }
    }
    int directory = open_directory_path(parent);
    if (directory < 0) {
        free(copy);
        return directory;
    }
    if (strcmp(leaf, ".") == 0 || strcmp(leaf, "..") == 0 || strchr(leaf, '/') != NULL) {
        close(directory);
        free(copy);
        return -EINVAL;
    }
    const int result = mkdirat(directory, leaf, (mode_t)mode) == 0 ? 0 : -errno;
    close(directory);
    free(copy);
    return result;
}

long long elisapkg_is_directory(const char *path) {
    int directory = open_directory_path(path);
    if (directory < 0) return 0;
    struct stat info;
    const int result = fstat(directory, &info) == 0 && S_ISDIR(info.st_mode) ? 1 : 0;
    close(directory);
    return result;
}

long long elisapkg_read_package_file(const char *path, unsigned char *output, size_t capacity) {
    if (output == NULL || capacity == 0) return -EINVAL;
    int file = open_package_file(path);
    if (file < 0) return file;
    struct stat info;
    if (fstat(file, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 || (unsigned long long)info.st_size >= capacity) {
        close(file); return -EFBIG;
    }
    size_t used = 0;
    while (used < capacity) {
        ssize_t amount = read(file, output + used, capacity - used);
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0) { close(file); return -EIO; }
        if (amount == 0) break;
        used += (size_t)amount;
    }
    close(file);
    return used == capacity ? -EFBIG : (long long)used;
}

static int split_parent_leaf(const char *path, char **copy_out, char **parent_out, char **leaf_out) {
    if (path == NULL || path[0] == '\0' || strlen(path) > 4096) return -EINVAL;
    char *copy = strdup(path);
    if (copy == NULL) return -ENOMEM;
    char *slash = strrchr(copy, '/');
    char *leaf = copy;
    char *parent = ".";
    if (slash != NULL) {
        leaf = slash + 1;
        if (*leaf == '\0') { free(copy); return -EINVAL; }
        if (slash == copy) {
            slash[1] = '\0';
            parent = copy;
        } else {
            *slash = '\0';
            parent = copy;
        }
    }
    if (*leaf == '\0' || strcmp(leaf, ".") == 0 || strcmp(leaf, "..") == 0 || strchr(leaf, '/') != NULL) {
        free(copy);
        return -EINVAL;
    }
    *copy_out = copy;
    *parent_out = parent;
    *leaf_out = leaf;
    return 0;
}

long long elisapkg_mkstemp(char *template_path) {
    char *copy = NULL;
    char *parent = NULL;
    char *leaf = NULL;
    const int split = split_parent_leaf(template_path, &copy, &parent, &leaf);
    if (split != 0) return split;
    const size_t leaf_length = strlen(leaf);
    if (leaf_length < 6 || memcmp(leaf + leaf_length - 6, "XXXXXX", 6) != 0) {
        free(copy);
        return -EINVAL;
    }
    int directory = open_directory_path(parent);
    if (directory < 0) { free(copy); return directory; }
    static const char alphabet[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const size_t template_offset = (size_t)(leaf - copy);
    for (unsigned int attempt = 0; attempt < 256; attempt++) {
        uint64_t value = ((uint64_t)getpid() << 32) ^ (uint64_t)(uintptr_t)template_path ^
                         (uint64_t)__sync_fetch_and_add(&temp_counter, 1) ^ (uint64_t)attempt * 0x9e3779b97f4a7c15ULL;
        for (size_t index = 0; index < 6; index++) {
            leaf[leaf_length - 6 + index] = alphabet[value % (sizeof(alphabet) - 1)];
            value = value / (sizeof(alphabet) - 1) + 0x9e3779b97f4a7c15ULL;
        }
        int file = openat(directory, leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (file >= 0) {
            memcpy(template_path + template_offset, leaf, leaf_length + 1);
            close(directory);
            free(copy);
            return file;
        }
        if (errno != EEXIST) {
            const int error = errno;
            close(directory);
            free(copy);
            return error == 0 ? -EIO : -error;
        }
    }
    close(directory);
    free(copy);
    return -EEXIST;
}

long long elisapkg_access(const char *path, int mode) {
    if (mode != 0 && mode != 1) return -EINVAL;
    int file = open_package_file(path);
    if (file < 0) return file;
    struct stat info;
    const int status = fstat(file, &info);
    close(file);
    if (status != 0) return -errno;
    if (mode == 1 && (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0) return -EACCES;
    return 0;
}

long long elisapkg_chdir(const char *path) {
    int directory = open_directory_path(path);
    if (directory < 0) return directory;
    const int result = fchdir(directory) == 0 ? 0 : -errno;
    close(directory);
    return result;
}

long long elisapkg_unlink(const char *path) {
    char *copy = NULL;
    char *parent = NULL;
    char *leaf = NULL;
    const int split = split_parent_leaf(path, &copy, &parent, &leaf);
    if (split != 0) return split;
    int directory = open_directory_path(parent);
    if (directory < 0) { free(copy); return directory; }
    const int result = unlinkat(directory, leaf, 0) == 0 ? 0 : -errno;
    close(directory);
    free(copy);
    return result;
}

long long elisapkg_rmdir(const char *path) {
    char *copy = NULL;
    char *parent = NULL;
    char *leaf = NULL;
    const int split = split_parent_leaf(path, &copy, &parent, &leaf);
    if (split != 0) return split;
    int directory = open_directory_path(parent);
    if (directory < 0) { free(copy); return directory; }
    const int result = unlinkat(directory, leaf, AT_REMOVEDIR) == 0 ? 0 : -errno;
    close(directory);
    free(copy);
    return result;
}

long long elisapkg_chmod(const char *path, unsigned short mode) {
    char *copy = NULL;
    char *parent = NULL;
    char *leaf = NULL;
    const int split = split_parent_leaf(path, &copy, &parent, &leaf);
    if (split != 0) return split;
    int directory = open_directory_path(parent);
    if (directory < 0) { free(copy); return directory; }
    int file = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    const int opened_errno = errno;
    if (file < 0) {
        close(directory);
        free(copy);
        return opened_errno == 0 ? -EIO : -opened_errno;
    }
    const int result = fchmod(file, (mode_t)mode) == 0 ? 0 : -errno;
    close(file);
    close(directory);
    free(copy);
    return result;
}

long long elisapkg_link(const char *old_path, const char *new_path) {
    char *old_copy = NULL;
    char *old_parent = NULL;
    char *old_leaf = NULL;
    char *new_copy = NULL;
    char *new_parent = NULL;
    char *new_leaf = NULL;
    int split = split_parent_leaf(old_path, &old_copy, &old_parent, &old_leaf);
    if (split != 0) return split;
    split = split_parent_leaf(new_path, &new_copy, &new_parent, &new_leaf);
    if (split != 0) { free(old_copy); return split; }
    int old_directory = open_directory_path(old_parent);
    int new_directory = open_directory_path(new_parent);
    if (old_directory < 0 || new_directory < 0) {
        if (old_directory >= 0) close(old_directory);
        if (new_directory >= 0) close(new_directory);
        free(old_copy); free(new_copy);
        return old_directory < 0 ? old_directory : new_directory;
    }
    struct stat source_info;
    struct stat destination_info;
    const int source_status = fstatat(old_directory, old_leaf, &source_info, AT_SYMLINK_NOFOLLOW);
    const int source_errno = errno;
    const int destination_status = fstatat(new_directory, new_leaf, &destination_info, AT_SYMLINK_NOFOLLOW);
    const int destination_errno = errno;
    int result = 0;
    if (source_status != 0 || !S_ISREG(source_info.st_mode) || (destination_status == 0)) {
        result = source_status != 0 ? -source_errno : (destination_status == 0 ? -EEXIST : -destination_errno);
    } else if (linkat(old_directory, old_leaf, new_directory, new_leaf, 0) != 0) {
        result = -errno;
    }
    close(old_directory); close(new_directory);
    free(old_copy); free(new_copy);
    return result;
}

long long elisapkg_rename(const char *old_path, const char *new_path) {
    char *old_copy = NULL;
    char *old_parent = NULL;
    char *old_leaf = NULL;
    char *new_copy = NULL;
    char *new_parent = NULL;
    char *new_leaf = NULL;
    int split = split_parent_leaf(old_path, &old_copy, &old_parent, &old_leaf);
    if (split != 0) return split;
    split = split_parent_leaf(new_path, &new_copy, &new_parent, &new_leaf);
    if (split != 0) { free(old_copy); return split; }
    int old_directory = open_directory_path(old_parent);
    int new_directory = open_directory_path(new_parent);
    if (old_directory < 0 || new_directory < 0) {
        if (old_directory >= 0) close(old_directory);
        if (new_directory >= 0) close(new_directory);
        free(old_copy); free(new_copy);
        return old_directory < 0 ? old_directory : new_directory;
    }
    struct stat source_info;
    struct stat destination_info;
    const int source_status = fstatat(old_directory, old_leaf, &source_info, AT_SYMLINK_NOFOLLOW);
    const int source_errno = errno;
    const int destination_status = fstatat(new_directory, new_leaf, &destination_info, AT_SYMLINK_NOFOLLOW);
    int result = 0;
    if (source_status != 0 || !S_ISREG(source_info.st_mode)) {
        result = source_status != 0 ? -source_errno : -EINVAL;
    } else if (destination_status == 0 && S_ISLNK(destination_info.st_mode)) {
        result = -ELOOP;
    } else if (destination_status == 0 && !S_ISREG(destination_info.st_mode)) {
        result = -EISDIR;
    } else if (renameat(old_directory, old_leaf, new_directory, new_leaf) != 0) {
        result = -errno;
    }
    close(old_directory); close(new_directory);
    free(old_copy); free(new_copy);
    return result;
}
