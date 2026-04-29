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
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>

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
/* If `*bufp`/`*lenp` is a SEGMENT container, header-scan the parent directory
 * of `path`, reassemble all matching segments (stream_id=0), free the original
 * buffer, and replace `*bufp`/`*lenp` with malloc'd bytes of the reassembled
 * payload.  Returns true on success (including the "not a segment" no-op case),
 * false on reassembly failure. */
static bool maybe_reassemble_segments(uint8_t **bufp, size_t *lenp, const char *path) {
    if (!*bufp || *lenp == 0) return true;
    if (blip_segment_is_segment(*bufp, *lenp) != 1) return true;

    /* Find the directory containing `path`. */
    char dirbuf[4096];
    const char *last_slash = strrchr(path, '/');
    if (last_slash) {
        size_t dlen = (size_t)(last_slash - path);
        if (dlen >= sizeof(dirbuf)) dlen = sizeof(dirbuf) - 1;
        memcpy(dirbuf, path, dlen);
        dirbuf[dlen] = '\0';
    } else {
        dirbuf[0] = '.';
        dirbuf[1] = '\0';
    }

    DIR *dir = opendir(dirbuf[0] ? dirbuf : ".");
    if (!dir) {
        fprintf(stderr, "Cannot open directory '%s' for segment reassembly: %s\n",
                dirbuf, strerror(errno));
        return false;
    }

    blip_segment_t *segs = NULL;
    size_t seg_cap = 0, seg_count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        char full[4096];
        snprintf(full, sizeof(full), "%s/%s", dirbuf, name);
        struct stat st;
        if (stat(full, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        size_t flen = 0;
        uint8_t *fbuf = read_file(full, &flen);
        if (!fbuf) continue;
        if (blip_segment_is_segment(fbuf, flen) != 1) {
            free(fbuf);
            continue;
        }
        if (seg_count >= seg_cap) {
            seg_cap = seg_cap ? seg_cap * 2 : 8;
            blip_segment_t *new_segs = (blip_segment_t *)realloc(segs, seg_cap * sizeof(*segs));
            if (!new_segs) {
                free(fbuf);
                for (size_t i = 0; i < seg_count; i++) free(segs[i].data);
                free(segs);
                closedir(dir);
                fprintf(stderr, "Out of memory during segment reassembly\n");
                return false;
            }
            segs = new_segs;
        }
        segs[seg_count].data = fbuf;
        segs[seg_count].len = flen;
        seg_count++;
    }
    closedir(dir);

    if (seg_count == 0) {
        fprintf(stderr, "No SEGMENT containers found in '%s'\n", dirbuf);
        return false;
    }

    uint8_t *out_data = NULL;
    size_t out_len = 0;
    int32_t rc = blip_segment_reassemble(segs, seg_count, /* expected_stream_id */ 0,
                                          &out_data, &out_len);
    for (size_t i = 0; i < seg_count; i++) free(segs[i].data);
    free(segs);

    if (rc != BLIP_OK) {
        fprintf(stderr, "Segment reassembly failed: %s\n", blip_error_string(rc));
        return false;
    }

    /* Copy into malloc'd buffer so callers can free() uniformly. */
    uint8_t *copy = (uint8_t *)malloc(out_len);
    if (!copy) {
        blip_free(out_data, out_len);
        fprintf(stderr, "Out of memory copying reassembled archive\n");
        return false;
    }
    memcpy(copy, out_data, out_len);
    blip_free(out_data, out_len);

    free(*bufp);
    *bufp = copy;
    *lenp = out_len;
    return true;
}

static uint8_t *read_archive(const char *path, size_t *out_len) {
    uint8_t *buf = read_file(path, out_len);
    if (!buf) return NULL;

    /* Auto-reassemble if `path` is a single SEGMENT (header-scan its directory). */
    if (!maybe_reassemble_segments(&buf, out_len, path)) {
        free(buf);
        return NULL;
    }

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


        /* Try Zig-based collapse for migrated formats */
        {
            static const char *zig_collapse_codecs[] = {
                "bmp", "tga", "tiff", "png", "gif", "fits", "dicom", "nifti", "wav", "aiff", "gz", "tar", "jpeg", "zip", NULL
            };
            bool is_zig_codec = false;
            for (const char **zc = zig_collapse_codecs; *zc; zc++) {
                if (co_type && strlen(*zc) == co_type_len && memcmp(*zc, co_type, co_type_len) == 0) {
                    is_zig_codec = true; break;
                }
            }

            if (is_zig_codec) {
                /* Collect all child entries for this container */
                size_t child_cap = 8;
                size_t child_n = 0;
                const char **child_paths_arr = malloc(child_cap * sizeof(const char *));
                size_t *child_path_lens_arr = malloc(child_cap * sizeof(size_t));
                const uint8_t **child_contents_arr = malloc(child_cap * sizeof(const uint8_t *));
                size_t *child_content_lens_arr = malloc(child_cap * sizeof(size_t));
                uint8_t **child_data_ptrs = malloc(child_cap * sizeof(uint8_t *));
                uint64_t *child_pdf_offs = malloc(child_cap * sizeof(uint64_t));
                uint64_t *child_pdf_lens = malloc(child_cap * sizeof(uint64_t));
                uint16_t *child_zip_comps = malloc(child_cap * sizeof(uint16_t));
                const char **child_jxl_srcs = malloc(child_cap * sizeof(const char *));
                size_t *child_jxl_src_lens = malloc(child_cap * sizeof(size_t));

                if (!child_paths_arr || !child_path_lens_arr || !child_contents_arr || !child_content_lens_arr || !child_data_ptrs || !child_pdf_offs || !child_pdf_lens) {
                    free(child_paths_arr); free(child_path_lens_arr);
                    free(child_contents_arr); free(child_content_lens_arr); free(child_data_ptrs);
                    free(child_pdf_offs); free(child_pdf_lens); free(child_zip_comps);
                    free(child_jxl_srcs); free(child_jxl_src_lens);
                    failed++; continue;
                }

                for (uint64_t j = 0; j < count; j++) {
                    if (j == co_idx) continue;
                    const char *j_path = NULL; size_t j_path_len = 0;
                    if (blip_archive_file_path(buf, buf_len, j, &j_path, &j_path_len) != BLIP_OK) continue;
                    if (j_path_len <= co_path_len + 1 ||
                        memcmp(j_path, co_path, co_path_len) != 0 ||
                        j_path[co_path_len] != '/')
                        continue;
                    const char *inner = j_path + co_path_len + 1;
                    size_t inner_len = j_path_len - co_path_len - 1;

                    uint8_t *j_content = NULL; size_t j_content_len = 0;
                    rc = blip_archive_file_content(buf, buf_len, j, &j_content, &j_content_len);
                    if (rc != BLIP_OK) continue;

                    if (child_n >= child_cap) {
                        child_cap *= 2;
                        child_paths_arr = realloc(child_paths_arr, child_cap * sizeof(const char *));
                        child_path_lens_arr = realloc(child_path_lens_arr, child_cap * sizeof(size_t));
                        child_contents_arr = realloc(child_contents_arr, child_cap * sizeof(const uint8_t *));
                        child_content_lens_arr = realloc(child_content_lens_arr, child_cap * sizeof(size_t));
                        child_data_ptrs = realloc(child_data_ptrs, child_cap * sizeof(uint8_t *));
                        child_pdf_offs = realloc(child_pdf_offs, child_cap * sizeof(uint64_t));
                        child_pdf_lens = realloc(child_pdf_lens, child_cap * sizeof(uint64_t));
                        child_jxl_srcs = realloc(child_jxl_srcs, child_cap * sizeof(const char *));
                        child_jxl_src_lens = realloc(child_jxl_src_lens, child_cap * sizeof(size_t));
                        child_zip_comps = realloc(child_zip_comps, child_cap * sizeof(uint16_t));
                    }
                    child_paths_arr[child_n] = inner;
                    child_path_lens_arr[child_n] = inner_len;
                    child_contents_arr[child_n] = j_content;
                    child_content_lens_arr[child_n] = j_content_len;
                    child_data_ptrs[child_n] = j_content;
                    /* Collect PDF/JXL metadata for this child */
                    child_pdf_offs[child_n] = UINT64_MAX;
                    child_pdf_lens[child_n] = UINT64_MAX;
                    child_jxl_srcs[child_n] = "";
                    child_jxl_src_lens[child_n] = 0;

                    blip_archive_entry_pdf_offset(buf, buf_len, j, &child_pdf_offs[child_n]);
                    blip_archive_entry_pdf_length(buf, buf_len, j, &child_pdf_lens[child_n]);
                    {
                        const char *js = NULL; size_t js_len = 0;
                        blip_archive_entry_jxl_source(buf, buf_len, j, &js, &js_len);
                        if (js) { child_jxl_srcs[child_n] = js; child_jxl_src_lens[child_n] = js_len; }
                    }
                    {
                        uint16_t zc = 0xFFFF;
                        blip_archive_entry_zip_comp(buf, buf_len, j, &zc);
                        child_zip_comps[child_n] = zc;
                    }
                    child_n++;
                    /* Note: flate metadata (predictor/columns/colors/bpc) is passed
                     * through the blip_collapse_container FFI via CollapseChild fields */
                }

                uint8_t *result_data = NULL; size_t result_len = 0;
                int collapse_rc = blip_collapse_container(
                    co_type, co_type_len,
                    child_n,
                    child_paths_arr, child_path_lens_arr,
                    child_contents_arr, child_content_lens_arr,
                    child_pdf_offs, child_pdf_lens, child_zip_comps,
                    child_jxl_srcs, child_jxl_src_lens,
                    &result_data, &result_len
                );

                /* Free child content */
                for (size_t ci = 0; ci < child_n; ci++)
                    blip_free_content(child_data_ptrs[ci], child_content_lens_arr[ci]);
                free(child_paths_arr); free(child_path_lens_arr);
                free(child_contents_arr); free(child_content_lens_arr); free(child_data_ptrs);
                free(child_pdf_offs); free(child_pdf_lens); free(child_zip_comps);
                free(child_jxl_srcs); free(child_jxl_src_lens);

                if (collapse_rc != 0) {
                    EXTRACT_LOG("\033[31mERROR: container '%.*s' (%.*s): Zig collapse failed\033[0m",
                            (int)co_path_len, co_path, (int)co_type_len, co_type);
                    failed++; continue;
                }

                /* Write result */
                char out_path[4096];
                if (output_dir) {
                    int n = snprintf(out_path, sizeof(out_path), "%s/%.*s", output_dir, (int)co_path_len, co_path);
                    if (n < 0 || (size_t)n >= sizeof(out_path)) { blip_free(result_data, result_len); failed++; continue; }
                } else { memcpy(out_path, co_path, co_path_len); out_path[co_path_len] = '\0'; }

                if (!ensure_parent_dir(out_path) || !write_file(out_path, result_data, result_len)) {
                    blip_free(result_data, result_len); failed++; continue;
                }
                blip_free(result_data, result_len);

                /* Restore metadata */
                uint16_t co_mode = 0; int64_t co_mtime_ns = 0;
                const char *co_owner = NULL; size_t co_owner_len = 0;
                blip_archive_entry_metadata(buf, buf_len, co_idx, &co_mode, &co_mtime_ns, &co_owner, &co_owner_len);
                if (co_mode != 0) chmod(out_path, co_mode);
                if (co_mtime_ns != 0) {
                    struct timespec times[2];
                    times[0].tv_sec = 0; times[0].tv_nsec = UTIME_OMIT;
                    times[1].tv_sec = co_mtime_ns / 1000000000LL; times[1].tv_nsec = co_mtime_ns % 1000000000LL;
                    utimensat(AT_FDCWD, out_path, times, 0);
                }
                blip_xattr_entry *co_xattrs = NULL; size_t co_xattr_count = 0;
                uint8_t *co_rfork = NULL; size_t co_rfork_len = 0;
                if (blip_archive_entry_xattrs(buf, buf_len, co_idx, &co_xattrs, &co_xattr_count, &co_rfork, &co_rfork_len) == BLIP_OK) {
                    if (co_xattr_count > 0 || co_rfork_len > 0) write_file_xattrs(out_path, co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
                    blip_free_xattrs(co_xattrs, co_xattr_count, co_rfork, co_rfork_len);
                }
                files_done++;
                if (progress_fn) progress_fn(files_done, bytes_done, file_entries, total_bytes, callback_ctx);
                continue;
            }
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
    } /* end for (ci) */

    free(container_indices);

    if (failed > 0) {
        EXTRACT_LOG("\n%llu extracted, %llu failed",
                (unsigned long long)files_done, (unsigned long long)failed);
        return EXIT_IO;
    }
    return EXIT_OK;

    #undef EXTRACT_LOG
}

/* ── Entry collection for create ──────────────────────────────────────── */

typedef struct {
    blip_archive_entry *entries;
    size_t count;
    size_t capacity;
    uint8_t **content_bufs; /* owned content buffers to free */
    size_t content_count;
    size_t content_capacity;
    progrez_ctx *progress;  /* optional progress context (updated during collection) */
    uint64_t bytes_seen;    /* running total for progress updates */
    bool expand_containers; /* expand zip containers into DIR+FILE entries */
    bool expand_all_zips;   /* also expand .zip/.gz files (normally excluded) */
    uint8_t num_threads;    /* thread count for parallel work (0=auto) */
    bool metadata_only;     /* true: set source_path, skip read_file() */
    /* Generic progress callback (used by GUI — fires during expansion phase) */
    void (*expansion_progress_fn)(uint64_t done, uint64_t total, void *ctx);
    void *expansion_progress_ctx;
} entry_list_t;

static void entry_list_init(entry_list_t *el) {
    el->entries = NULL;
    el->count = 0;
    el->capacity = 0;
    el->content_bufs = NULL;
    el->content_count = 0;
    el->content_capacity = 0;
    el->progress = NULL;
    el->expansion_progress_fn = NULL;
    el->expansion_progress_ctx = NULL;
    el->bytes_seen = 0;
    el->expand_containers = false;
    el->expand_all_zips = false;
    el->num_threads = 0;
    el->metadata_only = false;
}

static bool entry_list_add(entry_list_t *el, blip_archive_entry entry) {
    if (el->count >= el->capacity) {
        size_t new_cap = el->capacity == 0 ? 64 : el->capacity * 2;
        blip_archive_entry *new_entries = realloc(el->entries, new_cap * sizeof(blip_archive_entry));
        if (!new_entries) return false;
        el->entries = new_entries;
        el->capacity = new_cap;
    }
    el->entries[el->count++] = entry;
    return true;
}

static bool entry_list_add_content(entry_list_t *el, uint8_t *buf) {
    if (el->content_count >= el->content_capacity) {
        size_t new_cap = el->content_capacity == 0 ? 64 : el->content_capacity * 2;
        uint8_t **new_bufs = realloc(el->content_bufs, new_cap * sizeof(uint8_t *));
        if (!new_bufs) return false;
        el->content_bufs = new_bufs;
        el->content_capacity = new_cap;
    }
    el->content_bufs[el->content_count++] = buf;
    return true;
}

static void entry_list_free(entry_list_t *el) {
    for (size_t i = 0; i < el->content_count; i++) {
        free(el->content_bufs[i]);
    }
    free(el->content_bufs);
    free(el->entries);
    el->entries = NULL;
    el->count = 0;
    el->capacity = 0;
    el->content_bufs = NULL;
    el->content_count = 0;
    el->content_capacity = 0;
}

/* ── Recursive directory walker ───────────────────────────────────────── */

/* Add a strdup'd path to the content list so it gets freed with entry_list_free. */
static char *entry_list_strdup(entry_list_t *el, const char *s) {
    char *dup = strdup(s);
    if (!dup) return NULL;
    if (!entry_list_add_content(el, (uint8_t *)dup)) {
        free(dup);
        return NULL;
    }
    return dup;
}

/* ── Zip container expansion helpers ──────────────────────────────────── */

/* Check if a file extension indicates an intentional archive (not a container). */
static bool is_archive_extension(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return false;
    dot++; /* skip the dot */
    /* Case-insensitive comparison */
    static const char *archive_exts[] = {
        "zip", "gz", "gzip", "tgz", "tar", "bz2", "xz", "7z", "rar", "lz4",
        "zst", "zstd", "blar", "lzma", "lzo", "cab", "arj", "z", NULL
    };
    for (const char **ext = archive_exts; *ext; ext++) {
        if (strcasecmp(dot, *ext) == 0) return true;
    }
    return false;
}

/* Convert MS-DOS date/time to nanoseconds since epoch. */
static int64_t msdos_to_ns(uint16_t dos_time, uint16_t dos_date) {
    if (dos_date == 0 && dos_time == 0) return 0;
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    tm.tm_sec  = (dos_time & 0x1F) * 2;
    tm.tm_min  = (dos_time >> 5) & 0x3F;
    tm.tm_hour = (dos_time >> 11) & 0x1F;
    tm.tm_mday = dos_date & 0x1F;
    tm.tm_mon  = ((dos_date >> 5) & 0x0F) - 1;
    tm.tm_year = ((dos_date >> 9) & 0x7F) + 80;
    tm.tm_isdst = -1;
    time_t t = mktime(&tm);
    if (t == (time_t)-1) return 0;
    return (int64_t)t * 1000000000LL;
}

/* Convert nanoseconds since epoch to MS-DOS date/time. */
/* Expand a zip container into DIR + FILE entries in the entry list.
 * Returns true on success, false on failure (caller should fall back to opaque). */
/* Expand a PDF file by extracting JPEG streams as JXL files.
 * Returns true on success, false on failure (caller should fall back to opaque). */
/* Context for parallel JPEG→JXL transcode workers */
typedef struct {
    const uint8_t *content;
    const uint64_t *offsets;
    const uint64_t *lengths;
    uint64_t jpeg_count;
    uint8_t **jxl_bufs;
    size_t *jxl_lens;
    _Atomic uint64_t next_idx;
} jxl_transcode_ctx_t;

static void *jxl_transcode_worker(void *arg) {
    jxl_transcode_ctx_t *ctx = (jxl_transcode_ctx_t *)arg;
    for (;;) {
        uint64_t i = atomic_fetch_add(&ctx->next_idx, 1);
        if (i >= ctx->jpeg_count) break;
        uint8_t *jxl_data = NULL;
        size_t jxl_len = 0;
        if (blip_jxl_from_jpeg(ctx->content + ctx->offsets[i],
                (size_t)ctx->lengths[i], &jxl_data, &jxl_len) == BLIP_OK) {
            ctx->jxl_bufs[i] = jxl_data;
            ctx->jxl_lens[i] = jxl_len;
        }
    }
    return NULL;
}

/* Expand a PNG file by decomposing into JXL lossless pixels + metadata.
 * Returns true on success, false on failure (caller should fall back to opaque). */
/* ── TAR container expansion ─────────────────────────────────────────── */

/* ── DICOM container expansion ───────────────────────────────────────── */

/* ── FITS container expansion ────────────────────────────────────────── */

/* ── AIFF container expansion (AIFF → FLAC) ─────────────────────────── */

/* ── WAV container expansion (WAV → FLAC) ────────────────────────────── */

/* ── TGA container expansion ─────────────────────────────────────────── */

/* ── GIF container expansion ─────────────────────────────────────────── */

/* ── TIFF container expansion ────────────────────────────────────────── */

/* ── BMP container expansion ─────────────────────────────────────────── */

/* ── JPEG container expansion ────────────────────────────────────────── */

static bool is_jpeg(const uint8_t *buf, size_t len) {
    return len >= 3 && buf[0] == 0xFF && buf[1] == 0xD8 && buf[2] == 0xFF;
}

/* Gzip container expansion: decompress for better LZMA2 compression,
 * recompress to gzip on extraction. NOTE: extraction produces
 * content-identical but NOT byte-identical gzip output - the original
 * compression level/strategy is not preserved in the gzip format.
 * zcat on both files produces identical output. */
/* Typed expand/collapse function pointer for blar.c (cast from void* in blar_codec_t) */

/* ── Builtin codec structs & registry ─────────────────────────────────── */

static const char *const jpeg_extensions[] = { ".jpg", ".jpeg", ".jpe", NULL };
static const char *const pdf_extensions[] = { ".pdf", NULL };
static const char *const png_extensions[] = { ".png", NULL };
static const char *const nifti_extensions[] = { ".nii", NULL };
static const char *const dicom_extensions[] = { ".dcm", ".dicom", ".dic", NULL };
static const char *const fits_extensions[] = { ".fits", ".fit", ".fts", NULL };
static const char *const aiff_extensions[] = { ".aiff", ".aif", ".aifc", NULL };
static const char *const wav_extensions[] = { ".wav", ".wave", NULL };
static const char *const tga_extensions[] = { ".tga", ".tpic", NULL };
static const char *const gif_extensions[] = { ".gif", NULL };
static const char *const tiff_extensions[] = { ".tiff", ".tif", NULL };
static const char *const tar_extensions[] = { ".tar", NULL };
static const char *const bmp_extensions[] = { ".bmp", ".dib", NULL };
static const char *const gz_extensions[] = { ".gz", ".gzip", NULL };
static const char *const zip_extensions[] = { ".zip", ".jar", ".war", ".ear", ".apk", ".aab",
                                              ".ipa", ".xpi", ".crx",
                                              ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp",
                                              ".ott", ".ots", ".otp",
                                              ".epub", ".cbz",
                                              ".3mf", ".amf", ".sketch", NULL };

static const blar_codec_t builtin_codecs[] = {
    {
        .name       = "jpeg",
        .extensions = jpeg_extensions,
        .detect     = is_jpeg,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "pdf",
        .extensions = pdf_extensions,
        .detect     = blip_is_pdf,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "png",
        .extensions = png_extensions,
        .detect     = blip_is_png,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "nifti",
        .extensions = nifti_extensions,
        .detect     = blip_is_nifti,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "dicom",
        .extensions = dicom_extensions,
        .detect     = blip_is_dicom,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "fits",
        .extensions = fits_extensions,
        .detect     = blip_is_fits,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "aiff",
        .extensions = aiff_extensions,
        .detect     = blip_is_aiff,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "wav",
        .extensions = wav_extensions,
        .detect     = blip_is_wav,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "tga",
        .extensions = tga_extensions,
        .detect     = blip_is_tga,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "gif",
        .extensions = gif_extensions,
        .detect     = blip_is_gif,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "tiff",
        .extensions = tiff_extensions,
        .detect     = blip_is_tiff,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "tar",
        .extensions = tar_extensions,
        .detect     = blip_is_tar,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "bmp",
        .extensions = bmp_extensions,
        .detect     = blip_is_bmp,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "gz",
        .extensions = gz_extensions,
        .detect     = blip_is_gz,
        .expand     = NULL,
        .collapse   = NULL,
    },
    {
        .name       = "zip",
        .extensions = zip_extensions,
        .detect     = blip_is_zip,
        .expand     = NULL,
        .collapse   = NULL,
    },
};

static const blar_codec_registry_t builtin_registry = {
    .codecs = builtin_codecs,
    .count  = sizeof(builtin_codecs) / sizeof(builtin_codecs[0]),
};


/* Collect entries recording only metadata + disk paths (no file content loaded).
 * For use with the streaming archive creation path. */
static bool collect_entries_metadata_recurse(const char *path, entry_list_t *el);

static bool collect_metadata_dir_children(const char *path, entry_list_t *el) {
    DIR *dir = opendir(path);
    if (!dir) return false;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
        char child_path[4096];
        size_t plen = strlen(path);
        while (plen > 0 && path[plen - 1] == '/') plen--;
        int n = snprintf(child_path, sizeof(child_path), "%.*s/%s", (int)plen, path, de->d_name);
        if (n < 0 || (size_t)n >= sizeof(child_path)) { closedir(dir); return false; }
        if (!collect_entries_metadata_recurse(child_path, el)) { closedir(dir); return false; }
    }
    closedir(dir);
    return true;
}

static bool collect_entries_metadata_recurse(const char *path, entry_list_t *el) {
    struct stat st;
    if (lstat(path, &st) != 0) return false;

    const char *norm = NULL;
    size_t norm_len = 0;
    blip_normalize_path(path, strlen(path), &norm, &norm_len);
    if (norm_len == 0) {
        return collect_metadata_dir_children(path, el);
    }
    char *owned_path = strdup(norm);
    if (!owned_path) return false;
    if (!entry_list_add_content(el, (uint8_t *)owned_path)) { free(owned_path); return false; }

    if (S_ISDIR(st.st_mode)) {
        blip_archive_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.path = owned_path;
        entry.path_len = strlen(owned_path);
        entry.is_dir = 1;
        fill_entry_metadata(&entry, &st);
        /* Read xattrs */
        blip_xattr_entry *xa = NULL; size_t xa_count = 0;
        uint8_t *rfork = NULL; size_t rfork_len = 0;
        read_file_xattrs(path, &xa, &xa_count, &rfork, &rfork_len);
        entry.xattrs = xa; entry.xattr_count = xa_count;
        entry.resource_fork = rfork; entry.resource_fork_len = rfork_len;
        if (!entry_list_add(el, entry)) return false;
        if (xa) entry_list_add_content(el, (uint8_t *)xa);
        for (size_t xi = 0; xi < xa_count; xi++) {
            if (xa[xi].name) entry_list_add_content(el, (uint8_t *)xa[xi].name);
            if (xa[xi].value) entry_list_add_content(el, (uint8_t *)xa[xi].value);
        }
        if (rfork) entry_list_add_content(el, rfork);
        return collect_metadata_dir_children(path, el);
    } else if (S_ISREG(st.st_mode)) {
        /* KEY DIFFERENCE: store source_path instead of reading content */
        char *disk_path = strdup(path);
        if (!disk_path) return false;
        if (!entry_list_add_content(el, (uint8_t *)disk_path)) { free(disk_path); return false; }

        blip_archive_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.path = owned_path;
        entry.path_len = strlen(owned_path);
        entry.content = NULL;  /* no content loaded */
        entry.content_len = (size_t)st.st_size;  /* size from stat */
        entry.is_dir = 0;
        entry.source_path = disk_path;
        entry.source_path_len = strlen(disk_path);
        fill_entry_metadata(&entry, &st);
        /* Read xattrs */
        blip_xattr_entry *xa = NULL; size_t xa_count = 0;
        uint8_t *rfork = NULL; size_t rfork_len = 0;
        read_file_xattrs(path, &xa, &xa_count, &rfork, &rfork_len);
        entry.xattrs = xa; entry.xattr_count = xa_count;
        entry.resource_fork = rfork; entry.resource_fork_len = rfork_len;
        if (!entry_list_add(el, entry)) return false;
        if (xa) entry_list_add_content(el, (uint8_t *)xa);
        for (size_t xi = 0; xi < xa_count; xi++) {
            if (xa[xi].name) entry_list_add_content(el, (uint8_t *)xa[xi].name);
            if (xa[xi].value) entry_list_add_content(el, (uint8_t *)xa[xi].value);
        }
        if (rfork) entry_list_add_content(el, rfork);
        return true;
    }
    /* Skip non-regular, non-directory entries (symlinks, etc.) */
    return true;
}


static bool expand_via_zig(entry_list_t *el, const uint8_t *content, size_t content_len, const blip_archive_entry *file_entry, const blar_codec_t *codec);

static bool collect_entries_recurse(const char *path, entry_list_t *el);

static bool collect_dir_children(const char *path, entry_list_t *el) {
    DIR *dir = opendir(path);
    if (!dir) {
        fprintf(stderr, "blar: create: cannot open directory '%s': %s\n",
                path, strerror(errno));
        return false;
    }

    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;

        char child_path[4096];
        /* Strip trailing slashes from parent to avoid "dir//child" */
        size_t plen = strlen(path);
        while (plen > 0 && path[plen - 1] == '/') plen--;
        int n = snprintf(child_path, sizeof(child_path), "%.*s/%s", (int)plen, path, de->d_name);
        if (n < 0 || (size_t)n >= sizeof(child_path)) {
            fprintf(stderr, "blar: create: path too long: %s/%s\n", path, de->d_name);
            closedir(dir);
            return false;
        }

        if (!collect_entries_recurse(child_path, el)) {
            closedir(dir);
            return false;
        }
    }
    closedir(dir);
    return true;
}

static bool collect_entries_recurse(const char *path, entry_list_t *el) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        fprintf(stderr, "blar: create: cannot stat '%s': %s\n",
                path, strerror(errno));
        return false;
    }

    const char *norm = NULL;
    size_t norm_len = 0;
    blip_normalize_path(path, strlen(path), &norm, &norm_len);
    if (norm_len == 0) {
        /* Root "." — skip entry but recurse */
        if (S_ISDIR(st.st_mode)) return collect_dir_children(path, el);
        return true;
    }

    /* Duplicate the normalized path so it survives stack unwinding */
    char *norm_dup = strndup(norm, norm_len);
    if (!norm_dup) return false;
    if (!entry_list_add_content(el, (uint8_t *)norm_dup)) {
        free(norm_dup);
        return false;
    }
    char *owned_path = norm_dup;
    /* Strip trailing slashes from stored path */
    size_t op_len = norm_len;
    while (op_len > 0 && owned_path[op_len - 1] == '/') owned_path[--op_len] = '\0';

    if (S_ISDIR(st.st_mode)) {
        blip_archive_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.path = owned_path;
        entry.path_len = strlen(owned_path);
        entry.is_dir = 1;
        fill_entry_metadata(&entry, &st);
        memset(entry.xh64, 0, 8);

        /* Read xattrs (dirs don't have resource forks) */
        blip_xattr_entry *xa = NULL;
        size_t xa_count = 0;
        uint8_t *rfork = NULL;
        size_t rfork_len = 0;
        read_file_xattrs(path, &xa, &xa_count, &rfork, &rfork_len);
        entry.xattrs = xa;
        entry.xattr_count = xa_count;
        /* resource_fork stays NULL/0 for dirs (rfork freed below if any) */

        if (!entry_list_add(el, entry)) {
            free_file_xattrs(xa, xa_count, rfork);
            return false;
        }
        /* Register xattr buffers for cleanup */
        if (xa) entry_list_add_content(el, (uint8_t *)xa);
        for (size_t xi = 0; xi < xa_count; xi++) {
            if (xa[xi].name) entry_list_add_content(el, (uint8_t *)xa[xi].name);
            if (xa[xi].value) entry_list_add_content(el, (uint8_t *)xa[xi].value);
        }
        if (rfork) entry_list_add_content(el, rfork);

        if (el->progress) progrez_update(el->progress, el->count, el->bytes_seen);

        return collect_dir_children(path, el);
    } else if (S_ISREG(st.st_mode)) {
        /* Update progress label with current filename */
        if (el->progress) {
            const char *basename = strrchr(path, '/');
            basename = basename ? basename + 1 : path;
            char label_buf[256];
            snprintf(label_buf, sizeof(label_buf), "Scanning: %s", basename);
            progrez_set_label(el->progress, label_buf);
        }

        size_t content_len = 0;
        uint8_t *content = NULL;
        char *disk_path = NULL;

        if (el->metadata_only) {
            /* Streaming mode: record source path, don't load content */
            content_len = (size_t)st.st_size;
            disk_path = strdup(path);
            if (!disk_path) return false;
            if (!entry_list_add_content(el, (uint8_t *)disk_path)) {
                free(disk_path);
                return false;
            }
        } else {
            content = read_file(path, &content_len);
            if (!content) {
                fprintf(stderr, "blar: create: cannot read '%s': %s\n",
                        path, strerror(errno));
                return false;
            }
            if (!entry_list_add_content(el, content)) {
                free(content);
                return false;
            }
        }

        blip_archive_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.path = owned_path;
        entry.path_len = strlen(owned_path);
        entry.content = content;
        entry.content_len = content_len;
        entry.is_dir = 0;
        entry.source_path = disk_path;
        entry.source_path_len = disk_path ? strlen(disk_path) : 0;
        fill_entry_metadata(&entry, &st);

        /* Read xattrs and resource fork */
        blip_xattr_entry *xa = NULL;
        size_t xa_count = 0;
        uint8_t *rfork = NULL;
        size_t rfork_len = 0;
        read_file_xattrs(path, &xa, &xa_count, &rfork, &rfork_len);
        entry.xattrs = xa;
        entry.xattr_count = xa_count;
        entry.resource_fork = rfork;
        entry.resource_fork_len = rfork_len;

        /* Container expansion is deferred to a separate pass (expand_containers_pass)
         * so it can have its own progress bar and potentially be parallelized. */

        if (!entry_list_add(el, entry)) {
            free_file_xattrs(xa, xa_count, rfork);
            return false;
        }
        /* Register xattr buffers for cleanup */
        if (xa) entry_list_add_content(el, (uint8_t *)xa);
        for (size_t xi = 0; xi < xa_count; xi++) {
            if (xa[xi].name) entry_list_add_content(el, (uint8_t *)xa[xi].name);
            if (xa[xi].value) entry_list_add_content(el, (uint8_t *)xa[xi].value);
        }
        if (rfork) entry_list_add_content(el, rfork);

        el->bytes_seen += content_len;
        if (el->progress) progrez_update(el->progress, el->count, el->bytes_seen);
    }

    return true;
}

/* ── Container expansion pass (separate phase with progress) ─────────── */

/* Try to expand containers in the entry list. This runs after scanning,
 * so we know the total count and can show determinate progress.
 * Expanded entries replace the original at its index (DIR entry) and
 * append child entries at the end of the list. */
/* Worker context for parallel container expansion */
typedef struct {
    size_t index;                        /* index in main entry list */
    blip_archive_entry entry_copy;       /* copy of the original entry */
    const uint8_t *content;              /* pointer to file content */
    size_t content_len;
    const blar_codec_t *codec;           /* detected codec */
    entry_list_t result;                 /* per-worker result list */
    bool success;                        /* did expansion succeed? */
    bool expand_all_zips;
} expand_worker_ctx_t;

/* Shared state for work-stealing expansion threads */
typedef struct {
    expand_worker_ctx_t *workers;
    size_t total;
    _Atomic size_t next_index;   /* next item to grab */
    _Atomic size_t done_count;   /* items completed (for progress) */
    _Atomic uint64_t done_bytes; /* bytes completed (for progress) */
} expand_work_queue_t;

static void *expand_worker(void *arg) {
    expand_work_queue_t *queue = (expand_work_queue_t *)arg;

    while (1) {
        size_t idx = atomic_fetch_add(&queue->next_index, 1);
        if (idx >= queue->total) break;

        expand_worker_ctx_t *ctx = &queue->workers[idx];
        entry_list_init(&ctx->result);
        ctx->result.expand_all_zips = ctx->expand_all_zips;
        ctx->success = expand_via_zig(
            &ctx->result, ctx->content, ctx->content_len, &ctx->entry_copy, ctx->codec);

        atomic_fetch_add(&queue->done_count, 1);
        atomic_fetch_add(&queue->done_bytes, ctx->content_len);
    }
    return NULL;
}


/* Bridge: try Zig expansion first, fall back to C expand function.
 * This is the transition layer — formats migrated to expansion.zig go through
 * blip_expand_file(), others still use their C expand_*_container() function. */


static bool expand_via_zig(entry_list_t *el,
                                 const uint8_t *content, size_t content_len,
                                 const blip_archive_entry *file_entry,
                                 const blar_codec_t *codec) {
    /* ALL formats go through Zig core expansion */
    {
        size_t count = 0;
        const char *container_type = NULL;
        size_t container_type_len = 0;
        const char **path_suffixes = NULL;
        size_t *path_suffix_lens = NULL;
        uint8_t **contents = NULL;
        size_t *content_lens_arr = NULL;
        uint8_t *is_dirs = NULL;
        const char **jxl_sources = NULL;
        size_t *jxl_source_lens = NULL;
        uint8_t *gz_levels = NULL;
        uint16_t *zip_comps = NULL;
        uint64_t *pdf_offsets = NULL;
        uint64_t *pdf_lengths = NULL;

        int rc = blip_expand_file(
            content, content_len,
            codec->name, strlen(codec->name),
            &count,
            &container_type, &container_type_len,
            &path_suffixes, &path_suffix_lens,
            &contents, &content_lens_arr,
            &is_dirs,
            &jxl_sources, &jxl_source_lens,
            &gz_levels,
            &zip_comps, &pdf_offsets, &pdf_lengths
        );

        if (rc != 0) return false;

        /* Build entry list from Zig expansion results */
        /* Container DIR entry */
        blip_archive_entry dir_entry;
        memset(&dir_entry, 0, sizeof(dir_entry));
        dir_entry.path = file_entry->path;
        dir_entry.path_len = file_entry->path_len;
        dir_entry.is_dir = 1;
        dir_entry.mode = file_entry->mode;
        dir_entry.mtime_ns = file_entry->mtime_ns;
        dir_entry.ctime_ns = file_entry->ctime_ns;
        dir_entry.birthtime_ns = file_entry->birthtime_ns;
        dir_entry.uid = file_entry->uid;
        dir_entry.gid = file_entry->gid;
        dir_entry.owner = file_entry->owner;
        dir_entry.owner_len = file_entry->owner_len;
        dir_entry.groupname = file_entry->groupname;
        dir_entry.groupname_len = file_entry->groupname_len;
        dir_entry.xattrs = file_entry->xattrs;
        dir_entry.xattr_count = file_entry->xattr_count;
        dir_entry.container_type = container_type;
        dir_entry.container_type_len = container_type_len;
        dir_entry.zip_compression_method = 0xFFFF;
        dir_entry.pdf_stream_offset = UINT64_MAX;
        dir_entry.pdf_stream_length = UINT64_MAX;
        memset(dir_entry.xh64, 0, 8);
        if (!entry_list_add(el, dir_entry)) return false;

        /* Add child entries */
        for (size_t i = 0; i < count; i++) {
            /* Build full path: file_entry->path / suffix */
            size_t suffix_len = path_suffix_lens[i];
            size_t child_path_len = file_entry->path_len + 1 + suffix_len;
            char *child_path = malloc(child_path_len + 1);
            if (!child_path) return false;
            memcpy(child_path, file_entry->path, file_entry->path_len);
            child_path[file_entry->path_len] = '/';
            memcpy(child_path + file_entry->path_len + 1, path_suffixes[i], suffix_len);
            child_path[child_path_len] = '\0';
            if (!entry_list_add_content(el, (uint8_t *)child_path)) { free(child_path); return false; }

            /* Copy content to malloc'd buffer (Zig allocated with page_allocator) */
            uint8_t *child_content = NULL;
            size_t child_content_len = content_lens_arr[i];
            if (child_content_len > 0) {
                child_content = malloc(child_content_len);
                if (!child_content) return false;
                memcpy(child_content, contents[i], child_content_len);
                blip_free((uint8_t *)contents[i], child_content_len);
                if (!entry_list_add_content(el, child_content)) return false;
            }

            blip_archive_entry child_ent;
            memset(&child_ent, 0, sizeof(child_ent));
            child_ent.path = child_path;
            child_ent.path_len = child_path_len;
            child_ent.content = child_content;
            child_ent.content_len = child_content_len;
            child_ent.is_dir = is_dirs[i] ? 1 : 0;
            child_ent.mode = file_entry->mode;
            child_ent.mtime_ns = file_entry->mtime_ns;
            child_ent.zip_compression_method = (zip_comps && zip_comps[i] != 0xFFFF) ? zip_comps[i]
                                             : (gz_levels && gz_levels[i] > 0) ? (uint16_t)gz_levels[i] : 0xFFFF;
            child_ent.pdf_stream_offset = (pdf_offsets) ? pdf_offsets[i] : UINT64_MAX;
            child_ent.pdf_stream_length = (pdf_lengths) ? pdf_lengths[i] : UINT64_MAX;
            if (jxl_source_lens[i] > 0) {
                child_ent.jxl_source_format = jxl_sources[i];
                child_ent.jxl_source_format_len = jxl_source_lens[i];
            }
            memset(child_ent.xh64, 0, 8);
            if (!entry_list_add(el, child_ent)) return false;
        }

        /* Free Zig-allocated arrays */
        blip_free((uint8_t *)path_suffixes, count * sizeof(const char *));
        blip_free((uint8_t *)path_suffix_lens, count * sizeof(size_t));
        blip_free((uint8_t *)contents, count * sizeof(uint8_t *));
        blip_free((uint8_t *)content_lens_arr, count * sizeof(size_t));
        blip_free((uint8_t *)is_dirs, count);
        blip_free((uint8_t *)jxl_sources, count * sizeof(const char *));
        blip_free((uint8_t *)jxl_source_lens, count * sizeof(size_t));
        if (gz_levels) blip_free((uint8_t *)gz_levels, count);
        if (zip_comps) blip_free((uint8_t *)zip_comps, count * sizeof(uint16_t));
        if (pdf_offsets) blip_free((uint8_t *)pdf_offsets, count * sizeof(uint64_t));
        if (pdf_lengths) blip_free((uint8_t *)pdf_lengths, count * sizeof(uint64_t));

        el->bytes_seen += content_len;
        return true;
    }

    return false;
}

static bool expand_containers_pass(entry_list_t *el) {
    /* First pass: identify expandable entries */
    size_t expandable = 0;
    uint64_t total_expandable_bytes = 0;

    /* Collect indices and codecs of expandable entries */
    size_t exp_cap = 64;
    expand_worker_ctx_t *workers = malloc(exp_cap * sizeof(expand_worker_ctx_t));
    if (!workers) return false;

    for (size_t i = 0; i < el->count; i++) {
        if (el->entries[i].is_dir) continue;
        const uint8_t *content = el->entries[i].content;
        size_t content_len = el->entries[i].content_len;
        const blar_codec_t *codec = blar_codec_detect(&builtin_registry, content, content_len);
        if (codec) {
            if (strcmp(codec->name, "zip") == 0 &&
                !el->expand_all_zips && is_archive_extension(el->entries[i].path)) {
                codec = NULL;
            }
        }
        if (codec) {
            if (expandable >= exp_cap) {
                exp_cap *= 2;
                workers = realloc(workers, exp_cap * sizeof(expand_worker_ctx_t));
                if (!workers) return false;
            }
            workers[expandable].index = i;
            workers[expandable].entry_copy = el->entries[i];
            workers[expandable].content = content;
            workers[expandable].content_len = content_len;
            workers[expandable].codec = codec;
            workers[expandable].success = false;
            workers[expandable].expand_all_zips = el->expand_all_zips;
            expandable++;
            total_expandable_bytes += content_len;
        }
    }

    if (expandable == 0) {
        free(workers);
        return true;
    }

    /* Set up progress for expansion phase */
    if (el->progress) {
        progrez_set_label(el->progress, "Expanding");
        progrez_set_determinate(el->progress, expandable, total_expandable_bytes);
        progrez_update(el->progress, 0, 0);
    }

    /* Determine thread count */
    size_t num_threads = el->num_threads;
    if (num_threads == 0) {
#ifdef _SC_NPROCESSORS_ONLN
        long n = sysconf(_SC_NPROCESSORS_ONLN);
        num_threads = n > 0 ? (size_t)n : 1;
#else
        num_threads = 4;
#endif
    }
    if (num_threads > expandable) num_threads = expandable;

    /* Parallel expansion: work-stealing queue — each thread grabs the
     * next available file when done, no waiting for batch boundaries. */
    if (num_threads > 1) {
        expand_work_queue_t queue = {
            .workers = workers,
            .total = expandable,
            .next_index = 0,
            .done_count = 0,
            .done_bytes = 0,
        };

        pthread_t *threads = malloc(num_threads * sizeof(pthread_t));
        if (!threads) { free(workers); return false; }

        for (size_t t = 0; t < num_threads; t++) {
            pthread_create(&threads[t], NULL, expand_worker, &queue);
        }

        /* Poll progress while workers expand containers */
        while (atomic_load(&queue.done_count) < expandable) {
            size_t done = atomic_load(&queue.done_count);
            uint64_t done_b = atomic_load(&queue.done_bytes);
            if (el->progress)
                progrez_update(el->progress, done, done_b);
            if (el->expansion_progress_fn)
                el->expansion_progress_fn(done, expandable, el->expansion_progress_ctx);

            struct timespec ts = { .tv_sec = 0, .tv_nsec = 100000000 }; /* 100ms */
            nanosleep(&ts, NULL);
        }

        for (size_t t = 0; t < num_threads; t++) {
            pthread_join(threads[t], NULL);
        }
        free(threads);

        if (el->progress)
            progrez_update(el->progress, expandable, total_expandable_bytes);
        if (el->expansion_progress_fn)
            el->expansion_progress_fn(expandable, expandable, el->expansion_progress_ctx);
    } else {
        /* Sequential fallback */
        for (size_t w = 0; w < expandable; w++) {
            entry_list_init(&workers[w].result);
            workers[w].result.expand_all_zips = workers[w].expand_all_zips;
            workers[w].success = expand_via_zig(
                &workers[w].result, workers[w].content, workers[w].content_len, &workers[w].entry_copy,
                workers[w].codec);

            if (el->progress) {
                const char *basename = strrchr(workers[w].entry_copy.path, '/');
                basename = basename ? basename + 1 : workers[w].entry_copy.path;
                char label_buf[256];
                snprintf(label_buf, sizeof(label_buf), "Expanding: %s", basename);
                progrez_set_label(el->progress, label_buf);
                progrez_update(el->progress, w + 1, 0);
            }
            if (el->expansion_progress_fn)
                el->expansion_progress_fn(w + 1, expandable, el->expansion_progress_ctx);
        }
    }

    /* Merge results: remove successfully expanded originals, append expanded entries.
     * Process in reverse order so indices remain valid during removal. */

    /* First, collect all expanded entries from workers */
    for (size_t w = 0; w < expandable; w++) {
        if (!workers[w].success) {
            /* Expansion failed — clean up the temp list, keep original */
            entry_list_free(&workers[w].result);
            continue;
        }

        /* Remove original entry at workers[w].index.
         * Since we process forward and indices shift, we need to track offset. */
    }

    /* Build a new entry list: non-expanded entries in original order,
     * then expanded entries (DIR + children) in place of originals. */
    entry_list_t merged;
    entry_list_init(&merged);
    merged.progress = el->progress;
    merged.expand_containers = el->expand_containers;
    merged.expand_all_zips = el->expand_all_zips;
    merged.num_threads = el->num_threads;
    merged.bytes_seen = el->bytes_seen;

    /* Build a set of successfully expanded indices for O(1) lookup */
    bool *expanded_set = calloc(el->count, sizeof(bool));
    if (!expanded_set) { free(workers); return false; }
    for (size_t w = 0; w < expandable; w++) {
        if (workers[w].success) expanded_set[workers[w].index] = true;
    }

    /* Walk original entries; for each expanded one, substitute the worker's results */
    size_t next_worker = 0;
    for (size_t i = 0; i < el->count; i++) {
        if (expanded_set[i]) {
            /* Find the worker for this index */
            while (next_worker < expandable && workers[next_worker].index != i)
                next_worker++;
            if (next_worker < expandable && workers[next_worker].success) {
                /* Append all entries from the worker's result list */
                for (size_t j = 0; j < workers[next_worker].result.count; j++) {
                    entry_list_add(&merged, workers[next_worker].result.entries[j]);
                }
                /* Transfer content ownership to merged list */
                for (size_t j = 0; j < workers[next_worker].result.content_count; j++) {
                    entry_list_add_content(&merged, workers[next_worker].result.content_bufs[j]);
                }
                /* Clear worker's content_bufs so entry_list_free doesn't double-free */
                workers[next_worker].result.content_count = 0;
                next_worker++;
            }
        } else {
            entry_list_add(&merged, el->entries[i]);
        }
    }

    /* Transfer content ownership — free expanded entries' content (O(N) via pointer set).
     * Build set of expanded content pointers first, then iterate with O(1) lookup. */
    {
        /* Collect pointers to free in a simple array (expandable is typically small) */
        const uint8_t **expanded_ptrs = calloc(expandable, sizeof(const uint8_t *));
        size_t num_expanded_ptrs = 0;
        if (expanded_ptrs) {
            for (size_t w = 0; w < expandable; w++) {
                if (!workers[w].success) continue;
                size_t eidx = workers[w].index;
                if (el->entries[eidx].content && el->entries[eidx].content_len > 0) {
                    expanded_ptrs[num_expanded_ptrs++] = el->entries[eidx].content;
                }
            }
        }
        for (size_t i = 0; i < el->content_count; i++) {
            bool is_expanded = false;
            if (expanded_ptrs) {
                for (size_t ep = 0; ep < num_expanded_ptrs; ep++) {
                    if (el->content_bufs[i] == expanded_ptrs[ep]) {
                        is_expanded = true;
                        break;
                    }
                }
            }
            if (is_expanded) {
                free(el->content_bufs[i]);
            } else {
                entry_list_add_content(&merged, el->content_bufs[i]);
            }
        }
        free(expanded_ptrs);
    }
    /* Prevent original from freeing content (transferred or freed above) */
    el->content_count = 0;

    /* Clean up workers */
    for (size_t w = 0; w < expandable; w++) {
        entry_list_free(&workers[w].result);
    }
    free(workers);
    free(expanded_set);

    /* Swap merged into el */
    free(el->entries);
    el->entries = merged.entries;
    el->count = merged.count;
    el->capacity = merged.capacity;
    /* Content bufs were already transferred */
    free(el->content_bufs);
    el->content_bufs = merged.content_bufs;
    el->content_count = merged.content_count;
    el->content_capacity = merged.content_capacity;

    return true;
}

#endif /* BLAR_COMMON_H */
