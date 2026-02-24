/*
 * blar_common.h -- Shared utilities for blar and miniblar CLIs
 *
 * Includes: file I/O, mkdir -p, progress bar, exit codes, arg parsing.
 */

#ifndef BLAR_COMMON_H
#define BLAR_COMMON_H

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

/* ── Peek: types, helpers, shared implementation ─────────────────────── */

typedef enum {
    PEEK_ACC_NONE,
    PEEK_ACC_TYPE,
    PEEK_ACC_COUNT,
    PEEK_ACC_HASH,
    PEEK_ACC_KEYS,
} peek_accessor_t;

typedef enum {
    PEEK_OUT_DEFAULT,
    PEEK_OUT_JSON,
    PEEK_OUT_RAW,
} peek_output_mode_t;

static const char *peek_type_name(uint8_t type) {
    switch (type) {
    case 0x01: return "ARRAY";
    case 0x02: return "DICT";
    case 0x03: return "UTF8";
    case 0x04: return "RAW";
    case 0x05: return "FILE";
    case 0x06: return "MAP";
    case 0x07: return "DIR";
    case 0x08: return "DATA";
    default:   return "UNKNOWN";
    }
}

/* Parse accessor suffix (.type, .count, .hash, .keys) from a path string.
 * Sets *nav_len to the length of the navigation portion (before accessor). */
static peek_accessor_t peek_parse_accessor(const char *path, size_t path_len,
                                            size_t *nav_len) {
    static const struct { const char *suffix; size_t len; peek_accessor_t acc; } table[] = {
        { ".count", 6, PEEK_ACC_COUNT },
        { ".type",  5, PEEK_ACC_TYPE  },
        { ".hash",  5, PEEK_ACC_HASH  },
        { ".keys",  5, PEEK_ACC_KEYS  },
    };

    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (path_len >= table[i].len &&
            memcmp(path + path_len - table[i].len, table[i].suffix,
                   table[i].len) == 0) {
            size_t prefix_len = path_len - table[i].len;
            if (prefix_len == 0 || path[prefix_len - 1] == ']') {
                *nav_len = prefix_len;
                return table[i].acc;
            }
        }
    }

    *nav_len = path_len;
    return PEEK_ACC_NONE;
}

/* Extract the last key from a navigation path.
 * Returns true if the last segment is a dict key (non-numeric). */
static bool peek_last_key(const char *path, size_t path_len,
                           const char **out_key, size_t *out_key_len) {
    if (path_len < 3 || path[path_len - 1] != ']') return false;

    size_t i = path_len - 2;
    while (i > 0 && path[i] != '[') i--;
    if (path[i] != '[') return false;

    const char *key = path + i + 1;
    size_t key_len = (path_len - 1) - (i + 1);
    if (key_len == 0) return false;

    bool all_digits = true;
    for (size_t j = 0; j < key_len; j++) {
        if (key[j] < '0' || key[j] > '9') { all_digits = false; break; }
    }
    if (all_digits) return false;

    *out_key = key;
    *out_key_len = key_len;
    return true;
}

/* Extract value payload from container bytes (skip TLV header).
 * Works for UTF8 (0x03), RAW (0x04), and DATA (0x08).
 * Note: BLIP containers encode the TOTAL container length, not payload length.
 * For DATA, the value region includes a trailing 8-byte xxHash64 which we exclude. */
static bool peek_extract_payload(const uint8_t *container, size_t container_len,
                                  uint8_t type,
                                  const uint8_t **out_payload,
                                  size_t *out_payload_len) {
    if (type != 0x03 && type != 0x04 && type != 0x08) return false;
    if (container_len < 3) return false;

    uint64_t total_length = 0;
    int32_t consumed = blip_decode(container + 2, container_len - 2, &total_length);
    if (consumed < 0) return false;

    size_t value_offset = 2 + (size_t)consumed;
    if (total_length > container_len) return false;
    if (total_length < value_offset) return false;

    size_t value_len = (size_t)total_length - value_offset;

    /* DATA containers have an 8-byte xxHash64 suffix in the value region */
    if (type == 0x08) {
        if (value_len < 8) return false;
        value_len -= 8;
    }

    *out_payload = container + value_offset;
    *out_payload_len = value_len;
    return true;
}

/* Print bytes as hex. */
static void peek_print_hex(const uint8_t *data, size_t len, FILE *out) {
    for (size_t i = 0; i < len; i++)
        fprintf(out, "%02x", data[i]);
}

/* Print nanosecond-epoch timestamp as ISO 8601. */
static void peek_print_timestamp(int64_t ns, FILE *out) {
    time_t secs = (time_t)(ns / 1000000000LL);
    long nanos = (long)(ns % 1000000000LL);
    if (nanos < 0) { secs--; nanos += 1000000000L; }
    struct tm tm;
    gmtime_r(&secs, &tm);
    fprintf(out, "%04d-%02d-%02dT%02d:%02d:%02d.%09ldZ",
            tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
            tm.tm_hour, tm.tm_min, tm.tm_sec, nanos);
}

/* Format a value for a known metadata key.
 * Returns true if the key was recognized and formatted.
 * Handles: md (mode), mt/ct/bt (timestamps), ui/gi (IDs), xh (hash). */
static bool peek_format_known_key(const char *key, size_t key_len,
                                   uint8_t type,
                                   const uint8_t *payload, size_t payload_len,
                                   peek_output_mode_t mode, FILE *out) {
    if (key_len != 2) return false;

    /* md: mode (u16 LE) → octal */
    if (memcmp(key, "md", 2) == 0 && type == 0x04 && payload_len == 2) {
        uint16_t m = (uint16_t)payload[0] | ((uint16_t)payload[1] << 8);
        if (mode == PEEK_OUT_JSON)
            fprintf(out, "%u", m);
        else
            fprintf(out, "%04o", m);
        return true;
    }

    /* mt, ct, bt: timestamps (i64 LE ns) → ISO 8601 */
    if (type == 0x04 && payload_len == 8 &&
        (memcmp(key, "mt", 2) == 0 || memcmp(key, "ct", 2) == 0 ||
         memcmp(key, "bt", 2) == 0)) {
        int64_t ns = 0;
        memcpy(&ns, payload, 8);
        if (mode == PEEK_OUT_JSON)
            fprintf(out, "%lld", (long long)ns);
        else
            peek_print_timestamp(ns, out);
        return true;
    }

    /* ui, gi: IDs (u32 LE) → decimal */
    if (type == 0x04 && payload_len == 4 &&
        (memcmp(key, "ui", 2) == 0 || memcmp(key, "gi", 2) == 0)) {
        uint32_t id = 0;
        memcpy(&id, payload, 4);
        fprintf(out, "%u", id);
        return true;
    }

    /* xh: hash (8 bytes) → hex */
    if (memcmp(key, "xh", 2) == 0 && type == 0x04 && payload_len == 8) {
        peek_print_hex(payload, payload_len, out);
        return true;
    }

    /* pa, un, gn: UTF8 strings — display as-is (or quoted for JSON) */
    if (type == 0x03 &&
        (memcmp(key, "pa", 2) == 0 || memcmp(key, "un", 2) == 0 ||
         memcmp(key, "gn", 2) == 0)) {
        if (mode == PEEK_OUT_JSON) {
            fputc('"', out);
            fwrite(payload, 1, payload_len, out);
            fputc('"', out);
        } else {
            fwrite(payload, 1, payload_len, out);
        }
        return true;
    }

    return false;
}

/* Main peek command implementation shared by blar and miniblar. */
static int cmd_peek_common(const char *prog, int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr,
                "%s: peek: requires <archive> [<path>] [--json|--raw|--type]\n",
                prog);
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *path = "";
    peek_output_mode_t out_mode = PEEK_OUT_DEFAULT;
    bool type_flag = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0)      out_mode = PEEK_OUT_JSON;
        else if (strcmp(argv[i], "--raw") == 0)   out_mode = PEEK_OUT_RAW;
        else if (strcmp(argv[i], "--type") == 0)  type_flag = true;
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

    /* Read archive */
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "%s: peek: cannot open '%s': %s\n",
                prog, archive_path, strerror(errno));
        return EXIT_IO;
    }

    size_t path_len = strlen(path);

    /* Parse accessor from path */
    size_t nav_len = 0;
    peek_accessor_t accessor = peek_parse_accessor(path, path_len, &nav_len);

    /* --type flag forces TYPE accessor */
    if (type_flag) accessor = PEEK_ACC_TYPE;

    /* Navigate to the target container */
    uint8_t type = 0;
    const uint8_t *data = NULL;
    size_t data_len = 0;
    int32_t rc = blip_peek(buf, buf_len, path, nav_len, &type, &data, &data_len);
    if (rc != BLIP_OK) {
        fprintf(stderr, "%s: peek: %s\n", prog, blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    int result = EXIT_OK;

    switch (accessor) {
    case PEEK_ACC_TYPE:
        if (out_mode == PEEK_OUT_JSON)
            printf("\"%s\"\n", peek_type_name(type));
        else
            printf("%s\n", peek_type_name(type));
        break;

    case PEEK_ACC_COUNT: {
        uint64_t count = 0;
        rc = blip_container_count(data, data_len, &count);
        if (rc != BLIP_OK) {
            fprintf(stderr, "%s: peek: %s\n", prog, blip_error_string(rc));
            result = EXIT_IO;
        } else {
            printf("%llu\n", (unsigned long long)count);
        }
        break;
    }

    case PEEK_ACC_HASH: {
        uint8_t hash[8];
        rc = blip_container_hash(data, data_len, hash);
        if (rc != BLIP_OK) {
            fprintf(stderr, "%s: peek: %s\n", prog, blip_error_string(rc));
            result = EXIT_IO;
        } else {
            if (out_mode == PEEK_OUT_JSON) printf("\"");
            peek_print_hex(hash, 8, stdout);
            if (out_mode == PEEK_OUT_JSON) printf("\"");
            printf("\n");
        }
        break;
    }

    case PEEK_ACC_KEYS: {
        uint64_t count = 0;
        rc = blip_container_count(data, data_len, &count);
        if (rc != BLIP_OK) {
            fprintf(stderr, "%s: peek: %s\n", prog, blip_error_string(rc));
            result = EXIT_IO;
            break;
        }

        if (out_mode == PEEK_OUT_JSON) {
            printf("[");
            for (uint64_t i = 0; i < count; i++) {
                const uint8_t *key = NULL;
                size_t klen = 0;
                rc = blip_container_key_at(data, data_len, i, &key, &klen);
                if (rc != BLIP_OK) {
                    fprintf(stderr, "\n%s: peek: %s\n", prog,
                            blip_error_string(rc));
                    result = EXIT_IO;
                    break;
                }
                if (i > 0) printf(",");
                printf("\"");
                fwrite(key, 1, klen, stdout);
                printf("\"");
            }
            if (result == EXIT_OK) printf("]\n");
        } else {
            for (uint64_t i = 0; i < count; i++) {
                const uint8_t *key = NULL;
                size_t klen = 0;
                rc = blip_container_key_at(data, data_len, i, &key, &klen);
                if (rc != BLIP_OK) {
                    fprintf(stderr, "%s: peek: %s\n", prog,
                            blip_error_string(rc));
                    result = EXIT_IO;
                    break;
                }
                fwrite(key, 1, klen, stdout);
                printf("\n");
            }
        }
        break;
    }

    case PEEK_ACC_NONE: {
        /* --raw: output raw payload bytes */
        if (out_mode == PEEK_OUT_RAW) {
            const uint8_t *payload = NULL;
            size_t plen = 0;
            if (peek_extract_payload(data, data_len, type, &payload, &plen)) {
                if (plen > 0) fwrite(payload, 1, plen, stdout);
            } else {
                /* Container type: output raw container bytes */
                fwrite(data, 1, data_len, stdout);
            }
            break;
        }

        /* Check for semantic display of known metadata keys */
        const char *last_key = NULL;
        size_t last_key_len = 0;
        bool has_key = peek_last_key(path, nav_len, &last_key, &last_key_len);
        if (has_key) {
            const uint8_t *payload = NULL;
            size_t plen = 0;
            if (peek_extract_payload(data, data_len, type, &payload, &plen)) {
                if (peek_format_known_key(last_key, last_key_len, type,
                                           payload, plen, out_mode, stdout)) {
                    printf("\n");
                    break;
                }
            }
        }

        /* Default display by type */
        switch (type) {
        case 0x03: { /* UTF8 */
            const uint8_t *payload = NULL;
            size_t plen = 0;
            if (peek_extract_payload(data, data_len, type, &payload, &plen)) {
                if (out_mode == PEEK_OUT_JSON) {
                    printf("\"");
                    fwrite(payload, 1, plen, stdout);
                    printf("\"\n");
                } else {
                    fwrite(payload, 1, plen, stdout);
                    printf("\n");
                }
            }
            break;
        }
        case 0x04: { /* RAW */
            const uint8_t *payload = NULL;
            size_t plen = 0;
            if (peek_extract_payload(data, data_len, type, &payload, &plen)) {
                if (out_mode == PEEK_OUT_JSON) {
                    printf("\"");
                    peek_print_hex(payload, plen, stdout);
                    printf("\"\n");
                } else {
                    uint8_t *pb_buf = NULL;
                    size_t pb_len = 0;
                    rc = blip_encode_printable_binary(payload, plen,
                                                      &pb_buf, &pb_len);
                    if (rc == BLIP_OK && pb_buf) {
                        fwrite(pb_buf, 1, pb_len, stdout);
                        printf("\n");
                        blip_free(pb_buf, pb_len);
                    } else {
                        peek_print_hex(payload, plen, stdout);
                        printf("\n");
                    }
                }
            }
            break;
        }
        case 0x08: { /* DATA */
            const uint8_t *payload = NULL;
            size_t plen = 0;
            if (peek_extract_payload(data, data_len, type, &payload, &plen)) {
                if (out_mode == PEEK_OUT_JSON) {
                    printf("\"");
                    peek_print_hex(payload, plen, stdout);
                    printf("\"\n");
                } else {
                    uint8_t *pb_buf = NULL;
                    size_t pb_len = 0;
                    rc = blip_encode_printable_binary(payload, plen,
                                                      &pb_buf, &pb_len);
                    if (rc == BLIP_OK && pb_buf) {
                        fwrite(pb_buf, 1, pb_len, stdout);
                        printf("\n");
                        blip_free(pb_buf, pb_len);
                    }
                    fprintf(stderr, "(DATA, %llu bytes)\n",
                            (unsigned long long)plen);
                }
            }
            break;
        }
        case 0x01: case 0x05: { /* ARRAY, FILE */
            uint64_t count = 0;
            blip_container_count(data, data_len, &count);
            if (out_mode == PEEK_OUT_JSON)
                printf("{\"type\":\"%s\",\"count\":%llu}\n",
                       peek_type_name(type), (unsigned long long)count);
            else
                printf("%s (%llu elements)\n", peek_type_name(type),
                       (unsigned long long)count);
            break;
        }
        case 0x02: case 0x06: case 0x07: { /* DICT, MAP, DIR */
            uint64_t count = 0;
            blip_container_count(data, data_len, &count);
            if (out_mode == PEEK_OUT_JSON)
                printf("{\"type\":\"%s\",\"count\":%llu}\n",
                       peek_type_name(type), (unsigned long long)count);
            else
                printf("%s (%llu pairs)\n", peek_type_name(type),
                       (unsigned long long)count);
            break;
        }
        default:
            fprintf(stderr, "%s: peek: unknown container type 0x%02x\n",
                    prog, type);
            result = EXIT_IO;
            break;
        }
        break;
    }
    }

    free(buf);
    return result;
}

#endif /* BLAR_COMMON_H */
