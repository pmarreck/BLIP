/*
 * blar_common.h -- Shared utilities for blar and miniblar CLIs
 *
 * Includes: file I/O, mkdir -p, progress bar, exit codes, arg parsing.
 */

#ifndef BLAR_COMMON_H
#define BLAR_COMMON_H

/* Enable POSIX.1-2008 for st_mtim, utimensat, AT_FDCWD, UTIME_OMIT on Linux.
 * Not needed on macOS (which exposes these without feature macros) and would
 * actually hide BSD extensions like st_birthtimespec. */
#if defined(__linux__) && (!defined(_POSIX_C_SOURCE) || _POSIX_C_SOURCE < 200809L)
#undef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "blip.h"

#include <errno.h>
#include <grp.h>
#include <time.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <termios.h>
#include <fcntl.h>

#if defined(__APPLE__)
#include <sys/time.h>
#endif

/* ── Exit codes ───────────────────────────────────────────────────────── */

#define EXIT_OK       0
#define EXIT_USAGE    1
#define EXIT_IO       2
#define EXIT_VERIFY   3

/* ── Version ──────────────────────────────────────────────────────────── */

#define BLAR_VERSION "0.2.0"

/* ── Operation enum ───────────────────────────────────────────────────── */

typedef enum {
    OP_NONE,
    OP_CREATE,
    OP_LIST,
    OP_EXTRACT,
    OP_VERIFY,
    OP_INFO,
    OP_CAT,
    OP_PEEK,
    OP_POKE,
    OP_TO_JSON,
    OP_FROM_JSON,
} operation_t;

/* ── Utility: read entire file into malloc'd buffer ──────────────────── */

static uint8_t *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long len = ftell(f);
    if (len < 0) { fclose(f); return NULL; }
    rewind(f);

    uint8_t *buf = malloc((size_t)len);
    if (!buf) { fclose(f); return NULL; }

    if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_len = (size_t)len;
    return buf;
}

/* ── Utility: human-readable file size ────────────────────────────────── */

static const char *format_size(uint64_t bytes, char *buf, size_t buf_size) {
    const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    double size = (double)bytes;
    int unit = 0;
    while (size >= 1024.0 && unit < 4) { size /= 1024.0; unit++; }
    if (unit == 0)
        snprintf(buf, buf_size, "%llu B", (unsigned long long)bytes);
    else
        snprintf(buf, buf_size, "%.1f %s", size, units[unit]);
    return buf;
}

/* ── Utility: write buffer to file ───────────────────────────────────── */

static bool write_file(const char *path, const uint8_t *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return false;
    if (len > 0 && fwrite(data, 1, len, f) != len) {
        fclose(f);
        return false;
    }
    fclose(f);
    return true;
}

/* Write with progress: writes in 4 MB chunks, calling back after each.
 * progress_cb(bytes_written, user_ctx) is called after every chunk. */
typedef void (*write_progress_fn)(uint64_t bytes_written, void *user_ctx);

static bool write_file_progress(const char *path, const uint8_t *data, size_t len,
                                 write_progress_fn progress_cb, void *user_ctx) {
    FILE *f = fopen(path, "wb");
    if (!f) return false;
    const size_t chunk = 64 * 1024 * 1024;
    size_t written = 0;
    while (written < len) {
        size_t n = len - written < chunk ? len - written : chunk;
        if (fwrite(data + written, 1, n, f) != n) {
            fclose(f);
            return false;
        }
        written += n;
        if (progress_cb) progress_cb((uint64_t)written, user_ctx);
    }
    fclose(f);
    return true;
}

/* ── Password helpers ─────────────────────────────────────────────────── */

/* Prompt for a password on stderr with echo disabled.
 * Returns a pointer to a static buffer (overwritten on next call). */
static const char *prompt_password(const char *prompt) {
    static char pw_buf[256];
    fprintf(stderr, "%s", prompt);
    struct termios old, new_term;
    bool tty = (tcgetattr(fileno(stdin), &old) == 0);
    if (tty) {
        new_term = old;
        new_term.c_lflag &= ~(tcflag_t)ECHO;
        tcsetattr(fileno(stdin), TCSANOW, &new_term);
    }
    if (!fgets(pw_buf, sizeof(pw_buf), stdin)) {
        if (tty) tcsetattr(fileno(stdin), TCSANOW, &old);
        return NULL;
    }
    if (tty) {
        tcsetattr(fileno(stdin), TCSANOW, &old);
        fprintf(stderr, "\n");
    }
    size_t len = strlen(pw_buf);
    if (len > 0 && pw_buf[len-1] == '\n') pw_buf[--len] = '\0';
    return pw_buf;
}

/* Get password from BLIP_PASSWORD env var, or prompt interactively.
 * Returns NULL if no password available. */
static const char *get_password(void) {
    const char *pw = getenv("BLIP_PASSWORD");
    if (pw && pw[0] != '\0') return pw;
    return prompt_password("Password: ");
}

/* ── Utility: read archive with transparent decryption/decompression ──── */

/* Read a plain (uncompressed, unencrypted) archive file.
 * For use by miniblar which only handles MBAR-magic flat archives.
 * Rejects compressed or encrypted LP containers — those need blar.
 * Returns a malloc'd buffer — caller frees with free(). */
static uint8_t *read_archive_plain(const char *path, size_t *out_len) {
    uint8_t *buf = read_file(path, out_len);
    if (!buf) return NULL;

    if (blip_is_encrypted(buf, *out_len)) {
        fprintf(stderr, "Encrypted archives not supported by miniblar (use blar)\n");
        free(buf);
        return NULL;
    }

    if (blip_is_compressed(buf, *out_len)) {
        fprintf(stderr, "Compressed archives not supported by miniblar (use blar)\n");
        free(buf);
        return NULL;
    }

    return buf;
}

/* Read an archive file, transparently decrypting and/or decompressing.
 * Always returns a malloc'd buffer — caller frees with free().
 * Layering order on disk: compress → encrypt (innermost to outermost).
 * So on read: decrypt (outer) → decompress (inner). */
static uint8_t *read_archive(const char *path, size_t *out_len) {
    uint8_t *buf = read_file(path, out_len);
    if (!buf) return NULL;

    /* Check for encrypted LP container (ENC attribute) — outermost layer */
    if (blip_is_encrypted(buf, *out_len)) {
        const char *password = get_password();
        if (!password) {
            fprintf(stderr, "Password required for encrypted archive\n");
            free(buf);
            return NULL;
        }
        uint8_t *decrypted = NULL;
        size_t dec_len = 0;
        int32_t rc = blip_decrypt_container(buf, *out_len,
                                             password, strlen(password),
                                             &decrypted, &dec_len);
        free(buf);
        if (rc != BLIP_OK) {
            if (rc == BLIP_ERR_AUTH_FAILED)
                fprintf(stderr, "Wrong password or corrupted archive\n");
            else
                fprintf(stderr, "Decryption failed: %s\n", blip_error_string(rc));
            return NULL;
        }
        /* Copy into malloc'd buffer so caller can free() uniformly */
        buf = (uint8_t *)malloc(dec_len);
        if (!buf) {
            blip_free(decrypted, dec_len);
            return NULL;
        }
        memcpy(buf, decrypted, dec_len);
        blip_free(decrypted, dec_len);
        *out_len = dec_len;
    }

    /* Check for compressed LP container (COMP attribute) — inner layer */
    if (blip_is_compressed(buf, *out_len)) {
        uint8_t *decompressed = NULL;
        size_t decomp_len = 0;
        int32_t rc = blip_decompress_container(buf, *out_len, &decompressed, &decomp_len);
        free(buf);
        if (rc != BLIP_OK) {
            fprintf(stderr, "Failed to decompress archive: %s\n", blip_error_string(rc));
            return NULL;
        }
        /* Copy into malloc'd buffer so caller can free() uniformly */
        buf = (uint8_t *)malloc(decomp_len);
        if (!buf) {
            blip_free(decompressed, decomp_len);
            return NULL;
        }
        memcpy(buf, decompressed, decomp_len);
        blip_free(decompressed, decomp_len);
        *out_len = decomp_len;
    }

    return buf;
}

/* ── Utility: mkdir -p ───────────────────────────────────────────────── */

static bool mkdirp(const char *path) {
    char tmp[4096];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return false;
    memcpy(tmp, path, len + 1);

    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return false;
            tmp[i] = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return false;
    return true;
}

/* Ensure the parent directory of a file path exists. */
static bool ensure_parent_dir(const char *filepath) {
    char tmp[4096];
    size_t len = strlen(filepath);
    if (len >= sizeof(tmp)) return false;
    memcpy(tmp, filepath, len + 1);

    char *last_slash = strrchr(tmp, '/');
    if (!last_slash) return true;
    *last_slash = '\0';
    return mkdirp(tmp);
}

/* ── Metadata helpers ─────────────────────────────────────────────────── */

/* Get mtime in nanoseconds from a stat result. */
static int64_t get_mtime_ns(const struct stat *st) {
#if defined(__APPLE__)
    return (int64_t)st->st_mtimespec.tv_sec * 1000000000LL +
           (int64_t)st->st_mtimespec.tv_nsec;
#elif defined(__linux__)
    return (int64_t)st->st_mtim.tv_sec * 1000000000LL +
           (int64_t)st->st_mtim.tv_nsec;
#else
    return (int64_t)st->st_mtime * 1000000000LL;
#endif
}

/* Get ctime (inode change time) in nanoseconds. */
static int64_t get_ctime_ns(const struct stat *st) {
#if defined(__APPLE__)
    return (int64_t)st->st_ctimespec.tv_sec * 1000000000LL +
           (int64_t)st->st_ctimespec.tv_nsec;
#elif defined(__linux__)
    return (int64_t)st->st_ctim.tv_sec * 1000000000LL +
           (int64_t)st->st_ctim.tv_nsec;
#else
    return (int64_t)st->st_ctime * 1000000000LL;
#endif
}

/* Get birthtime (creation time) in nanoseconds.
 * Returns 0 if not available on this platform. */
static int64_t get_birthtime_ns(const struct stat *st) {
#if defined(__APPLE__)
    return (int64_t)st->st_birthtimespec.tv_sec * 1000000000LL +
           (int64_t)st->st_birthtimespec.tv_nsec;
#else
    (void)st;
    return 0; /* birthtime not readily available on Linux without statx */
#endif
}

/* Get owner (username) from uid. Returns NULL if not found. */
static const char *get_owner_name(uid_t uid) {
    struct passwd *pw = getpwuid(uid);
    return pw ? pw->pw_name : NULL;
}

/* Get group name from gid. Returns NULL if not found. */
static const char *get_group_name(gid_t gid) {
    struct group *gr = getgrgid(gid);
    return gr ? gr->gr_name : NULL;
}

/* Populate a blip_archive_entry with metadata from a stat result.
 * Fills in mode, mtime_ns, ctime_ns, birthtime_ns, uid, gid, owner, groupname.
 * The entry's path, content, and is_dir fields must be set by the caller. */
static void fill_entry_metadata(blip_archive_entry *entry, const struct stat *st) {
    entry->mode = (uint16_t)(st->st_mode & 07777);
    entry->mtime_ns = get_mtime_ns(st);
    entry->ctime_ns = get_ctime_ns(st);
    entry->birthtime_ns = get_birthtime_ns(st);
    entry->uid = (uint32_t)st->st_uid;
    entry->gid = (uint32_t)st->st_gid;
    entry->zip_compression_method = 0xFFFF;
    entry->pdf_stream_offset = UINT64_MAX;
    entry->pdf_stream_length = UINT64_MAX;
    entry->flate_predictor = 0;
    entry->flate_columns = 0;
    entry->flate_colors = 0;
    entry->flate_bpc = 0;

    const char *owner = get_owner_name(st->st_uid);
    if (owner) {
        entry->owner = owner;
        entry->owner_len = strlen(owner);
    } else {
        entry->owner = NULL;
        entry->owner_len = 0;
    }

    const char *gname = get_group_name(st->st_gid);
    if (gname) {
        entry->groupname = gname;
        entry->groupname_len = strlen(gname);
    } else {
        entry->groupname = NULL;
        entry->groupname_len = 0;
    }
}

/* ── Extended attribute helpers ────────────────────────────────────────── */

#if defined(__APPLE__) || defined(__linux__)
  #if defined(__has_include)
    #if __has_include(<sys/xattr.h>)
      #include <sys/xattr.h>
      #define HAVE_XATTR 1
    #endif
  #endif
#endif

/* Read extended attributes from a filesystem path.
 * Separates com.apple.ResourceFork into dedicated output on macOS.
 * Returns 0 on success, -1 on error (errno set).
 * Caller must free returned buffers with free_file_xattrs(). */
static int read_file_xattrs(const char *path,
                             blip_xattr_entry **out_xattrs, size_t *out_count,
                             uint8_t **out_resource_fork, size_t *out_resource_fork_len) {
    *out_xattrs = NULL;
    *out_count = 0;
    *out_resource_fork = NULL;
    *out_resource_fork_len = 0;

#ifdef HAVE_XATTR
    /* List xattr names */
#if defined(__APPLE__)
    ssize_t list_len = listxattr(path, NULL, 0, XATTR_NOFOLLOW);
#else
    ssize_t list_len = llistxattr(path, NULL, 0);
#endif
    if (list_len <= 0) return 0; /* no xattrs or error */

    char *name_buf = (char *)malloc((size_t)list_len);
    if (!name_buf) return -1;

#if defined(__APPLE__)
    list_len = listxattr(path, name_buf, (size_t)list_len, XATTR_NOFOLLOW);
#else
    list_len = llistxattr(path, name_buf, (size_t)list_len);
#endif
    if (list_len <= 0) {
        free(name_buf);
        return 0;
    }

    /* Count xattr names */
    size_t total = 0;
    for (ssize_t i = 0; i < list_len; ) {
        total++;
        i += (ssize_t)strlen(name_buf + i) + 1;
    }

    /* Allocate max possible (some may become resource_fork) */
    blip_xattr_entry *xattrs = (blip_xattr_entry *)calloc(total, sizeof(blip_xattr_entry));
    if (!xattrs) { free(name_buf); return -1; }

    size_t count = 0;
    for (ssize_t i = 0; i < list_len; ) {
        const char *name = name_buf + i;
        size_t name_len = strlen(name);
        i += (ssize_t)name_len + 1;

        /* Get value size */
#if defined(__APPLE__)
        ssize_t val_len = getxattr(path, name, NULL, 0, 0, XATTR_NOFOLLOW);
#else
        ssize_t val_len = lgetxattr(path, name, NULL, 0);
#endif
        if (val_len < 0) continue; /* skip unreadable */

        uint8_t *val_buf = NULL;
        if (val_len > 0) {
            val_buf = (uint8_t *)malloc((size_t)val_len);
            if (!val_buf) continue;
#if defined(__APPLE__)
            ssize_t got = getxattr(path, name, val_buf, (size_t)val_len, 0, XATTR_NOFOLLOW);
#else
            ssize_t got = lgetxattr(path, name, val_buf, (size_t)val_len);
#endif
            if (got < 0) { free(val_buf); continue; }
            val_len = got;
        }

#if defined(__APPLE__)
        /* Separate resource fork */
        if (strcmp(name, "com.apple.ResourceFork") == 0) {
            *out_resource_fork = val_buf;
            *out_resource_fork_len = (size_t)val_len;
            continue;
        }
#endif

        /* Duplicate name (name_buf will be freed) */
        char *name_dup = strdup(name);
        if (!name_dup) { free(val_buf); continue; }

        xattrs[count].name = name_dup;
        xattrs[count].name_len = name_len;
        xattrs[count].value = val_buf;
        xattrs[count].value_len = (size_t)val_len;
        count++;
    }

    free(name_buf);

    if (count == 0) {
        free(xattrs);
        return 0;
    }

    *out_xattrs = xattrs;
    *out_count = count;
#else
    (void)path;
#endif /* HAVE_XATTR */

    return 0;
}

/* Free xattr data returned by read_file_xattrs(). */
static void free_file_xattrs(blip_xattr_entry *xattrs, size_t count,
                               uint8_t *resource_fork) {
    if (xattrs) {
        for (size_t i = 0; i < count; i++) {
            free((void *)xattrs[i].name);
            free((void *)xattrs[i].value);
        }
        free(xattrs);
    }
    if (resource_fork) free(resource_fork);
}

/* Write extended attributes to a filesystem path.
 * Writes resource fork as com.apple.ResourceFork on macOS.
 * Non-fatal: warns on stderr for individual failures. */
static void write_file_xattrs(const char *path,
                                const blip_xattr_entry *xattrs, size_t count,
                                const uint8_t *resource_fork, size_t resource_fork_len) {
#ifdef HAVE_XATTR
    for (size_t i = 0; i < count; i++) {
        /* Build null-terminated name */
        char name_buf[256];
        if (xattrs[i].name_len >= sizeof(name_buf)) {
            fprintf(stderr, "warning: xattr name too long, skipping\n");
            continue;
        }
        memcpy(name_buf, xattrs[i].name, xattrs[i].name_len);
        name_buf[xattrs[i].name_len] = '\0';

#if defined(__APPLE__)
        int rc = setxattr(path, name_buf, xattrs[i].value, xattrs[i].value_len, 0, XATTR_NOFOLLOW);
#else
        int rc = lsetxattr(path, name_buf, xattrs[i].value, xattrs[i].value_len, 0);
#endif
        if (rc != 0) {
            fprintf(stderr, "warning: cannot set xattr '%s' on '%s': %s\n",
                    name_buf, path, strerror(errno));
        }
    }

#if defined(__APPLE__)
    if (resource_fork && resource_fork_len > 0) {
        int rc = setxattr(path, "com.apple.ResourceFork", resource_fork, resource_fork_len, 0, XATTR_NOFOLLOW);
        if (rc != 0) {
            fprintf(stderr, "warning: cannot set resource fork on '%s': %s\n",
                    path, strerror(errno));
        }
    }
#else
    if (resource_fork && resource_fork_len > 0) {
        fprintf(stderr, "\033[33mwarning: resource fork data for '%s' cannot be restored "
                "(not macOS) — %zu bytes dropped\033[0m\n", path, resource_fork_len);
    }
#endif

#else
    /* No xattr support on this platform */
    if (count > 0) {
        fprintf(stderr, "\033[33mwarning: %zu extended attribute(s) for '%s' cannot be restored "
                "(platform lacks xattr support)\033[0m\n", count, path);
    }
    if (resource_fork && resource_fork_len > 0) {
        fprintf(stderr, "\033[33mwarning: resource fork data for '%s' cannot be restored "
                "(platform lacks xattr support) — %zu bytes dropped\033[0m\n",
                path, resource_fork_len);
    }
    (void)xattrs;
#endif /* HAVE_XATTR */
}

/* ── MIME-type sorting (for solid compression) ────────────────────────── */

#ifdef HAVE_LIBMAGIC
#include <magic.h>

static magic_t g_magic = NULL;

static void init_magic(void) {
    g_magic = magic_open(MAGIC_MIME_TYPE | MAGIC_NO_CHECK_COMPRESS);
    if (g_magic) magic_load(g_magic, NULL);
}

static void cleanup_magic(void) {
    if (g_magic) { magic_close(g_magic); g_magic = NULL; }
}

static int mime_compare(const void *a, const void *b) {
    const blip_archive_entry *ea = (const blip_archive_entry *)a;
    const blip_archive_entry *eb = (const blip_archive_entry *)b;
    /* Directories first */
    if (ea->is_dir && !eb->is_dir) return -1;
    if (!ea->is_dir && eb->is_dir) return 1;
    if (ea->is_dir && eb->is_dir) return strcmp(ea->path, eb->path);
    /* Sort files by MIME type */
    const char *ma = magic_buffer(g_magic, ea->content, ea->content_len);
    const char *mb = magic_buffer(g_magic, eb->content, eb->content_len);
    if (!ma) ma = "application/octet-stream";
    if (!mb) mb = "application/octet-stream";
    int cmp = strcmp(ma, mb);
    return cmp != 0 ? cmp : strcmp(ea->path, eb->path);
}

static void mime_sort_entries(blip_archive_entry *entries, size_t count) {
    init_magic();
    if (!g_magic) return; /* graceful fallback */
    qsort(entries, count, sizeof(blip_archive_entry), mime_compare);
    cleanup_magic();
}
#else
static void mime_sort_entries(blip_archive_entry *entries, size_t count) {
    (void)entries; (void)count;
}
#endif /* HAVE_LIBMAGIC */

/* ── Progress (via progrez library) ───────────────────────────────────── */

#include "progrez.h"

/* ── Tar-style flag parsing ───────────────────────────────────────────── */

static operation_t parse_tar_flags(const char *flags, bool *has_f) {
    operation_t op = OP_NONE;
    *has_f = false;
    for (const char *p = flags; *p; p++) {
        switch (*p) {
        case '-': break;
        case 'c':
            if (op != OP_NONE) return OP_NONE;
            op = OP_CREATE;
            break;
        case 't':
            if (op != OP_NONE) return OP_NONE;
            op = OP_LIST;
            break;
        case 'x':
            if (op != OP_NONE) return OP_NONE;
            op = OP_EXTRACT;
            break;
        case 'V':
            if (op != OP_NONE) return OP_NONE;
            op = OP_VERIFY;
            break;
        case 'I':
            if (op != OP_NONE) return OP_NONE;
            op = OP_INFO;
            break;
        case 'p':
            if (op != OP_NONE) return OP_NONE;
            op = OP_CAT;
            break;
        case 'k':
            if (op != OP_NONE) return OP_NONE;
            op = OP_PEEK;
            break;
        case 'K':
            if (op != OP_NONE) return OP_NONE;
            op = OP_POKE;
            break;
        case 'j':
            if (op != OP_NONE) return OP_NONE;
            op = OP_TO_JSON;
            break;
        case 'J':
            if (op != OP_NONE) return OP_NONE;
            op = OP_FROM_JSON;
            break;
        case 'P':
            break; /* absolute-names: handled by caller after parse */
        case 'f':
            *has_f = true;
            break;
        default:
            return OP_NONE;
        }
    }
    return op;
}

/* Check if 'P' (absolute-names) flag is present in a tar-style flag string. */
static bool tar_flags_has_P(const char *flags) {
    for (const char *p = flags; *p; p++) {
        if (*p == 'P') return true;
    }
    return false;
}

/* ── Default output name helper ───────────────────────────────────────── */

/* Given a single input path, produce "<basename><ext>" in the provided buffer.
 * ext should include the leading dot (e.g. ".blar", ".mblar").
 * Returns the buffer on success, NULL if the result would overflow. */
static char *default_output_name(const char *input_path, const char *ext,
                                 char *buf, size_t buf_size) {
    /* Strip trailing slashes from input path before finding basename */
    size_t path_len = strlen(input_path);
    while (path_len > 1 && input_path[path_len - 1] == '/') path_len--;

    /* Find the basename: last component after '/' */
    const char *base = input_path;
    for (size_t i = 0; i < path_len; i++) {
        if (input_path[i] == '/' && i + 1 < path_len) base = input_path + i + 1;
    }
    size_t base_len = (size_t)(input_path + path_len - base);
    if (base_len == 0) return NULL;

    size_t ext_len = strlen(ext);
    if (base_len + ext_len + 1 > buf_size) return NULL;
    memcpy(buf, base, base_len);
    memcpy(buf + base_len, ext, ext_len);
    buf[base_len + ext_len] = '\0';
    return buf;
}

/* ── Peek: thin C wrapper calling Zig core via blip_peek_display ──────── */

/* Main peek command implementation shared by blar and miniblar.
 * All formatting logic lives in Zig (peek.zig peekDisplay).
 * This wrapper only handles: arg parsing, file I/O, isatty check, output. */
static void peek_usage(FILE *out, const char *prog) {
    fprintf(out,
        "Usage: %s peek <archive> [<path>] [--json|--raw|--hex|--type]\n"
        "\n"
        "Navigate and inspect BLIP archive structure.\n"
        "\n"
        "Path syntax:\n"
        "  [N]       Array/FILE element by index\n"
        "  [key]     DICT/MAP/DIR value by key\n"
        "\n"
        "Accessors (append to path):\n"
        "  .type     Container type name (ARRAY, DICT, FILE, ...)\n"
        "  .count    Element/pair count\n"
        "  .hash     Trailing xxHash64 (hex)\n"
        "  .keys     List DICT/MAP/DIR keys\n"
        "\n"
        "Output flags:\n"
        "  --raw     Raw payload bytes (printable-binary encoded if stdout is a TTY)\n"
        "  --hex     Hex-encoded payload (0x-prefixed)\n"
        "  --json    JSON output\n"
        "  --type    Shorthand for .type accessor\n"
        "\n"
        "Archive structure:\n"
        "  ARRAY[ DATA(magic), ARRAY[ FILE[DICT{meta}, DATA{content}], ... ] ]\n"
        "  [0]           magic bytes\n"
        "  [1]           body array (all entries)\n"
        "  [1][0]        first entry (FILE or DIR)\n"
        "  [1][0][0]     metadata dict (keys: pa, md, mt, ct, bt, ui, gi, un, gn)\n"
        "  [1][0][1]     file content (DATA)\n"
        "\n"
        "Examples:\n"
        "  %s peek archive.blar \"[1][0][0][pa]\"       # file path\n"
        "  %s peek archive.blar \"[1][0][1]\" --raw     # raw content\n"
        "  %s peek archive.blar \"[1][0].type\"         # FILE\n"
        "  %s peek archive.blar \"[1][0][0].keys\"      # metadata key list\n",
        prog, prog, prog, prog, prog);
}

static int cmd_peek_common(const char *prog, int argc, char **argv) {
    /* Check for --help / -h anywhere in args */
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            peek_usage(stdout, prog);
            return EXIT_OK;
        }
    }

    if (argc < 1) {
        peek_usage(stderr, prog);
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *path = "";
    uint32_t flags = 0;
    bool type_flag = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0)       flags |= BLIP_PEEK_JSON;
        else if (strcmp(argv[i], "--raw") == 0)    flags |= BLIP_PEEK_RAW;
        else if (strcmp(argv[i], "--hex") == 0)    flags |= BLIP_PEEK_HEX;
        else if (strcmp(argv[i], "--type") == 0)   type_flag = true;
        else if (argv[i][0] != '-') {
            if (path[0] == '\0')
                path = argv[i];
            else {
                fprintf(stderr, "%s: peek: unexpected argument '%s'\n",
                        prog, argv[i]);
                return EXIT_USAGE;
            }
        } else {
            fprintf(stderr, "%s: peek: unknown option '%s'\n", prog, argv[i]);
            return EXIT_USAGE;
        }
    }

    if (isatty(STDOUT_FILENO)) flags |= BLIP_PEEK_IS_TTY;

    /* --type flag: append .type accessor to path */
    char type_path[4096];
    if (type_flag) {
        size_t plen = strlen(path);
        if (plen + 5 >= sizeof(type_path)) {
            fprintf(stderr, "%s: peek: path too long\n", prog);
            return EXIT_USAGE;
        }
        memcpy(type_path, path, plen);
        memcpy(type_path + plen, ".type", 5);
        type_path[plen + 5] = '\0';
        path = type_path;
    }

    /* Read archive */
    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "%s: peek: cannot open '%s': %s\n",
                prog, archive_path, strerror(errno));
        return EXIT_IO;
    }

    /* Call Zig core */
    const uint8_t *out_stdout = NULL;
    size_t out_stdout_len = 0;
    const uint8_t *out_stderr = NULL;
    size_t out_stderr_len = 0;

    int32_t rc = blip_peek_display(buf, buf_len,
                                    path, strlen(path),
                                    flags,
                                    &out_stdout, &out_stdout_len,
                                    &out_stderr, &out_stderr_len);

    /* Output */
    if (out_stderr_len > 0) fwrite(out_stderr, 1, out_stderr_len, stderr);
    if (out_stdout_len > 0) fwrite(out_stdout, 1, out_stdout_len, stdout);

    /* Cleanup */
    if (out_stdout_len > 0) blip_free((uint8_t *)out_stdout, out_stdout_len);
    if (out_stderr_len > 0) blip_free((uint8_t *)out_stderr, out_stderr_len);
    free(buf);

    return (rc == 0) ? EXIT_OK : EXIT_IO;
}

/* ── Poke: thin C wrapper calling Zig core via blip_poke ──────────────── */

static void poke_usage(FILE *out, const char *prog) {
    fprintf(out,
        "Usage: %s poke <archive> <path> [--value <string>] [-i <file>] [-o <output>] [--backup]\n"
        "\n"
        "Modify a value in a BLIP archive.\n"
        "\n"
        "Value sources (priority order):\n"
        "  --value <string>   Literal string value\n"
        "  -i <file>          Read value from file\n"
        "  (stdin)            Read value from standard input (default)\n"
        "\n"
        "Output options:\n"
        "  -o <output>        Write modified archive to a different file\n"
        "  --backup           Create .bak copy before overwriting in place\n"
        "\n"
        "Path syntax:\n"
        "  [N]       Array/FILE element by index\n"
        "  [key]     DICT/MAP/DIR value by key\n"
        "\n"
        "Pokeable targets:\n"
        "  [1][N][1]          FILE content (DATA)\n"
        "  [1][N][0][pa]      File path (rename)\n"
        "  [1][N][0][key]     Any metadata leaf value\n"
        "\n"
        "Examples:\n"
        "  echo -n 'new' | %s poke archive.blar \"[1][0][1]\"           # stdin\n"
        "  %s poke archive.blar \"[1][0][1]\" --value \"hello\"            # literal\n"
        "  %s poke archive.blar \"[1][0][0][pa]\" --value \"renamed.txt\"  # rename\n"
        "  %s poke archive.blar \"[1][0][1]\" -i data.bin                # from file\n"
        "  %s poke archive.blar \"[1][0][1]\" --value x -o new.blar      # output file\n"
        "  %s poke archive.blar \"[1][0][1]\" --value x --backup         # .bak first\n",
        prog, prog, prog, prog, prog, prog, prog);
}

/* Read all bytes from stdin into a malloc'd buffer. Returns NULL on error. */
static uint8_t *read_stdin_all(size_t *out_len) {
    size_t cap = 4096;
    size_t len = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) return NULL;

    while (1) {
        if (len >= cap) {
            cap *= 2;
            uint8_t *newbuf = (uint8_t *)realloc(buf, cap);
            if (!newbuf) { free(buf); return NULL; }
            buf = newbuf;
        }
        size_t n = fread(buf + len, 1, cap - len, stdin);
        if (n == 0) break;
        len += n;
    }
    *out_len = len;
    return buf;
}

/* Atomic write: write to a temp file, then rename. */
static bool write_file_atomic(const char *path, const uint8_t *data, size_t len) {
    char tmp_path[4200];
    int n = snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", path, (int)getpid());
    if (n < 0 || (size_t)n >= sizeof(tmp_path)) return false;

    if (!write_file(tmp_path, data, len)) {
        unlink(tmp_path);
        return false;
    }
    if (rename(tmp_path, path) != 0) {
        unlink(tmp_path);
        return false;
    }
    return true;
}

/* Copy a file (for --backup). */
static bool copy_file(const char *src, const char *dst) {
    size_t len = 0;
    uint8_t *data = read_file(src, &len);
    if (!data) return false;
    bool ok = write_file(dst, data, len);
    free(data);
    return ok;
}

static int cmd_poke_common(const char *prog, int argc, char **argv) {
    /* Check for --help / -h anywhere */
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            poke_usage(stdout, prog);
            return EXIT_OK;
        }
    }

    if (argc < 2) {
        poke_usage(stderr, prog);
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *path_expr = argv[1];
    const char *value_str = NULL;
    const char *input_file = NULL;
    const char *output_path = NULL;
    bool backup = false;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--value") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: poke: --value requires an argument\n", prog);
                return EXIT_USAGE;
            }
            value_str = argv[++i];
        } else if (strcmp(argv[i], "-i") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: poke: -i requires an argument\n", prog);
                return EXIT_USAGE;
            }
            input_file = argv[++i];
        } else if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: poke: -o requires an argument\n", prog);
                return EXIT_USAGE;
            }
            output_path = argv[++i];
        } else if (strcmp(argv[i], "--backup") == 0) {
            backup = true;
        } else {
            fprintf(stderr, "%s: poke: unknown option '%s'\n", prog, argv[i]);
            return EXIT_USAGE;
        }
    }

    /* Read archive */
    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "%s: poke: cannot open '%s': %s\n",
                prog, archive_path, strerror(errno));
        return EXIT_IO;
    }

    /* Get new value from --value, -i, or stdin */
    uint8_t *new_value = NULL;
    size_t new_value_len = 0;
    bool free_new_value = false;

    if (value_str) {
        new_value = (uint8_t *)value_str;
        new_value_len = strlen(value_str);
    } else if (input_file) {
        new_value = read_file(input_file, &new_value_len);
        if (!new_value) {
            fprintf(stderr, "%s: poke: cannot read '%s': %s\n",
                    prog, input_file, strerror(errno));
            free(buf);
            return EXIT_IO;
        }
        free_new_value = true;
    } else {
        /* Read from stdin */
        new_value = read_stdin_all(&new_value_len);
        if (!new_value) {
            fprintf(stderr, "%s: poke: cannot read from stdin\n", prog);
            free(buf);
            return EXIT_IO;
        }
        free_new_value = true;
    }

    /* Call blip_poke */
    uint8_t *out_buf = NULL;
    size_t out_len = 0;
    int32_t rc = blip_poke(buf, buf_len,
                           path_expr, strlen(path_expr),
                           new_value, new_value_len,
                           &out_buf, &out_len);

    if (free_new_value) free(new_value);
    free(buf);

    if (rc != BLIP_OK) {
        fprintf(stderr, "%s: poke: %s\n", prog, blip_error_string(rc));
        return EXIT_IO;
    }

    /* Write output */
    const char *write_path = output_path ? output_path : archive_path;

    if (!output_path && backup) {
        /* Create .bak copy of original */
        char bak_path[4200];
        int n = snprintf(bak_path, sizeof(bak_path), "%s.bak", archive_path);
        if (n < 0 || (size_t)n >= sizeof(bak_path)) {
            fprintf(stderr, "%s: poke: backup path too long\n", prog);
            blip_free(out_buf, out_len);
            return EXIT_IO;
        }
        if (!copy_file(archive_path, bak_path)) {
            fprintf(stderr, "%s: poke: cannot create backup '%s': %s\n",
                    prog, bak_path, strerror(errno));
            blip_free(out_buf, out_len);
            return EXIT_IO;
        }
    }

    if (!write_file_atomic(write_path, out_buf, out_len)) {
        fprintf(stderr, "%s: poke: cannot write '%s': %s\n",
                prog, write_path, strerror(errno));
        blip_free(out_buf, out_len);
        return EXIT_IO;
    }

    blip_free(out_buf, out_len);
    return EXIT_OK;
}

/* ── to-json: convert archive to JSON ─────────────────────────────────── */

static void to_json_usage(FILE *out, const char *prog) {
    fprintf(out,
        "Usage: %s to-json <archive>\n"
        "\n"
        "Convert a BLIP archive to JSON and write to stdout.\n"
        "The JSON can be piped through jq for manipulation,\n"
        "then piped to 'from-json' to create a new archive.\n"
        "\n"
        "Examples:\n"
        "  %s to-json archive.blar | jq '.entries[].path'\n"
        "  %s to-json a.blar | jq '(.entries[] | select(.path==\"hello.txt\")).content = \"new\"' | %s from-json -o b.blar\n",
        prog, prog, prog, prog);
}

static int cmd_to_json_common(const char *prog, int argc, char **argv) {
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            to_json_usage(stdout, prog);
            return EXIT_OK;
        }
    }

    if (argc < 1) {
        to_json_usage(stderr, prog);
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "%s: to-json: cannot open '%s': %s\n",
                prog, archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint8_t *json_buf = NULL;
    size_t json_len = 0;
    int32_t rc = blip_to_json(buf, buf_len, &json_buf, &json_len);
    free(buf);

    if (rc != BLIP_OK) {
        fprintf(stderr, "%s: to-json: %s\n", prog, blip_error_string(rc));
        return EXIT_IO;
    }

    if (json_len > 0) fwrite(json_buf, 1, json_len, stdout);
    blip_free(json_buf, json_len);
    return EXIT_OK;
}

/* ── from-json: convert JSON to archive ──────────────────────────────── */

static void from_json_usage(FILE *out, const char *prog) {
    fprintf(out,
        "Usage: %s from-json [-o <output>] [-z] [-e [cipher]] [--kdf <name>] [<json-file>]\n"
        "\n"
        "Convert JSON to a BLIP archive.\n"
        "Reads JSON from a file argument or stdin.\n"
        "\n"
        "Options:\n"
        "  -o <output>        Write archive to specified file (required unless piping)\n"
        "  -z [algo]          Compress (lzma2=default, bzip2, lz4, zstd)\n"
        "  -e [cipher]        Encrypt (aes = AES-256-GCM [default], chacha = ChaCha20-Poly1305)\n"
        "  --kdf <name>       KDF for encryption (argon2 [default], pbkdf2)\n"
        "\n"
        "Password for encryption is read from BLIP_PASSWORD env var.\n"
        "If -e is specified but no password is available, a warning is printed and\n"
        "encryption is skipped.\n"
        "\n"
        "Examples:\n"
        "  %s from-json input.json -o output.blar\n"
        "  cat input.json | %s from-json -o output.blar\n"
        "  %s to-json a.blar | jq '...' | %s from-json -o b.blar\n"
        "  %s to-json a.blar | %s from-json -z -e -o b.blar\n",
        prog, prog, prog, prog, prog, prog, prog);
}

static int cmd_from_json_common(const char *prog, int argc, char **argv) {
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            from_json_usage(stdout, prog);
            return EXIT_OK;
        }
    }

    const char *output_path = NULL;
    const char *input_file = NULL;
    uint8_t compress_algo = 0;  /* 0 = no compression */
    bool do_encrypt = false;
    uint8_t enc_id = 1;   /* default: AES-256-GCM */
    uint8_t kdf_id = 1;   /* default: Argon2id */

    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: from-json: -o requires an argument\n", prog);
                return EXIT_USAGE;
            }
            output_path = argv[++i];
        } else if (strcmp(argv[i], "-z") == 0) {
            compress_algo = BLIP_COMP_LZMA2; /* default */
            /* Check for optional algorithm argument */
            if (i + 1 < argc && argv[i+1][0] != '-') {
                const char *algo = argv[i+1];
                if (strcmp(algo, "lzma2") == 0 || strcmp(algo, "lzma") == 0) {
                    compress_algo = BLIP_COMP_LZMA2;
                    i++; /* consume algo arg */
                } else if (strcmp(algo, "bzip2") == 0 || strcmp(algo, "bz2") == 0) {
                    compress_algo = BLIP_COMP_BZIP2;
                    i++;
                } else if (strcmp(algo, "lz4") == 0) {
                    compress_algo = BLIP_COMP_LZ4;
                    i++;
                } else if (strcmp(algo, "zstd") == 0 || strcmp(algo, "zst") == 0) {
                    compress_algo = BLIP_COMP_ZSTD;
                    i++;
                }
                /* else: not an algo name, don't consume */
            }
        } else if (strcmp(argv[i], "-e") == 0) {
            do_encrypt = true;
            /* Check for optional cipher argument */
            if (i + 1 < argc && argv[i+1][0] != '-') {
                const char *cipher = argv[i+1];
                if (strcmp(cipher, "aes") == 0 || strcmp(cipher, "aes-256-gcm") == 0) {
                    enc_id = 1;
                    i++; /* consume cipher arg */
                } else if (strcmp(cipher, "chacha") == 0 || strcmp(cipher, "chacha20") == 0 ||
                           strcmp(cipher, "chacha20-poly1305") == 0) {
                    enc_id = 2;
                    i++; /* consume cipher arg */
                }
                /* else: not a cipher name, don't consume it */
            }
        } else if (strcmp(argv[i], "--kdf") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: from-json: --kdf requires an argument\n", prog);
                return EXIT_USAGE;
            }
            const char *kdf_name = argv[++i];
            if (strcmp(kdf_name, "argon2") == 0 || strcmp(kdf_name, "argon2id") == 0) {
                kdf_id = 1;
            } else if (strcmp(kdf_name, "pbkdf2") == 0 || strcmp(kdf_name, "pbkdf2-sha256") == 0) {
                kdf_id = 2;
            } else {
                fprintf(stderr, "%s: from-json: unknown KDF '%s' (use 'argon2' or 'pbkdf2')\n", prog, kdf_name);
                return EXIT_USAGE;
            }
        } else if (argv[i][0] != '-') {
            if (!input_file)
                input_file = argv[i];
            else {
                fprintf(stderr, "%s: from-json: unexpected argument '%s'\n", prog, argv[i]);
                return EXIT_USAGE;
            }
        } else {
            fprintf(stderr, "%s: from-json: unknown option '%s'\n", prog, argv[i]);
            return EXIT_USAGE;
        }
    }

    if (!output_path) {
        fprintf(stderr, "%s: from-json: -o <output> is required\n", prog);
        return EXIT_USAGE;
    }

    /* Read JSON from file or stdin */
    uint8_t *json_buf = NULL;
    size_t json_len = 0;

    if (input_file) {
        json_buf = read_file(input_file, &json_len);
        if (!json_buf) {
            fprintf(stderr, "%s: from-json: cannot open '%s': %s\n",
                    prog, input_file, strerror(errno));
            return EXIT_IO;
        }
    } else {
        json_buf = read_stdin_all(&json_len);
        if (!json_buf) {
            fprintf(stderr, "%s: from-json: cannot read from stdin\n", prog);
            return EXIT_IO;
        }
    }

    /* Convert JSON to archive */
    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    int32_t rc = blip_from_json(json_buf, json_len, &archive_buf, &archive_len);
    free(json_buf);

    if (rc != BLIP_OK) {
        fprintf(stderr, "%s: from-json: %s\n", prog, blip_error_string(rc));
        return EXIT_IO;
    }

    /* Optionally compress */
    if (compress_algo != 0) {
        uint8_t *compressed_buf = NULL;
        size_t compressed_len = 0;
        rc = blip_compress_container(archive_buf, archive_len, compress_algo, 0,
                                      NULL, NULL, NULL,
                                      &compressed_buf, &compressed_len);
        blip_free(archive_buf, archive_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "%s: from-json: compression failed: %s\n",
                    prog, blip_error_string(rc));
            return EXIT_IO;
        }
        archive_buf = compressed_buf;
        archive_len = compressed_len;
    }

    /* Optionally encrypt (outermost layer — after compression) */
    if (do_encrypt) {
        const char *password = getenv("BLIP_PASSWORD");
        if (!password || strlen(password) == 0) {
            fprintf(stderr, "%s: from-json: warning: -e specified but BLIP_PASSWORD not set; skipping encryption\n", prog);
        } else {
            uint8_t *encrypted_buf = NULL;
            size_t encrypted_len = 0;
            rc = blip_encrypt_container(archive_buf, archive_len,
                                         password, strlen(password),
                                         enc_id, kdf_id,
                                         &encrypted_buf, &encrypted_len);
            blip_free(archive_buf, archive_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "%s: from-json: encryption failed: %s\n",
                        prog, blip_error_string(rc));
                return EXIT_IO;
            }
            archive_buf = encrypted_buf;
            archive_len = encrypted_len;
        }
    }

    if (!write_file(output_path, archive_buf, archive_len)) {
        fprintf(stderr, "%s: from-json: cannot write '%s': %s\n",
                prog, output_path, strerror(errno));
        blip_free(archive_buf, archive_len);
        return EXIT_IO;
    }

    blip_free(archive_buf, archive_len);
    return EXIT_OK;
}


/* ── Codec plugin interface (shared between CLI and GUI) ─────────────── */

/* A codec describes how to detect and expand a container format. */
typedef struct {
    const char *name;                   /* e.g. "pdf", "png", "zip" */
    const char *const *extensions;      /* NULL-terminated list of file extensions */
    bool (*detect)(const uint8_t *buf, size_t len);
    /* expand/collapse are used only during archive creation (blar.c) */
    void *expand;   /* opaque: bool (*)(entry_list_t *, ...) */
    void *collapse; /* opaque: bool (*)(entry_list_t *, ...) */
} blar_codec_t;

/* A registry holds an array of codecs. */
typedef struct {
    const blar_codec_t *codecs;
    size_t count;
} blar_codec_registry_t;

/* Find a codec by name (e.g. "pdf", "zip").
 * Returns NULL if not found. */
static const blar_codec_t *blar_codec_find_by_name(const blar_codec_registry_t *reg,
                                                     const char *name, size_t name_len) {
    for (size_t i = 0; i < reg->count; i++) {
        if (strlen(reg->codecs[i].name) == name_len &&
            memcmp(reg->codecs[i].name, name, name_len) == 0) {
            return &reg->codecs[i];
        }
    }
    return NULL;
}

/* Detect which codec matches a buffer's magic bytes.
 * Returns the first matching codec, or NULL if none match. */
static const blar_codec_t *blar_codec_detect(const blar_codec_registry_t *reg,
                                               const uint8_t *buf_data, size_t len) {
    for (size_t i = 0; i < reg->count; i++) {
        if (reg->codecs[i].detect && reg->codecs[i].detect(buf_data, len)) {
            return &reg->codecs[i];
        }
    }
    return NULL;
}

/* ── MS-DOS timestamp conversion (needed by ZIP container reconstruction) */

static void ns_to_msdos(int64_t ns, uint16_t *out_time, uint16_t *out_date) {
    if (ns == 0) {
        *out_time = 0;
        *out_date = 0;
        return;
    }
    time_t t = (time_t)(ns / 1000000000LL);
    struct tm tm;
    localtime_r(&t, &tm);
    *out_time = (uint16_t)((tm.tm_sec / 2) | (tm.tm_min << 5) | (tm.tm_hour << 11));
    *out_date = (uint16_t)(tm.tm_mday | ((tm.tm_mon + 1) << 5) | ((tm.tm_year - 80) << 9));
}

/* ── Reusable extraction logic ───────────────────────────────────────── */

typedef void (*blar_extract_progress_fn)(uint64_t files_done, uint64_t bytes_done,
                                          uint64_t total_files, uint64_t total_bytes,
                                          void *ctx);
typedef void (*blar_extract_log_fn)(const char *msg, void *ctx);

/*
 * blar_extract_to_dir — extract an archive buffer to an output directory.
 *
 * The caller provides:
 *   buf / buf_len    — the raw (decrypted/decompressed) archive bytes
 *   output_dir       — target directory (NULL = cwd)
 *   codec_registry   — codec registry for container reconstruction
 *   progress_fn      — called after each file (may be NULL)
 *   log_fn           — called for log/error messages (may be NULL)
 *   callback_ctx     — opaque pointer passed to callbacks
 *
 * Returns EXIT_OK on success, EXIT_IO on failure.
 */
static int blar_extract_to_dir(
    const uint8_t *buf, size_t buf_len,
    const char *output_dir,
    const blar_codec_registry_t *codec_registry,
    blar_extract_progress_fn progress_fn,
    blar_extract_log_fn log_fn,
    void *callback_ctx)
{
    /* Helper macro: format + log */
    #define EXTRACT_LOG(...) do { \
        if (log_fn) { \
            char _logbuf[2048]; \
            snprintf(_logbuf, sizeof(_logbuf), __VA_ARGS__); \
            log_fn(_logbuf, callback_ctx); \
        } \
    } while (0)

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        EXTRACT_LOG("extract: %s", blip_error_string(rc));
        return EXIT_IO;
    }

    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;
    uint64_t file_entries = 0; /* count of non-dir entries for progress */

    /* Container tracking: indices of container DIRs */
    uint64_t *container_indices = NULL;
    size_t container_count = 0;
    size_t container_cap = 0;

    /* ── Pass 1: create directories, count bytes for progress ────────── */
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            EXTRACT_LOG("extract: entry %llu: %s",
                    (unsigned long long)i, blip_error_string(rc));
            free(container_indices);
            return EXIT_IO;
        }

        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)path_len, path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                EXTRACT_LOG("extract: path too long");
                free(container_indices);
                return EXIT_IO;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                EXTRACT_LOG("extract: path too long");
                free(container_indices);
                return EXIT_IO;
            }
            memcpy(out_path, path, path_len);
            out_path[path_len] = '\0';
        }

        if (entry_type == 0x07) {
            /* Check if this is a container DIR */
            const char *co_type = NULL;
            size_t co_type_len = 0;
            bool is_container = false;
            if (blip_archive_entry_container_type(buf, buf_len, i,
                    &co_type, &co_type_len) == BLIP_OK && co_type != NULL) {
                is_container = true;
                /* Track this container for pass 3 */
                if (container_count >= container_cap) {
                    size_t new_cap = container_cap == 0 ? 16 : container_cap * 2;
                    uint64_t *new_arr = realloc(container_indices, new_cap * sizeof(uint64_t));
                    if (!new_arr) {
                        free(container_indices);
                        return EXIT_IO;
                    }
                    container_indices = new_arr;
                    container_cap = new_cap;
                }
                container_indices[container_count++] = i;
            }

            /* Check if this DIR is a child of an existing container DIR */
            if (!is_container) {
                bool in_container = false;
                for (size_t cci = 0; cci < container_count; cci++) {
                    const char *co_path = NULL;
                    size_t co_path_len = 0;
                    if (blip_archive_file_path(buf, buf_len, container_indices[cci],
                            &co_path, &co_path_len) == BLIP_OK) {
                        if (path_len > co_path_len + 1 &&
                            memcmp(path, co_path, co_path_len) == 0 &&
                            path[co_path_len] == '/') {
                            in_container = true;
                            break;
                        }
                    }
                }
                if (in_container) continue; /* skip — will be inside re-created zip */
            }

            if (!is_container) {
                /* Normal DIR entry: create directory */
                uint16_t mode = 0;
                int64_t mtime_ns = 0;
                const char *owner = NULL;
                size_t owner_len = 0;
                blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);

                if (!mkdirp(out_path)) {
                    EXTRACT_LOG("extract: cannot create directory '%s': %s",
                            out_path, strerror(errno));
                    free(container_indices);
                    return EXIT_IO;
                }
                if (mode != 0) {
                    chmod(out_path, mode);
                }

                /* Restore xattrs on directory */
                blip_xattr_entry *dir_xattrs = NULL;
                size_t dir_xattr_count = 0;
                uint8_t *dir_rfork = NULL;
                size_t dir_rfork_len = 0;
                if (blip_archive_entry_xattrs(buf, buf_len, i,
                        &dir_xattrs, &dir_xattr_count,
                        &dir_rfork, &dir_rfork_len) == BLIP_OK) {
                    if (dir_xattr_count > 0 || dir_rfork_len > 0) {
                        write_file_xattrs(out_path, dir_xattrs, dir_xattr_count,
                                           dir_rfork, dir_rfork_len);
                    }
                    blip_free_xattrs(dir_xattrs, dir_xattr_count,
                                      dir_rfork, dir_rfork_len);
                }
            }
            /* Container DIRs: skip creating directory (will become a file in pass 3).
             * Ensure parent directory exists though. */
            if (is_container) {
                if (!ensure_parent_dir(out_path)) {
                    EXTRACT_LOG("extract: cannot create parent dir for container '%s': %s",
                            out_path, strerror(errno));
                    free(container_indices);
                    return EXIT_IO;
                }
            }

            /* mtime for directories is set after all files are extracted */
        } else {
            /* FILE entry: count bytes for progress */
            uint8_t *data = NULL;
            size_t data_len = 0;
            if (blip_archive_file_content(buf, buf_len, i, &data, &data_len) == BLIP_OK) {
                total_bytes += data_len;
                blip_free_content(data, data_len);
            }
            file_entries++;
        }
    }

    /* Report initial progress with totals */
    if (progress_fn) progress_fn(0, 0, file_entries, total_bytes, callback_ctx);

    uint64_t files_done = 0;
    uint64_t failed = 0;

    /* ── Pass 2: extract files (resilient — continue on per-file errors) */
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);
        if (entry_type == 0x07) continue; /* skip DIR entries */

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc == BLIP_OK) {
            /* Skip files belonging to a container DIR */
            bool in_container = false;
            for (size_t cci = 0; cci < container_count; cci++) {
                const char *co_path = NULL;
                size_t co_path_len = 0;
                if (blip_archive_file_path(buf, buf_len, container_indices[cci],
                        &co_path, &co_path_len) == BLIP_OK) {
                    if (path_len > co_path_len + 1 &&
                        memcmp(path, co_path, co_path_len) == 0 &&
                        path[co_path_len] == '/') {
                        in_container = true;
                        break;
                    }
                }
            }
            if (in_container) continue;
        }
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            EXTRACT_LOG("\033[31mERROR: entry %llu: cannot read path: %s\033[0m",
                    (unsigned long long)i, blip_error_string(rc));
            failed++;
            continue;
        }

        uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            EXTRACT_LOG("\033[31mERROR: skipping '%.*s': %s\033[0m",
                    (int)path_len, path, blip_error_string(rc));
            failed++;
            continue;
        }

        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)path_len, path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                EXTRACT_LOG("\033[31mERROR: skipping '%.*s': path too long\033[0m",
                        (int)path_len, path);
                blip_free_content(data, data_len);
                failed++;
                continue;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                EXTRACT_LOG("\033[31mERROR: skipping '%.*s': path too long\033[0m",
                        (int)path_len, path);
                blip_free_content(data, data_len);
                failed++;
                continue;
            }
            memcpy(out_path, path, path_len);
            out_path[path_len] = '\0';
        }

        /* Ensure parent dirs exist (for implicit directories) */
        if (!ensure_parent_dir(out_path)) {
            EXTRACT_LOG("\033[31mERROR: skipping '%.*s': cannot create directory: %s\033[0m",
                    (int)path_len, path, strerror(errno));
            blip_free_content(data, data_len);
            failed++;
            continue;
        }

        if (!write_file(out_path, data, data_len)) {
            EXTRACT_LOG("\033[31mERROR: skipping '%.*s': cannot write: %s\033[0m",
                    (int)path_len, path, strerror(errno));
            blip_free_content(data, data_len);
            failed++;
            continue;
        }

        blip_free_content(data, data_len);

        /* Restore file mode and mtime */
        uint16_t mode = 0;
        int64_t mtime_ns = 0;
        const char *owner = NULL;
        size_t owner_len = 0;
        blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);

        if (mode != 0) {
            chmod(out_path, mode);
        }

        if (mtime_ns != 0) {
            struct timespec times[2];
            times[0].tv_sec = 0;
            times[0].tv_nsec = UTIME_OMIT; /* don't change atime */
            times[1].tv_sec = (time_t)(mtime_ns / 1000000000LL);
            times[1].tv_nsec = (long)(mtime_ns % 1000000000LL);
            utimensat(AT_FDCWD, out_path, times, 0);
        }

        /* Restore xattrs and resource fork */
        blip_xattr_entry *file_xattrs = NULL;
        size_t file_xattr_count = 0;
        uint8_t *file_rfork = NULL;
        size_t file_rfork_len = 0;
        if (blip_archive_entry_xattrs(buf, buf_len, i,
                &file_xattrs, &file_xattr_count,
                &file_rfork, &file_rfork_len) == BLIP_OK) {
            if (file_xattr_count > 0 || file_rfork_len > 0) {
                write_file_xattrs(out_path, file_xattrs, file_xattr_count,
                                   file_rfork, file_rfork_len);
            }
            blip_free_xattrs(file_xattrs, file_xattr_count,
                              file_rfork, file_rfork_len);
        }

        bytes_done += data_len;
        files_done++;
        if (progress_fn) progress_fn(files_done, bytes_done, file_entries, total_bytes, callback_ctx);
    }

    /* ── Pass 3: re-assemble container DIRs ──────────────────────────── */
    for (size_t ci = 0; ci < container_count; ci++) {
        uint64_t co_idx = container_indices[ci];
        const char *co_path = NULL;
        size_t co_path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, co_idx, &co_path, &co_path_len);
        if (rc != BLIP_OK) {
            EXTRACT_LOG("\033[31mERROR: container %llu: cannot read path: %s\033[0m",
                    (unsigned long long)co_idx, blip_error_string(rc));
            failed++;
            continue;
        }

        /* Detect container type */
        const char *co_type = NULL;
        size_t co_type_len = 0;
        blip_archive_entry_container_type(buf, buf_len, co_idx, &co_type, &co_type_len);

        /* Look up codec in registry; warn if unknown */
        const blar_codec_t *codec = co_type
            ? blar_codec_find_by_name(codec_registry, co_type, co_type_len)
            : NULL;
        if (co_type && !codec) {
            EXTRACT_LOG("warning: codec \"%.*s\" not found for container '%.*s', skipping reconstruction",
                    (int)co_type_len, co_type, (int)co_path_len, co_path);
            failed++;
            continue;
        }

        /* PDF container re-assembly */
        if (codec && strcmp(codec->name, "pdf") == 0) {
            /* Find __body__ child -> read shell */
            uint8_t *shell_data = NULL;
            size_t shell_len = 0;
            bool found_body = false;

            for (uint64_t j = 0; j < count; j++) {
                if (j == co_idx) continue;
                const char *j_path = NULL;
                size_t j_path_len = 0;
                if (blip_archive_file_path(buf, buf_len, j, &j_path, &j_path_len) != BLIP_OK)
                    continue;
                /* Check: {co_path}/__body__ */
                if (j_path_len == co_path_len + 9 &&
                    memcmp(j_path, co_path, co_path_len) == 0 &&
                    memcmp(j_path + co_path_len, "/__body__", 9) == 0) {
                    rc = blip_archive_file_content(buf, buf_len, j, &shell_data, &shell_len);
                    if (rc == BLIP_OK) found_body = true;
                    break;
                }
            }

            if (!found_body) {
                EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': no __body__ found\033[0m",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            /* Copy shell to mutable malloc'd buffer */
            uint8_t *pdf_buf = malloc(shell_len);
            if (!pdf_buf) {
                blip_free_content(shell_data, shell_len);
                failed++;
                continue;
            }
            memcpy(pdf_buf, shell_data, shell_len);
            blip_free_content(shell_data, shell_len);

            /* For each __img_*.jxl child: decode and splice back into shell */
            bool pdf_ok = true;

            /* Collect FlateDecode replacements for potential PDF rewrite */
            size_t flate_cap = 8;
            size_t flate_n = 0;
            uint64_t *fl_starts = calloc(flate_cap, sizeof(uint64_t));
            uint64_t *fl_orig_lens = calloc(flate_cap, sizeof(uint64_t));
            uint8_t **fl_new_datas = calloc(flate_cap, sizeof(uint8_t *));
            size_t *fl_new_lens = calloc(flate_cap, sizeof(size_t));
            bool need_rewrite = false;

            for (uint64_t j = 0; j < count && pdf_ok; j++) {
                if (j == co_idx) continue;
                const char *j_path = NULL;
                size_t j_path_len = 0;
                if (blip_archive_file_path(buf, buf_len, j, &j_path, &j_path_len) != BLIP_OK)
                    continue;
                if (j_path_len <= co_path_len + 1 ||
                    memcmp(j_path, co_path, co_path_len) != 0 ||
                    j_path[co_path_len] != '/')
                    continue;
                const char *inner = j_path + co_path_len + 1;
                size_t inner_len = j_path_len - co_path_len - 1;
                if (inner_len < 10 || memcmp(inner, "__img_", 6) != 0)
                    continue;
                if (inner_len < 5 || memcmp(inner + inner_len - 4, ".jxl", 4) != 0)
                    continue;

                /* Check jxl_source_format to determine handling */
                const char *jx_fmt = NULL;
                size_t jx_fmt_len = 0;
                blip_archive_entry_jxl_source(buf, buf_len, j, &jx_fmt, &jx_fmt_len);

                bool is_flate = (jx_fmt && jx_fmt_len == 5 && memcmp(jx_fmt, "flate", 5) == 0);

                /* Read po (offset) and pl (length) metadata */
                uint64_t po = UINT64_MAX, pl = UINT64_MAX;
                blip_archive_entry_pdf_offset(buf, buf_len, j, &po);
                blip_archive_entry_pdf_length(buf, buf_len, j, &pl);
                if (po == UINT64_MAX || pl == UINT64_MAX) {
                    EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': image '%.*s' missing po/pl metadata\033[0m",
                            (int)co_path_len, co_path, (int)inner_len, inner);
                    pdf_ok = false;
                    break;
                }

                /* Read JXL content */
                uint8_t *jxl_data = NULL;
                size_t jxl_len = 0;
                rc = blip_archive_file_content(buf, buf_len, j, &jxl_data, &jxl_len);
                if (rc != BLIP_OK) {
                    EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': cannot read '%.*s': %s\033[0m",
                            (int)co_path_len, co_path, (int)inner_len, inner, blip_error_string(rc));
                    pdf_ok = false;
                    break;
                }

                if (is_flate) {
                    /* FlateDecode: JXL -> pixels -> refilter -> zlib compress */
                    uint8_t *pixels = NULL;
                    size_t pixels_len = 0;
                    uint32_t px_w = 0, px_h = 0, px_ch = 0, px_bps = 0;
                    rc = blip_jxl_to_pixels(jxl_data, jxl_len, &pixels, &pixels_len,
                                            &px_w, &px_h, &px_ch, &px_bps);
                    blip_free_content(jxl_data, jxl_len);
                    if (rc != BLIP_OK) {
                        EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': JXL pixel decode failed for '%.*s'\033[0m",
                                (int)co_path_len, co_path, (int)inner_len, inner);
                        pdf_ok = false;
                        break;
                    }

                    /* Read flate metadata from archive entry */
                    uint16_t predictor = 15; /* default: per-row filter byte */
                    uint32_t columns = px_w;
                    uint8_t colors = (uint8_t)px_ch;
                    uint8_t bpc = (uint8_t)px_bps;

                    /* Refilter pixels */
                    uint8_t *filtered = NULL;
                    size_t filtered_len = 0;
                    rc = blip_pdf_refilter(pixels, pixels_len, columns, colors, bpc, predictor,
                                           &filtered, &filtered_len);
                    blip_free(pixels, pixels_len);
                    if (rc != BLIP_OK) {
                        EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': refilter failed for '%.*s'\033[0m",
                                (int)co_path_len, co_path, (int)inner_len, inner);
                        pdf_ok = false;
                        break;
                    }

                    /* Zlib compress */
                    uint8_t *compressed = NULL;
                    size_t compressed_len = 0;
                    rc = blip_zlib_compress(filtered, filtered_len, &compressed, &compressed_len);
                    blip_free(filtered, filtered_len);
                    if (rc != BLIP_OK) {
                        EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': zlib compress failed for '%.*s'\033[0m",
                                (int)co_path_len, co_path, (int)inner_len, inner);
                        pdf_ok = false;
                        break;
                    }

                    if (compressed_len == pl) {
                        /* Lucky: same size — direct splice */
                        if (po + pl <= shell_len) {
                            memcpy(pdf_buf + po, compressed, compressed_len);
                        }
                        blip_free(compressed, compressed_len);
                    } else {
                        /* Different size — collect for PDF rewrite */
                        need_rewrite = true;
                        /* Grow arrays if needed */
                        if (flate_n >= flate_cap) {
                            flate_cap *= 2;
                            fl_starts = realloc(fl_starts, flate_cap * sizeof(uint64_t));
                            fl_orig_lens = realloc(fl_orig_lens, flate_cap * sizeof(uint64_t));
                            fl_new_datas = realloc(fl_new_datas, flate_cap * sizeof(uint8_t *));
                            fl_new_lens = realloc(fl_new_lens, flate_cap * sizeof(size_t));
                        }
                        fl_starts[flate_n] = po;
                        fl_orig_lens[flate_n] = pl;
                        fl_new_datas[flate_n] = compressed; /* ownership transferred */
                        fl_new_lens[flate_n] = compressed_len;
                        flate_n++;
                    }
                } else {
                    /* JPEG: JXL -> JPEG (bit-exact, same size) */
                    uint8_t *jpeg_data = NULL;
                    size_t jpeg_len = 0;
                    rc = blip_jxl_to_jpeg(jxl_data, jxl_len, &jpeg_data, &jpeg_len);
                    blip_free_content(jxl_data, jxl_len);
                    if (rc != BLIP_OK) {
                        EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': JXL decode failed for '%.*s'\033[0m",
                                (int)co_path_len, co_path, (int)inner_len, inner);
                        pdf_ok = false;
                        break;
                    }

                    if (jpeg_len != pl) {
                        EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': JPEG length mismatch for '%.*s': "
                                "expected %llu, got %zu\033[0m",
                                (int)co_path_len, co_path, (int)inner_len, inner,
                                (unsigned long long)pl, jpeg_len);
                        blip_free(jpeg_data, jpeg_len);
                        pdf_ok = false;
                        break;
                    }

                    if (po + pl > shell_len) {
                        EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': offset+length exceeds shell for '%.*s'\033[0m",
                                (int)co_path_len, co_path, (int)inner_len, inner);
                        blip_free(jpeg_data, jpeg_len);
                        pdf_ok = false;
                        break;
                    }
                    memcpy(pdf_buf + po, jpeg_data, jpeg_len);
                    blip_free(jpeg_data, jpeg_len);
                }
            }

            /* If FlateDecode streams changed size, rewrite the PDF */
            if (pdf_ok && need_rewrite && flate_n > 0) {
                uint8_t *rewritten = NULL;
                size_t rewritten_len = 0;
                rc = blip_pdf_rewrite_streams(pdf_buf, shell_len, flate_n,
                    fl_starts, fl_orig_lens,
                    (const uint8_t *const *)fl_new_datas, fl_new_lens,
                    &rewritten, &rewritten_len);
                if (rc == BLIP_OK) {
                    free(pdf_buf);
                    pdf_buf = malloc(rewritten_len);
                    if (pdf_buf) {
                        memcpy(pdf_buf, rewritten, rewritten_len);
                    } else {
                        pdf_buf = rewritten;
                        rewritten = NULL;
                    }
                    shell_len = rewritten_len;
                    if (rewritten) blip_free(rewritten, rewritten_len);
                } else if (rc == BLIP_ERR_XREF_STREAM) {
                    EXTRACT_LOG("WARNING: PDF '%.*s': xref stream PDF, "
                            "FlateDecode images left as zeroed regions",
                            (int)co_path_len, co_path);
                } else {
                    EXTRACT_LOG("WARNING: PDF '%.*s': rewrite failed (rc=%d), "
                            "FlateDecode images may be missing",
                            (int)co_path_len, co_path, rc);
                }
            }

            /* Free FlateDecode replacement data */
            for (size_t fi = 0; fi < flate_n; fi++) {
                blip_free(fl_new_datas[fi], fl_new_lens[fi]);
            }
            free(fl_starts);
            free(fl_orig_lens);
            free(fl_new_datas);
            free(fl_new_lens);

            if (!pdf_ok) {
                free(pdf_buf);
                failed++;
                continue;
            }

            /* ── Recompress content streams ── */
            {
                uint64_t cs_count = 0;
                uint64_t *cs_offs = NULL, *cs_lens = NULL;
                if (blip_pdf_content_streams(pdf_buf, shell_len, &cs_count,
                        &cs_offs, &cs_lens) == BLIP_OK && cs_count > 0)
                {
                    size_t cs_rep_n = 0;
                    uint64_t *cs_starts = calloc(cs_count, sizeof(uint64_t));
                    uint64_t *cs_orig = calloc(cs_count, sizeof(uint64_t));
                    uint8_t **cs_datas = calloc(cs_count, sizeof(uint8_t *));
                    size_t *cs_sizes = calloc(cs_count, sizeof(size_t));

                    if (cs_starts && cs_orig && cs_datas && cs_sizes) {
                        for (uint64_t csi = 0; csi < cs_count; csi++) {
                            const uint8_t *sdata = pdf_buf + cs_offs[csi];
                            size_t slen = (size_t)cs_lens[csi];
                            if (slen >= 2 && (sdata[0] & 0x0F) == 0x08 &&
                                ((uint16_t)sdata[0] * 256 + sdata[1]) % 31 == 0)
                                continue;
                            uint8_t *compressed = NULL;
                            size_t compressed_len = 0;
                            if (blip_zlib_compress(sdata, slen,
                                    &compressed, &compressed_len) == BLIP_OK)
                            {
                                cs_starts[cs_rep_n] = cs_offs[csi];
                                cs_orig[cs_rep_n] = cs_lens[csi];
                                cs_datas[cs_rep_n] = compressed;
                                cs_sizes[cs_rep_n] = compressed_len;
                                cs_rep_n++;
                            }
                        }

                        if (cs_rep_n > 0) {
                            uint8_t *recomp = NULL;
                            size_t recomp_len = 0;
                            int32_t cs_rc = blip_pdf_rewrite_streams(pdf_buf, shell_len,
                                cs_rep_n, cs_starts, cs_orig,
                                (const uint8_t *const *)cs_datas, cs_sizes,
                                &recomp, &recomp_len);
                            if (cs_rc == BLIP_OK) {
                                free(pdf_buf);
                                pdf_buf = malloc(recomp_len);
                                if (pdf_buf) {
                                    memcpy(pdf_buf, recomp, recomp_len);
                                } else {
                                    pdf_buf = recomp;
                                    recomp = NULL;
                                }
                                shell_len = recomp_len;
                                if (recomp) blip_free(recomp, recomp_len);
                            }
                            for (size_t csi = 0; csi < cs_rep_n; csi++)
                                blip_free(cs_datas[csi], cs_sizes[csi]);
                        }
                    }

                    free(cs_starts); free(cs_orig);
                    free(cs_datas); free(cs_sizes);
                    blip_free((uint8_t *)cs_offs, cs_count * sizeof(*cs_offs));
                    blip_free((uint8_t *)cs_lens, cs_count * sizeof(*cs_lens));
                }
            }

            /* Write the reconstructed PDF */
            char out_path[4096];
            if (output_dir) {
                int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                                 output_dir, (int)co_path_len, co_path);
                if (n < 0 || (size_t)n >= sizeof(out_path)) {
                    free(pdf_buf);
                    failed++;
                    continue;
                }
            } else {
                if (co_path_len >= sizeof(out_path)) {
                    free(pdf_buf);
                    failed++;
                    continue;
                }
                memcpy(out_path, co_path, co_path_len);
                out_path[co_path_len] = '\0';
            }

            if (!ensure_parent_dir(out_path)) {
                EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': cannot create parent dir: %s\033[0m",
                        (int)co_path_len, co_path, strerror(errno));
                free(pdf_buf);
                failed++;
                continue;
            }

            if (!write_file(out_path, pdf_buf, shell_len)) {
                EXTRACT_LOG("\033[31mERROR: PDF container '%.*s': cannot write: %s\033[0m",
                        (int)co_path_len, co_path, strerror(errno));
                free(pdf_buf);
                failed++;
                continue;
            }
            free(pdf_buf);

            /* Restore metadata */
            uint16_t co_mode = 0;
            int64_t co_mtime_ns = 0;
            const char *co_owner = NULL;
            size_t co_owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, co_idx, &co_mode, &co_mtime_ns, &co_owner, &co_owner_len);
            if (co_mode != 0) chmod(out_path, co_mode);
            if (co_mtime_ns != 0) {
                struct timespec times[2];
                times[0].tv_sec = 0;
                times[0].tv_nsec = UTIME_OMIT;
                times[1].tv_sec = (time_t)(co_mtime_ns / 1000000000LL);
                times[1].tv_nsec = (long)(co_mtime_ns % 1000000000LL);
                utimensat(AT_FDCWD, out_path, times, 0);
            }

            blip_xattr_entry *co_xattrs = NULL;
            size_t co_xattr_count = 0;
            uint8_t *co_rfork = NULL;
            size_t co_rfork_len = 0;
            if (blip_archive_entry_xattrs(buf, buf_len, co_idx,
                    &co_xattrs, &co_xattr_count,
                    &co_rfork, &co_rfork_len) == BLIP_OK) {
                if (co_xattr_count > 0 || co_rfork_len > 0)
                    write_file_xattrs(out_path, co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
                blip_free_xattrs(co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
            }

            files_done++;
            if (progress_fn) progress_fn(files_done, bytes_done, file_entries, total_bytes, callback_ctx);
            continue;
        }

        /* JPEG container re-assembly */
        if (codec && strcmp(codec->name, "jpeg") == 0) {
            uint8_t *jxl_data = NULL;
            size_t jxl_data_len = 0;
            bool found_body = false;

            for (uint64_t j = 0; j < count; j++) {
                if (j == co_idx) continue;
                const char *j_path = NULL;
                size_t j_path_len = 0;
                if (blip_archive_file_path(buf, buf_len, j, &j_path, &j_path_len) != BLIP_OK)
                    continue;
                if (j_path_len <= co_path_len + 1 ||
                    memcmp(j_path, co_path, co_path_len) != 0 ||
                    j_path[co_path_len] != '/')
                    continue;
                const char *inner = j_path + co_path_len + 1;
                size_t inner_len = j_path_len - co_path_len - 1;

                if (inner_len == 12 && memcmp(inner, "__body__.jxl", 12) == 0) {
                    rc = blip_archive_file_content(buf, buf_len, j, &jxl_data, &jxl_data_len);
                    if (rc == BLIP_OK) found_body = true;
                }
            }

            if (!found_body) {
                EXTRACT_LOG("\033[31mERROR: JPEG container '%.*s': missing __body__.jxl\033[0m",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            uint8_t *jpeg_data = NULL;
            size_t jpeg_len = 0;
            rc = blip_jxl_to_jpeg(jxl_data, jxl_data_len, &jpeg_data, &jpeg_len);
            blip_free_content(jxl_data, jxl_data_len);
            if (rc != BLIP_OK) {
                EXTRACT_LOG("\033[31mERROR: JPEG container '%.*s': JXL -> JPEG decode failed\033[0m",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            char out_path[4096];
            if (output_dir) {
                int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                                 output_dir, (int)co_path_len, co_path);
                if (n < 0 || (size_t)n >= sizeof(out_path)) {
                    blip_free(jpeg_data, jpeg_len);
                    failed++;
                    continue;
                }
            } else {
                if (co_path_len >= sizeof(out_path)) {
                    blip_free(jpeg_data, jpeg_len);
                    failed++;
                    continue;
                }
                memcpy(out_path, co_path, co_path_len);
                out_path[co_path_len] = '\0';
            }

            if (!ensure_parent_dir(out_path)) {
                EXTRACT_LOG("\033[31mERROR: JPEG container '%.*s': cannot create parent dir: %s\033[0m",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(jpeg_data, jpeg_len);
                failed++;
                continue;
            }

            if (!write_file(out_path, jpeg_data, jpeg_len)) {
                EXTRACT_LOG("\033[31mERROR: JPEG container '%.*s': cannot write: %s\033[0m",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(jpeg_data, jpeg_len);
                failed++;
                continue;
            }
            blip_free(jpeg_data, jpeg_len);

            uint16_t co_mode = 0;
            int64_t co_mtime_ns = 0;
            const char *co_owner = NULL;
            size_t co_owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, co_idx, &co_mode, &co_mtime_ns, &co_owner, &co_owner_len);
            if (co_mode != 0) chmod(out_path, co_mode);
            if (co_mtime_ns != 0) {
                struct timespec times[2];
                times[0].tv_sec = 0;
                times[0].tv_nsec = UTIME_OMIT;
                times[1].tv_sec = co_mtime_ns / 1000000000LL;
                times[1].tv_nsec = co_mtime_ns % 1000000000LL;
                utimensat(AT_FDCWD, out_path, times, 0);
            }

            blip_xattr_entry *co_xattrs = NULL;
            size_t co_xattr_count = 0;
            uint8_t *co_rfork = NULL;
            size_t co_rfork_len = 0;
            if (blip_archive_entry_xattrs(buf, buf_len, co_idx,
                    &co_xattrs, &co_xattr_count,
                    &co_rfork, &co_rfork_len) == BLIP_OK) {
                if (co_xattr_count > 0 || co_rfork_len > 0)
                    write_file_xattrs(out_path, co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
                blip_free_xattrs(co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
            }

            files_done++;
            if (progress_fn) progress_fn(files_done, bytes_done, file_entries, total_bytes, callback_ctx);
            continue;
        }

        /* PNG container re-assembly */
        if (codec && strcmp(codec->name, "png") == 0) {
            uint8_t *meta_data = NULL;
            size_t meta_data_len = 0;
            uint8_t *jxl_data = NULL;
            size_t jxl_data_len = 0;
            bool found_meta = false, found_pixels = false;

            for (uint64_t j = 0; j < count; j++) {
                if (j == co_idx) continue;
                const char *j_path = NULL;
                size_t j_path_len = 0;
                if (blip_archive_file_path(buf, buf_len, j, &j_path, &j_path_len) != BLIP_OK)
                    continue;
                if (j_path_len <= co_path_len + 1 ||
                    memcmp(j_path, co_path, co_path_len) != 0 ||
                    j_path[co_path_len] != '/')
                    continue;
                const char *inner = j_path + co_path_len + 1;
                size_t inner_len = j_path_len - co_path_len - 1;

                if (inner_len == 8 && memcmp(inner, "__meta__", 8) == 0) {
                    rc = blip_archive_file_content(buf, buf_len, j, &meta_data, &meta_data_len);
                    if (rc == BLIP_OK) found_meta = true;
                } else if (inner_len == 14 && memcmp(inner, "__pixels__.jxl", 14) == 0) {
                    rc = blip_archive_file_content(buf, buf_len, j, &jxl_data, &jxl_data_len);
                    if (rc == BLIP_OK) found_pixels = true;
                }
            }

            if (!found_meta || !found_pixels) {
                EXTRACT_LOG("\033[31mERROR: PNG container '%.*s': missing %s%s%s\033[0m",
                        (int)co_path_len, co_path,
                        found_meta ? "" : "__meta__",
                        (!found_meta && !found_pixels) ? " and " : "",
                        found_pixels ? "" : "__pixels__.jxl");
                if (meta_data) blip_free_content(meta_data, meta_data_len);
                if (jxl_data) blip_free_content(jxl_data, jxl_data_len);
                failed++;
                continue;
            }

            uint8_t *pixels = NULL;
            size_t pixels_len = 0;
            uint32_t width = 0, height = 0, num_channels = 0, bits_per_sample = 0;
            rc = blip_jxl_to_pixels(jxl_data, jxl_data_len,
                    &pixels, &pixels_len, &width, &height,
                    &num_channels, &bits_per_sample);
            blip_free_content(jxl_data, jxl_data_len);
            if (rc != BLIP_OK) {
                EXTRACT_LOG("\033[31mERROR: PNG container '%.*s': JXL decode failed\033[0m",
                        (int)co_path_len, co_path);
                blip_free_content(meta_data, meta_data_len);
                failed++;
                continue;
            }

            uint8_t *png_data = NULL;
            size_t png_len = 0;
            rc = blip_png_encode(pixels, pixels_len,
                    width, height, num_channels, bits_per_sample,
                    meta_data, meta_data_len,
                    &png_data, &png_len);
            blip_free(pixels, pixels_len);
            blip_free_content(meta_data, meta_data_len);
            if (rc != BLIP_OK) {
                EXTRACT_LOG("\033[31mERROR: PNG container '%.*s': PNG encode failed\033[0m",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            char out_path[4096];
            if (output_dir) {
                int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                                 output_dir, (int)co_path_len, co_path);
                if (n < 0 || (size_t)n >= sizeof(out_path)) {
                    blip_free(png_data, png_len);
                    failed++;
                    continue;
                }
            } else {
                if (co_path_len >= sizeof(out_path)) {
                    blip_free(png_data, png_len);
                    failed++;
                    continue;
                }
                memcpy(out_path, co_path, co_path_len);
                out_path[co_path_len] = '\0';
            }

            if (!ensure_parent_dir(out_path)) {
                EXTRACT_LOG("\033[31mERROR: PNG container '%.*s': cannot create parent dir: %s\033[0m",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(png_data, png_len);
                failed++;
                continue;
            }

            if (!write_file(out_path, png_data, png_len)) {
                EXTRACT_LOG("\033[31mERROR: PNG container '%.*s': cannot write: %s\033[0m",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(png_data, png_len);
                failed++;
                continue;
            }
            blip_free(png_data, png_len);

            uint16_t co_mode = 0;
            int64_t co_mtime_ns = 0;
            const char *co_owner = NULL;
            size_t co_owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, co_idx, &co_mode, &co_mtime_ns, &co_owner, &co_owner_len);
            if (co_mode != 0) chmod(out_path, co_mode);
            if (co_mtime_ns != 0) {
                struct timespec times[2];
                times[0].tv_sec = 0;
                times[0].tv_nsec = UTIME_OMIT;
                times[1].tv_sec = co_mtime_ns / 1000000000LL;
                times[1].tv_nsec = co_mtime_ns % 1000000000LL;
                utimensat(AT_FDCWD, out_path, times, 0);
            }

            blip_xattr_entry *co_xattrs = NULL;
            size_t co_xattr_count = 0;
            uint8_t *co_rfork = NULL;
            size_t co_rfork_len = 0;
            if (blip_archive_entry_xattrs(buf, buf_len, co_idx,
                    &co_xattrs, &co_xattr_count,
                    &co_rfork, &co_rfork_len) == BLIP_OK) {
                if (co_xattr_count > 0 || co_rfork_len > 0)
                    write_file_xattrs(out_path, co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
                blip_free_xattrs(co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
            }

            files_done++;
            if (progress_fn) progress_fn(files_done, bytes_done, file_entries, total_bytes, callback_ctx);
            continue;
        }

        /* ZIP container re-assembly — collect child entries */
        size_t child_cap = 32;
        size_t child_count = 0;
        blip_zip_write_entry *zip_entries = malloc(child_cap * sizeof(blip_zip_write_entry));
        size_t buf_cap_zip = child_cap * 2;
        uint8_t **child_bufs = malloc(buf_cap_zip * sizeof(uint8_t *));
        size_t child_buf_count = 0;
        if (!zip_entries || !child_bufs) {
            free(zip_entries);
            free(child_bufs);
            failed++;
            continue;
        }

        bool container_ok = true;
        for (uint64_t j = 0; j < count && container_ok; j++) {
            if (j == co_idx) continue;
            const char *j_path = NULL;
            size_t j_path_len = 0;
            if (blip_archive_file_path(buf, buf_len, j, &j_path, &j_path_len) != BLIP_OK)
                continue;

            if (j_path_len <= co_path_len + 1 ||
                memcmp(j_path, co_path, co_path_len) != 0 ||
                j_path[co_path_len] != '/') {
                continue;
            }

            const char *inner_path = j_path + co_path_len + 1;
            size_t inner_path_len = j_path_len - co_path_len - 1;

            uint8_t j_type = 0;
            blip_archive_entry_type(buf, buf_len, j, &j_type);

            uint16_t j_mode = 0;
            int64_t j_mtime_ns = 0;
            const char *j_owner = NULL;
            size_t j_owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, j, &j_mode, &j_mtime_ns, &j_owner, &j_owner_len);
            uint16_t dos_time = 0, dos_date = 0;
            ns_to_msdos(j_mtime_ns, &dos_time, &dos_date);

            if (child_count >= child_cap || child_buf_count + 2 >= buf_cap_zip) {
                child_cap *= 2;
                buf_cap_zip = child_cap * 2;
                blip_zip_write_entry *new_ze = realloc(zip_entries, child_cap * sizeof(blip_zip_write_entry));
                uint8_t **new_cb = realloc(child_bufs, buf_cap_zip * sizeof(uint8_t *));
                if (!new_ze || !new_cb) {
                    if (new_ze) zip_entries = new_ze;
                    if (new_cb) child_bufs = new_cb;
                    container_ok = false;
                    break;
                }
                zip_entries = new_ze;
                child_bufs = new_cb;
            }

            if (j_type == 0x07) {
                char *dir_name = malloc(inner_path_len + 2);
                if (!dir_name) { container_ok = false; break; }
                memcpy(dir_name, inner_path, inner_path_len);
                if (inner_path_len == 0 || inner_path[inner_path_len - 1] != '/') {
                    dir_name[inner_path_len] = '/';
                    dir_name[inner_path_len + 1] = '\0';
                    inner_path_len++;
                } else {
                    dir_name[inner_path_len] = '\0';
                }

                child_bufs[child_buf_count++] = (uint8_t *)dir_name;
                blip_zip_write_entry ze;
                memset(&ze, 0, sizeof(ze));
                ze.filename = dir_name;
                ze.filename_len = inner_path_len;
                ze.content = NULL;
                ze.content_len = 0;
                ze.compression_method = 0;
                ze.mtime = dos_time;
                ze.mdate = dos_date;
                ze.external_attributes = 0x10 << 16;
                zip_entries[child_count++] = ze;
            } else {
                uint8_t *data = NULL;
                size_t data_len = 0;
                rc = blip_archive_file_content(buf, buf_len, j, &data, &data_len);
                if (rc != BLIP_OK) {
                    EXTRACT_LOG("\033[31mERROR: container child '%.*s': %s\033[0m",
                            (int)j_path_len, j_path, blip_error_string(rc));
                    container_ok = false;
                    break;
                }

                uint8_t *owned = malloc(data_len > 0 ? data_len : 1);
                if (!owned) {
                    blip_free_content(data, data_len);
                    container_ok = false;
                    break;
                }
                if (data_len > 0) memcpy(owned, data, data_len);
                blip_free_content(data, data_len);
                child_bufs[child_buf_count++] = owned;

                char *fname = strndup(inner_path, inner_path_len);
                if (!fname) { container_ok = false; break; }
                child_bufs[child_buf_count++] = (uint8_t *)fname;

                uint16_t zc_method = 0;
                blip_archive_entry_zip_comp(buf, buf_len, j, &zc_method);
                if (zc_method == 0xFFFF) zc_method = 8;

                blip_zip_write_entry ze;
                memset(&ze, 0, sizeof(ze));
                ze.filename = fname;
                ze.filename_len = inner_path_len;
                ze.content = owned;
                ze.content_len = data_len;
                ze.compression_method = zc_method;
                ze.mtime = dos_time;
                ze.mdate = dos_date;
                ze.external_attributes = 0;
                zip_entries[child_count++] = ze;
            }
        }

        if (!container_ok || child_count == 0) {
            for (size_t k = 0; k < child_buf_count; k++) free(child_bufs[k]);
            free(child_bufs);
            free(zip_entries);
            if (!container_ok) failed++;
            continue;
        }

        uint8_t *zip_buf_out = NULL;
        size_t zip_len = 0;
        rc = blip_zip_create(zip_entries, child_count, &zip_buf_out, &zip_len);

        for (size_t k = 0; k < child_buf_count; k++) free(child_bufs[k]);
        free(child_bufs);
        free(zip_entries);

        if (rc != BLIP_OK) {
            EXTRACT_LOG("\033[31mERROR: container '%.*s': zip creation failed: %s\033[0m",
                    (int)co_path_len, co_path, blip_error_string(rc));
            failed++;
            continue;
        }

        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)co_path_len, co_path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                EXTRACT_LOG("\033[31mERROR: container '%.*s': path too long\033[0m",
                        (int)co_path_len, co_path);
                blip_free(zip_buf_out, zip_len);
                failed++;
                continue;
            }
        } else {
            if (co_path_len >= sizeof(out_path)) {
                blip_free(zip_buf_out, zip_len);
                failed++;
                continue;
            }
            memcpy(out_path, co_path, co_path_len);
            out_path[co_path_len] = '\0';
        }

        if (!ensure_parent_dir(out_path)) {
            EXTRACT_LOG("\033[31mERROR: container '%.*s': cannot create parent dir: %s\033[0m",
                    (int)co_path_len, co_path, strerror(errno));
            blip_free(zip_buf_out, zip_len);
            failed++;
            continue;
        }

        uint8_t *write_buf = malloc(zip_len);
        if (write_buf) {
            memcpy(write_buf, zip_buf_out, zip_len);
        }
        blip_free(zip_buf_out, zip_len);
        if (!write_buf) { failed++; continue; }

        if (!write_file(out_path, write_buf, zip_len)) {
            EXTRACT_LOG("\033[31mERROR: container '%.*s': cannot write: %s\033[0m",
                    (int)co_path_len, co_path, strerror(errno));
            free(write_buf);
            failed++;
            continue;
        }
        free(write_buf);

        uint16_t co_mode = 0;
        int64_t co_mtime_ns = 0;
        const char *co_owner = NULL;
        size_t co_owner_len = 0;
        blip_archive_entry_metadata(buf, buf_len, co_idx, &co_mode, &co_mtime_ns, &co_owner, &co_owner_len);

        if (co_mode != 0) {
            chmod(out_path, co_mode);
        }
        if (co_mtime_ns != 0) {
            struct timespec times[2];
            times[0].tv_sec = 0;
            times[0].tv_nsec = UTIME_OMIT;
            times[1].tv_sec = (time_t)(co_mtime_ns / 1000000000LL);
            times[1].tv_nsec = (long)(co_mtime_ns % 1000000000LL);
            utimensat(AT_FDCWD, out_path, times, 0);
        }

        blip_xattr_entry *co_xattrs = NULL;
        size_t co_xattr_count = 0;
        uint8_t *co_rfork = NULL;
        size_t co_rfork_len = 0;
        if (blip_archive_entry_xattrs(buf, buf_len, co_idx,
                &co_xattrs, &co_xattr_count,
                &co_rfork, &co_rfork_len) == BLIP_OK) {
            if (co_xattr_count > 0 || co_rfork_len > 0) {
                write_file_xattrs(out_path, co_xattrs, co_xattr_count,
                                   co_rfork, co_rfork_len);
            }
            blip_free_xattrs(co_xattrs, co_xattr_count,
                              co_rfork, co_rfork_len);
        }

        files_done++;
        if (progress_fn) progress_fn(files_done, bytes_done, file_entries, total_bytes, callback_ctx);
    }

    free(container_indices);

    if (failed > 0) {
        EXTRACT_LOG("\n%llu extracted, %llu failed",
                (unsigned long long)files_done, (unsigned long long)failed);
        return EXIT_IO;
    }
    return EXIT_OK;

    #undef EXTRACT_LOG
}

#endif /* BLAR_COMMON_H */
