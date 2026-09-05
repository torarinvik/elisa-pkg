#define _DARWIN_C_SOURCE
#define _XOPEN_SOURCE 700

#include <errno.h>
#include <dirent.h>
#include <ftw.h>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <sys/wait.h>

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

static int archive_parse_octal(const unsigned char *value, size_t offset, size_t width, size_t *out) {
    size_t parsed = 0;
    size_t digits = 0;
    if (value == NULL || out == NULL || width < 2) return 0;
    for (size_t index = 0; index < width; index++) {
        unsigned char byte = value[offset + index];
        if (byte >= '0' && byte <= '7') {
            size_t digit = (size_t)(byte - '0');
            if (parsed > (SIZE_MAX - digit) / 8) return 0;
            parsed = parsed * 8 + digit;
            digits++;
            continue;
        }
        if (byte != '\0' && byte != ' ') {
            return 0;
        }
        for (size_t rest = index + 1; rest < width; rest++) {
            if (value[offset + rest] != '\0' && value[offset + rest] != ' ') return 0;
        }
        *out = parsed;
        return digits > 0;
    }
    return 0;
}

static int archive_block_zero(const unsigned char *archive, size_t offset) {
    for (size_t index = 0; index < 512; index++) {
        if (archive[offset + index] != 0) return 0;
    }
    return 1;
}

static int archive_range_zero(const unsigned char *value, size_t offset, size_t length) {
    for (size_t index = 0; index < length; index++) {
        if (value[offset + index] != 0) return 0;
    }
    return 1;
}

static int archive_entry_safe(const unsigned char *name, size_t length) {
    if (name == NULL || length == 0 || length >= 100 || name[0] == '/' || name[0] == '\\' ||
        (length >= 2 && name[1] == ':') || name[length - 1] == '/' || name[length - 1] == '\\') {
        return 0;
    }
    size_t segment_start = 0;
    for (size_t index = 0; index <= length; index++) {
        if (index < length && name[index] != '/') {
            unsigned char byte = name[index];
            if (byte < 32 || byte == 127 || byte == '\\' || byte == ':') return 0;
            continue;
        }
        size_t segment_length = index - segment_start;
        if (segment_length == 0 || (segment_length == 1 && name[segment_start] == '.') ||
            (segment_length == 2 && name[segment_start] == '.' && name[segment_start + 1] == '.')) {
            return 0;
        }
        segment_start = index + 1;
        continue;
    }
    for (size_t index = 1; index < length; index++) {
        if (name[index] == '/' && name[index - 1] == '/') return 0;
    }
    return 1;
}

static int archive_name_seen(char **seen, size_t count, const char *wanted) {
    for (size_t item = 0; item < count; item++) {
        const char *left = seen[item];
        const char *right = wanted;
        size_t index = 0;
        while (left[index] != '\0' && right[index] != '\0') {
            unsigned char a = (unsigned char)left[index];
            unsigned char b = (unsigned char)right[index];
            if (a >= 'A' && a <= 'Z') a = (unsigned char)(a + ('a' - 'A'));
            if (b >= 'A' && b <= 'Z') b = (unsigned char)(b + ('a' - 'A'));
            if (a != b) break;
            index++;
        }
        if (left[index] == '\0' && right[index] == '\0') return 1;
        if (left[index] == '\0' && right[index] == '/') return 1;
        if (right[index] == '\0' && left[index] == '/') return 1;
    }
    return 0;
}

static int archive_directory_empty(int directory) {
    int duplicate = dup(directory);
    if (duplicate < 0) return 0;
    DIR *stream = fdopendir(duplicate);
    if (stream == NULL) {
        close(duplicate);
        return 0;
    }
    int empty = 1;
    struct dirent *entry = NULL;
    while ((entry = readdir(stream)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            empty = 0;
            break;
        }
    }
    closedir(stream);
    return empty;
}

/* Open the parent of an archive entry relative to the private extraction root,
 * creating only ordinary directories. Every component is reopened with
 * O_NOFOLLOW so a concurrent link swap cannot escape the staging tree. */
static int archive_open_parent(int root, const unsigned char *name, size_t length, char **copy_out, char **leaf_out) {
    char *copy = malloc(length + 1);
    if (copy == NULL) return -ENOMEM;
    memcpy(copy, name, length);
    copy[length] = '\0';
    int directory = dup(root);
    if (directory < 0) {
        free(copy);
        return -errno;
    }
    char *cursor = copy;
    char *slash = NULL;
    while ((slash = strchr(cursor, '/')) != NULL) {
        *slash = '\0';
        int next = openat(directory, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(directory, cursor, 0755) != 0 && errno != EEXIST) {
                int error = errno;
                close(directory);
                free(copy);
                return -error;
            }
            next = openat(directory, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            int error = errno;
            close(directory);
            free(copy);
            return error == 0 ? -EIO : -error;
        }
        close(directory);
        directory = next;
        cursor = slash + 1;
    }
    if (*cursor == '\0' || strcmp(cursor, ".") == 0 || strcmp(cursor, "..") == 0) {
        close(directory);
        free(copy);
        return -EINVAL;
    }
    *copy_out = copy;
    *leaf_out = cursor;
    return directory;
}

static void archive_cleanup_files(int root, char **seen, size_t count) {
    for (size_t index = 0; index < count; index++) {
        size_t length = strlen(seen[index]);
        char *copy = NULL;
        char *leaf = NULL;
        int parent = archive_open_parent(root, (const unsigned char *)seen[index], length, &copy, &leaf);
        if (parent >= 0) {
            (void)unlinkat(parent, leaf, 0);
            close(parent);
        }
        free(copy);
    }
}

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

/* Extract the package manager's intentionally narrow ustar subset into an
 * already-created private staging directory. The destination must be empty;
 * callers can remove that directory as a unit after failure. No archive entry
 * can replace an existing file or follow a link, and only regular 0644 files
 * with normalized metadata are accepted. */
long long elisapkg_extract_ustar(const unsigned char *archive, size_t archive_size, const char *destination) {
    if (archive == NULL || destination == NULL || archive_size < 1024 || archive_size > 67108864 || archive_size % 512 != 0) return -EINVAL;
    int root = open_directory_path(destination);
    if (root < 0) return root;
    if (!archive_directory_empty(root)) {
        close(root);
        return -ENOTEMPTY;
    }
    char *seen[4096] = {0};
    size_t seen_count = 0;
    size_t cursor = 0;
    size_t entries = 0;
    long long result = -EINVAL;
    while (cursor + 512 <= archive_size) {
        const unsigned char *header = archive + cursor;
        if (archive_block_zero(archive, cursor)) {
            if (cursor + 1024 == archive_size && entries > 0 && archive_block_zero(archive, cursor + 512)) {
                result = 0;
            }
            break;
        }
        if (cursor + 1024 > archive_size || memcmp(header + 257, "ustar\0", 6) != 0 || header[263] != '0' || header[264] != '0' || header[156] != '0') break;
        size_t name_length = 0;
        while (name_length < 100 && header[name_length] != '\0') name_length++;
        if (name_length == 0 || name_length >= 100 || !archive_entry_safe(header, name_length)) break;
        char name_text[100];
        memcpy(name_text, header, name_length);
        name_text[name_length] = '\0';
        if (archive_name_seen(seen, seen_count, name_text)) break;
        if (!archive_range_zero(header, name_length + 1, 100 - name_length - 1) ||
            !archive_range_zero(header, 157, 100) || !archive_range_zero(header, 265, 80) ||
            !archive_range_zero(header, 345, 155) || !archive_range_zero(header, 500, 12)) break;
        if (seen_count >= 4096) break;
        size_t mode = 0, uid = 0, gid = 0, size = 0, mtime = 0, stored_checksum = 0;
        if (!archive_parse_octal(header, 100, 8, &mode) || !archive_parse_octal(header, 108, 8, &uid) ||
            !archive_parse_octal(header, 116, 8, &gid) || !archive_parse_octal(header, 124, 12, &size) ||
            !archive_parse_octal(header, 136, 12, &mtime) || !archive_parse_octal(header, 148, 8, &stored_checksum) ||
            mode != 0644 || uid != 0 || gid != 0 || mtime != 0 || size > 67108864 - 1024) break;
        size_t checksum = 0;
        for (size_t index = 0; index < 512; index++) {
            checksum += (index >= 148 && index < 156) ? 32 : header[index];
        }
        if (checksum != stored_checksum) break;
        size_t data_start = cursor + 512;
        if (size > archive_size - data_start) break;
        size_t data_end = data_start + size;
        size_t padding = (512 - (size % 512)) % 512;
        if (padding > archive_size - data_end) break;
        for (size_t index = 0; index < padding; index++) {
            if (archive[data_end + index] != 0) goto extraction_failed;
        }
        char *entry_copy = malloc(name_length + 1);
        if (entry_copy == NULL) goto extraction_failed;
        memcpy(entry_copy, header, name_length);
        entry_copy[name_length] = '\0';
        char *copy = NULL;
        char *leaf = NULL;
        int parent = archive_open_parent(root, header, name_length, &copy, &leaf);
        if (parent < 0) {
            free(entry_copy);
            goto extraction_failed;
        }
        int file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (file < 0) {
            close(parent);
            free(copy);
            free(entry_copy);
            goto extraction_failed;
        }
        size_t written = 0;
        while (written < size) {
            ssize_t amount = write(file, archive + data_start + written, size - written);
            if (amount < 0 && errno == EINTR) continue;
            if (amount <= 0) {
                close(file);
                (void)unlinkat(parent, leaf, 0);
                close(parent);
                free(copy);
                free(entry_copy);
                goto extraction_failed;
            }
            written += (size_t)amount;
        }
        const int sync_status = fsync(file);
        const int close_status = close(file);
        if (sync_status != 0 || close_status != 0) {
            (void)unlinkat(parent, leaf, 0);
            close(parent);
            free(copy);
            free(entry_copy);
            goto extraction_failed;
        }
        close(parent);
        free(copy);
        seen[seen_count] = entry_copy;
        seen_count++;
        entries++;
        if (entries > 4096) goto extraction_failed;
        cursor = data_end + padding;
        continue;

extraction_failed:
        result = -EINVAL;
        break;
    }
    if (result != 0) archive_cleanup_files(root, seen, seen_count);
    for (size_t index = 0; index < seen_count; index++) free(seen[index]);
    close(root);
    return result;
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

const char *elisapkg_realpath(const char *path, unsigned char *resolved, size_t capacity) {
    if (path == NULL || resolved == NULL || capacity == 0 || strlen(path) > 4096) return NULL;
    char *canonical = realpath(path, NULL);
    if (canonical == NULL) return NULL;
    const size_t length = strlen(canonical);
    if (length + 1 > capacity) {
        free(canonical);
        return NULL;
    }
    memcpy(resolved, canonical, length + 1);
    free(canonical);
    return (const char *)resolved;
}

long long elisapkg_chdir(const char *path) {
    int directory = open_directory_path(path);
    if (directory < 0) return directory;
    const int result = fchdir(directory) == 0 ? 0 : -errno;
    close(directory);
    return result;
}

long long elisapkg_set_process_group(void) {
    return setpgid(0, 0) == 0 ? 0 : -errno;
}

static long long monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    if (now.tv_sec > (time_t)(LLONG_MAX / 1000)) return LLONG_MAX;
    const long long seconds = (long long)now.tv_sec * 1000;
    return seconds + (long long)(now.tv_nsec / 1000000);
}

long long elisapkg_waitpid_timeout(long long pid, long long *status, long long timeout_ms) {
    if (pid <= 0 || status == NULL || timeout_ms <= 0) return -EINVAL;
    const long long started = monotonic_milliseconds();
    if (started < 0) return -EIO;
    const long long deadline = started > LLONG_MAX - timeout_ms ? LLONG_MAX : started + timeout_ms;
    for (;;) {
        int native_status = 0;
        const pid_t waited = waitpid((pid_t)pid, &native_status, WNOHANG);
        if (waited == (pid_t)pid) {
            *status = (long long)native_status;
            return 0;
        }
        if (waited < 0) {
            if (errno == EINTR) continue;
            return errno == 0 ? -EIO : -errno;
        }
        const long long now = monotonic_milliseconds();
        if (now < 0) return -EIO;
        if (now >= deadline) {
            if (kill(-(pid_t)pid, SIGKILL) != 0 && errno != ESRCH) {
                (void)kill((pid_t)pid, SIGKILL);
            }
            int discarded_status = 0;
            while (waitpid((pid_t)pid, &discarded_status, 0) < 0 && errno == EINTR) {
            }
            *status = (long long)discarded_status;
            return -ETIMEDOUT;
        }
        struct timespec pause = {0, 10000000L};
        while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
        }
    }
}

long long elisapkg_timeout_error(void) {
    return -ETIMEDOUT;
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
