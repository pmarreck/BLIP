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
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <termios.h>

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
        int32_t rc = blip_lzma2_decompress(buf, *out_len, &decompressed, &decomp_len);
        free(buf);
        if (rc != BLIP_OK) {
            fprintf(stderr, "Failed to decompress archive: %s\n",
                    blip_error_string(rc));
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

/* ── Progress bar ─────────────────────────────────────────────────────── */

static void progress_bar(FILE *out, uint64_t current, uint64_t total,
                         uint64_t bytes_done, uint64_t bytes_total) {
    const int bar_width = 16;
    int filled = (total > 0) ? (int)((current * (uint64_t)bar_width) / total) : 0;
    if (filled > bar_width) filled = bar_width;
    int empty = bar_width - filled;

    fprintf(out, "\r[");
    for (int i = 0; i < filled; i++) fprintf(out, "\xe2\x96\x88");
    for (int i = 0; i < empty; i++) fprintf(out, "\xe2\x96\x91");
    fprintf(out, "]  %llu/%llu files", (unsigned long long)current,
            (unsigned long long)total);

    double done_mb = (double)bytes_done / (1024.0 * 1024.0);
    double total_mb = (double)bytes_total / (1024.0 * 1024.0);
    if (bytes_total >= 1024 * 1024) {
        fprintf(out, "   %.1f MB / %.1f MB", done_mb, total_mb);
    } else {
        fprintf(out, "   %llu B / %llu B", (unsigned long long)bytes_done,
                (unsigned long long)bytes_total);
    }

    if (current == total) {
        fprintf(out, "\n");
    }
    fflush(out);
}

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
    /* Find the basename: last component after '/' */
    const char *base = strrchr(input_path, '/');
    base = base ? base + 1 : input_path;

    /* Strip trailing slash if any */
    size_t base_len = strlen(base);
    while (base_len > 0 && base[base_len - 1] == '/') base_len--;
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
        "Usage: %s from-json [-o <output>] [<json-file>]\n"
        "\n"
        "Convert JSON to a BLIP archive.\n"
        "Reads JSON from a file argument or stdin.\n"
        "\n"
        "Options:\n"
        "  -o <output>   Write archive to specified file (required unless piping)\n"
        "\n"
        "Examples:\n"
        "  %s from-json input.json -o output.blar\n"
        "  cat input.json | %s from-json -o output.blar\n"
        "  %s to-json a.blar | jq '...' | %s from-json -o b.blar\n",
        prog, prog, prog, prog, prog);
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

    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: from-json: -o requires an argument\n", prog);
                return EXIT_USAGE;
            }
            output_path = argv[++i];
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

    if (!write_file(output_path, archive_buf, archive_len)) {
        fprintf(stderr, "%s: from-json: cannot write '%s': %s\n",
                prog, output_path, strerror(errno));
        blip_free(archive_buf, archive_len);
        return EXIT_IO;
    }

    blip_free(archive_buf, archive_len);
    return EXIT_OK;
}

#endif /* BLAR_COMMON_H */
