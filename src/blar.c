/*
 * blar -- BLIP Archive CLI
 *
 * A tar-like command-line tool for creating and manipulating BLIP archives.
 * Calls through the C FFI surface of libblip.
 *
 * Usage:
 *   blar create -o archive.blar file1 file2 ...
 *   blar list archive.blar
 *   blar extract archive.blar [-C dir]
 *   blar verify archive.blar
 *   blar info archive.blar
 *   blar cat archive.blar path/in/archive
 *
 * Tar-style shorthand (hyphen optional):
 *   blar cf archive.blar file1 file2 ...
 *   blar tf archive.blar
 *   blar xf archive.blar [-C dir]
 *   blar Vf archive.blar
 *   blar If archive.blar
 *   blar pf archive.blar path/in/archive
 */

#include "blip.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ── Exit codes ───────────────────────────────────────────────────────── */

#define EXIT_OK       0
#define EXIT_USAGE    1
#define EXIT_IO       2
#define EXIT_VERIFY   3

/* ── Version ──────────────────────────────────────────────────────────── */

#define BLAR_VERSION "0.1.0"

/* ── Forward declarations ─────────────────────────────────────────────── */

static int cmd_create(int argc, char **argv);
static int cmd_list(int argc, char **argv);
static int cmd_extract(int argc, char **argv);
static int cmd_verify(int argc, char **argv);
static int cmd_info(int argc, char **argv);
static int cmd_cat(int argc, char **argv);
static void print_usage(FILE *out);
static void print_version(void);

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

    /* Find the last slash. */
    char *last_slash = strrchr(tmp, '/');
    if (!last_slash) return true; /* no directory component */
    *last_slash = '\0';
    return mkdirp(tmp);
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

    /* Show bytes in human-readable form. */
    double done_mb = (double)bytes_done / (1024.0 * 1024.0);
    double total_mb = (double)bytes_total / (1024.0 * 1024.0);
    if (bytes_total >= 1024 * 1024) {
        fprintf(out, "   %.1f MB / %.1f MB", done_mb, total_mb);
    } else {
        fprintf(out, "   %llu B / %llu B", (unsigned long long)bytes_done,
                (unsigned long long)bytes_total);
    }

    /* If this is the last update, end with newline. */
    if (current == total) {
        fprintf(out, "\n");
    }
    fflush(out);
}

/* ── Argument parsing ─────────────────────────────────────────────────── */

/*
 * We support two styles:
 *   Subcommand: blar create -o out.blar file1 file2
 *   Tar-style:  blar cf out.blar file1 file2
 *               blar -cf out.blar file1 file2
 *
 * Tar flag mapping:
 *   c = create, t = list, x = extract, V = verify, I = info, p = cat
 *   f = file (archive path follows)
 */

typedef enum {
    OP_NONE,
    OP_CREATE,
    OP_LIST,
    OP_EXTRACT,
    OP_VERIFY,
    OP_INFO,
    OP_CAT,
} operation_t;

static operation_t parse_tar_flags(const char *flags, bool *has_f) {
    operation_t op = OP_NONE;
    *has_f = false;
    for (const char *p = flags; *p; p++) {
        switch (*p) {
        case '-': break; /* skip leading hyphen */
        case 'c':
            if (op != OP_NONE) return OP_NONE; /* conflict */
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
        case 'f':
            *has_f = true;
            break;
        default:
            return OP_NONE; /* unknown flag */
        }
    }
    return op;
}

/* ── Main ─────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(stderr);
        return EXIT_USAGE;
    }

    const char *arg1 = argv[1];

    /* --help / -h */
    if (strcmp(arg1, "--help") == 0 || strcmp(arg1, "-h") == 0) {
        print_usage(stdout);
        return EXIT_OK;
    }

    /* --version */
    if (strcmp(arg1, "--version") == 0) {
        print_version();
        return EXIT_OK;
    }

    /* Subcommand style? */
    if (strcmp(arg1, "create") == 0) return cmd_create(argc - 2, argv + 2);
    if (strcmp(arg1, "list") == 0)   return cmd_list(argc - 2, argv + 2);
    if (strcmp(arg1, "extract") == 0) return cmd_extract(argc - 2, argv + 2);
    if (strcmp(arg1, "verify") == 0) return cmd_verify(argc - 2, argv + 2);
    if (strcmp(arg1, "info") == 0)   return cmd_info(argc - 2, argv + 2);
    if (strcmp(arg1, "cat") == 0)    return cmd_cat(argc - 2, argv + 2);

    /* Tar-style flags? e.g. "cf", "-cf", "tf", etc. */
    bool has_f = false;
    operation_t op = parse_tar_flags(arg1, &has_f);
    if (op != OP_NONE && has_f) {
        /* argv[2] is the archive file, rest depends on operation */
        switch (op) {
        case OP_CREATE:  return cmd_create(argc - 2, argv + 2);
        case OP_LIST:    return cmd_list(argc - 2, argv + 2);
        case OP_EXTRACT: return cmd_extract(argc - 2, argv + 2);
        case OP_VERIFY:  return cmd_verify(argc - 2, argv + 2);
        case OP_INFO:    return cmd_info(argc - 2, argv + 2);
        case OP_CAT:     return cmd_cat(argc - 2, argv + 2);
        case OP_NONE:    break; /* unreachable */
        }
    }

    fprintf(stderr, "blar: unknown command '%s'\n", arg1);
    print_usage(stderr);
    return EXIT_USAGE;
}

/* ── Help and version ─────────────────────────────────────────────────── */

static void print_usage(FILE *out) {
    fprintf(out,
        "Usage: blar <command> [options] [arguments]\n"
        "\n"
        "Commands:\n"
        "  create -o <archive> <files...>    Create a BLIP archive\n"
        "  list <archive>                    List files in archive\n"
        "  extract <archive> [-C <dir>]      Extract files from archive\n"
        "  verify <archive>                  Verify archive integrity\n"
        "  info <archive>                    Show archive information\n"
        "  cat <archive> <path>              Print file contents to stdout\n"
        "\n"
        "Tar-style shorthand (hyphen optional):\n"
        "  blar cf  <archive> <files...>     Create\n"
        "  blar tf  <archive>                List\n"
        "  blar xf  <archive> [-C <dir>]     Extract\n"
        "  blar Vf  <archive>                Verify\n"
        "  blar If  <archive>                Info\n"
        "  blar pf  <archive> <path>         Cat\n"
        "\n"
        "Options:\n"
        "  -h, --help       Show this help\n"
        "  --version        Show version\n"
    );
}

static void print_version(void) {
    printf("blar %s\n", BLAR_VERSION);
}

/* ── cmd_create ───────────────────────────────────────────────────────── */

/*
 * Subcommand form:  create -o <archive> file1 file2 ...
 * Tar-style form:   (entered as) cf <archive> file1 file2 ...
 *   In tar-style, argv[0] is the archive path, argv[1..] are files.
 *   In subcommand form, we parse -o <archive> and the rest are files.
 *
 * We detect which form by checking for "-o" in argv.
 */

static int cmd_create(int argc, char **argv) {
    const char *out_path = NULL;
    int file_start = 0;

    if (argc < 1) {
        fprintf(stderr, "blar: create: missing arguments\n");
        return EXIT_USAGE;
    }

    /* Check for -o flag (subcommand style) */
    if (argc >= 2 && strcmp(argv[0], "-o") == 0) {
        out_path = argv[1];
        file_start = 2;
    } else {
        /* Tar-style: first arg is the archive path */
        out_path = argv[0];
        file_start = 1;
    }

    int file_count = argc - file_start;
    if (file_count <= 0) {
        fprintf(stderr, "blar: create: no input files specified\n");
        return EXIT_USAGE;
    }

    /* Read all input files. */
    blip_file_entry *entries = calloc((size_t)file_count, sizeof(blip_file_entry));
    if (!entries) {
        fprintf(stderr, "blar: create: out of memory\n");
        return EXIT_IO;
    }

    bool show_progress = isatty(STDERR_FILENO);
    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;

    /* First pass: get total size for progress bar. */
    if (show_progress) {
        for (int i = 0; i < file_count; i++) {
            struct stat st;
            if (stat(argv[file_start + i], &st) == 0) {
                total_bytes += (uint64_t)st.st_size;
            }
        }
    }

    for (int i = 0; i < file_count; i++) {
        const char *path = argv[file_start + i];
        size_t content_len = 0;
        uint8_t *content = read_file(path, &content_len);
        if (!content) {
            fprintf(stderr, "blar: create: cannot open '%s': %s\n",
                    path, strerror(errno));
            /* Clean up already-read entries. */
            for (int j = 0; j < i; j++) {
                free((void *)entries[j].content);
            }
            free(entries);
            return EXIT_IO;
        }
        entries[i].path = path;
        entries[i].path_len = strlen(path);
        entries[i].content = content;
        entries[i].content_len = content_len;

        if (show_progress) {
            bytes_done += content_len;
            progress_bar(stderr, (uint64_t)(i + 1), (uint64_t)file_count,
                         bytes_done, total_bytes);
        }
    }

    /* Create the archive. */
    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    int32_t rc = blip_archive_create(entries, (size_t)file_count,
                                      &archive_buf, &archive_len);

    /* Free input file buffers. */
    for (int i = 0; i < file_count; i++) {
        free((void *)entries[i].content);
    }
    free(entries);

    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: create: %s\n", blip_error_string(rc));
        return EXIT_IO;
    }

    /* Write the archive to disk. */
    if (!write_file(out_path, archive_buf, archive_len)) {
        fprintf(stderr, "blar: create: cannot write '%s': %s\n",
                out_path, strerror(errno));
        blip_free(archive_buf, archive_len);
        return EXIT_IO;
    }

    blip_free(archive_buf, archive_len);
    return EXIT_OK;
}

/* ── cmd_list ─────────────────────────────────────────────────────────── */

static int cmd_list(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: list: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: list: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: list: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: list: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }
        fwrite(path, 1, path_len, stdout);
        fputc('\n', stdout);
    }

    free(buf);
    return EXIT_OK;
}

/* ── cmd_extract ──────────────────────────────────────────────────────── */

static int cmd_extract(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: extract: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *output_dir = NULL;

    /* Parse optional -C <dir> */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-C") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: extract: -C requires an argument\n");
                return EXIT_USAGE;
            }
            output_dir = argv[i + 1];
            i++;
        }
    }

    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: extract: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: extract: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    bool show_progress = isatty(STDERR_FILENO);
    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;

    /* First pass to get total bytes for progress bar. */
    if (show_progress) {
        for (uint64_t i = 0; i < count; i++) {
            const uint8_t *data = NULL;
            size_t data_len = 0;
            if (blip_archive_file_content(buf, buf_len, i, &data, &data_len) == BLIP_OK) {
                total_bytes += data_len;
            }
        }
    }

    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: extract: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: extract: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        /* Build the output path. */
        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)path_len, path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                fprintf(stderr, "blar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                fprintf(stderr, "blar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
            memcpy(out_path, path, path_len);
            out_path[path_len] = '\0';
        }

        /* Ensure parent directories exist. */
        if (!ensure_parent_dir(out_path)) {
            fprintf(stderr, "blar: extract: cannot create directory for '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        if (!write_file(out_path, data, data_len)) {
            fprintf(stderr, "blar: extract: cannot write '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        if (show_progress) {
            bytes_done += data_len;
            progress_bar(stderr, i + 1, count, bytes_done, total_bytes);
        }
    }

    free(buf);
    return EXIT_OK;
}

/* ── cmd_verify ───────────────────────────────────────────────────────── */

static int cmd_verify(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: verify: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: verify: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    /* Verify outer archive hash. */
    if (!blip_archive_verify(buf, buf_len)) {
        fprintf(stderr, "blar: verify: archive hash mismatch\n");
        free(buf);
        return EXIT_VERIFY;
    }

    /* Verify each file's individual hash. */
    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: verify: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    for (uint64_t i = 0; i < count; i++) {
        rc = blip_archive_file_verify(buf, buf_len, i);
        if (rc != BLIP_OK) {
            const char *path = NULL;
            size_t path_len = 0;
            blip_archive_file_path(buf, buf_len, i, &path, &path_len);
            fprintf(stderr, "blar: verify: file %llu", (unsigned long long)i);
            if (path) {
                fprintf(stderr, " ('%.*s')", (int)path_len, path);
            }
            fprintf(stderr, ": %s\n", blip_error_string(rc));
            free(buf);
            return EXIT_VERIFY;
        }
    }

    printf("OK: %llu files verified\n", (unsigned long long)count);
    free(buf);
    return EXIT_OK;
}

/* ── cmd_info ─────────────────────────────────────────────────────────── */

static int cmd_info(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: info: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: info: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: info: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    printf("Archive: %s\n", archive_path);
    printf("Size:    %llu bytes\n", (unsigned long long)buf_len);
    printf("Files:   %llu\n", (unsigned long long)count);
    printf("\n");

    uint64_t total_content = 0;
    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: info: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: info: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        printf("  %8llu  %.*s\n", (unsigned long long)data_len,
               (int)path_len, path);
        total_content += data_len;
    }

    printf("\n");
    printf("Total content: %llu bytes\n", (unsigned long long)total_content);

    /* Integrity check. */
    bool ok = blip_archive_verify(buf, buf_len);
    if (ok) {
        /* Also check individual files. */
        for (uint64_t i = 0; i < count; i++) {
            if (blip_archive_file_verify(buf, buf_len, i) != BLIP_OK) {
                ok = false;
                break;
            }
        }
    }
    printf("Integrity: %s\n", ok ? "OK" : "FAILED");

    free(buf);
    return ok ? EXIT_OK : EXIT_VERIFY;
}

/* ── cmd_cat ──────────────────────────────────────────────────────────── */

static int cmd_cat(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "blar: cat: requires <archive> <path>\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *file_path = argv[1];

    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: cat: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    const uint8_t *data = NULL;
    size_t data_len = 0;
    int32_t rc = blip_archive_file_content_by_path(
        buf, buf_len, file_path, strlen(file_path), &data, &data_len);

    if (rc == BLIP_ERR_NOT_FOUND) {
        fprintf(stderr, "blar: cat: file not found in archive: '%s'\n", file_path);
        free(buf);
        return EXIT_VERIFY;
    } else if (rc != BLIP_OK) {
        fprintf(stderr, "blar: cat: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    if (data_len > 0) {
        fwrite(data, 1, data_len, stdout);
    }

    free(buf);
    return EXIT_OK;
}
