/*
 * miniblar -- Minimal BLIP Archive CLI
 *
 * Creates flat miniBLIP archives (FILE entries only, no directory support,
 * no metadata). For full directory and metadata support, use blar.
 *
 * Usage:
 *   miniblar create [-o <archive>] <files...>
 *   miniblar list <archive>
 *   miniblar extract <archive> [-C dir]
 *   miniblar verify <archive>
 *   miniblar info <archive>
 *   miniblar cat <archive> <path>
 *
 * Tar-style shorthand (hyphen optional):
 *   miniblar cf  <archive> <files...>
 *   miniblar tf  <archive>
 *   miniblar xf  <archive> [-C <dir>]
 *   miniblar Vf  <archive>
 *   miniblar If  <archive>
 *   miniblar pf  <archive> <path>
 */

#include "blar_common.h"

#include <fcntl.h>
#include <time.h>

/* ── Module-scoped state ──────────────────────────────────────────────── */

static bool g_absolute_names = false;

/* ── Forward declarations ─────────────────────────────────────────────── */

static int cmd_create(int argc, char **argv);
static int cmd_list(int argc, char **argv);
static int cmd_extract(int argc, char **argv);
static int cmd_verify(int argc, char **argv);
static int cmd_info(int argc, char **argv);
static int cmd_cat(int argc, char **argv);
static int cmd_peek(int argc, char **argv);
static void print_usage(FILE *out);
static void print_version(void);

/* ── Main ─────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(stderr);
        return EXIT_USAGE;
    }

    const char *arg1 = argv[1];

    if (strcmp(arg1, "--help") == 0 || strcmp(arg1, "-h") == 0) {
        print_usage(stdout);
        return EXIT_OK;
    }

    if (strcmp(arg1, "--version") == 0) {
        print_version();
        return EXIT_OK;
    }

    if (strcmp(arg1, "create") == 0) return cmd_create(argc - 2, argv + 2);
    if (strcmp(arg1, "list") == 0)   return cmd_list(argc - 2, argv + 2);
    if (strcmp(arg1, "extract") == 0) return cmd_extract(argc - 2, argv + 2);
    if (strcmp(arg1, "verify") == 0) return cmd_verify(argc - 2, argv + 2);
    if (strcmp(arg1, "info") == 0)   return cmd_info(argc - 2, argv + 2);
    if (strcmp(arg1, "cat") == 0)    return cmd_cat(argc - 2, argv + 2);
    if (strcmp(arg1, "peek") == 0)   return cmd_peek(argc - 2, argv + 2);

    bool has_f = false;
    operation_t op = parse_tar_flags(arg1, &has_f);
    if (op != OP_NONE && has_f) {
        if (tar_flags_has_P(arg1)) g_absolute_names = true;
        switch (op) {
        case OP_CREATE:  return cmd_create(argc - 2, argv + 2);
        case OP_LIST:    return cmd_list(argc - 2, argv + 2);
        case OP_EXTRACT: return cmd_extract(argc - 2, argv + 2);
        case OP_VERIFY:  return cmd_verify(argc - 2, argv + 2);
        case OP_INFO:    return cmd_info(argc - 2, argv + 2);
        case OP_CAT:     return cmd_cat(argc - 2, argv + 2);
        case OP_PEEK:    return cmd_peek(argc - 2, argv + 2);
        case OP_NONE:    break;
        }
    }

    fprintf(stderr, "miniblar: unknown command '%s'\n", arg1);
    print_usage(stderr);
    return EXIT_USAGE;
}

/* ── Help and version ─────────────────────────────────────────────────── */

static void print_usage(FILE *out) {
    fprintf(out,
        "Usage: miniblar <command> [options] [arguments]\n"
        "\n"
        "Minimal BLIP archive tool (flat files only, no directories).\n"
        "For directory support and metadata, use 'blar'.\n"
        "\n"
        "Commands:\n"
        "  create [-o <archive>] <files...>   Create a BLIP archive\n"
        "  list <archive>                     List files in archive\n"
        "  extract <archive> [-C <dir>]       Extract files from archive\n"
        "  verify <archive>                   Verify archive integrity\n"
        "  info <archive>                     Show archive information\n"
        "  cat <archive> <path>               Print file contents to stdout\n"
        "  peek <archive> [<path>] [flags]    Inspect archive structure\n"
        "\n"
        "Tar-style shorthand (hyphen optional):\n"
        "  miniblar cf  <archive> <files...>  Create\n"
        "  miniblar tf  <archive>             List\n"
        "  miniblar xf  <archive> [-C <dir>]  Extract\n"
        "  miniblar Vf  <archive>             Verify\n"
        "  miniblar If  <archive>             Info\n"
        "  miniblar pf  <archive> <path>      Cat\n"
        "  miniblar kf  <archive> [<path>]    Peek\n"
        "\n"
        "Tar-style flags:\n"
        "  P                              Absolute names (preserve leading /)\n"
        "\n"
        "Options:\n"
        "  --absolute-names Preserve absolute paths in archive\n"
        "  -h, --help       Show this help\n"
        "  --version        Show version\n"
    );
}

static void print_version(void) {
    printf("miniblar %s\n", BLAR_VERSION);
}

/* ── cmd_create ───────────────────────────────────────────────────────── */

static int cmd_create(int argc, char **argv) {
    const char *out_path = NULL;
    int file_start = 0;
    bool absolute_names = g_absolute_names;

    if (argc < 1) {
        fprintf(stderr, "miniblar: create: missing arguments\n");
        return EXIT_USAGE;
    }

    /* Scan for --absolute-names before positional parsing */
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--absolute-names") == 0) {
            absolute_names = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        }
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

    /* If no -o was specified and there's only one argument that looks like
     * an input file (not an archive path), generate default output name */
    char default_out[4096];
    if (file_count <= 0) {
        /* If we had -o flag, then out_path is set but no files given */
        fprintf(stderr, "miniblar: create: no input files specified\n");
        return EXIT_USAGE;
    }

    /* Reject directory arguments */
    for (int i = 0; i < file_count; i++) {
        struct stat st;
        if (stat(argv[file_start + i], &st) == 0 && S_ISDIR(st.st_mode)) {
            fprintf(stderr, "miniblar: create: '%s' is a directory "
                    "(use blar for directory support)\n", argv[file_start + i]);
            return EXIT_USAGE;
        }
    }

    /* Default output: single input file -> <basename>.mblar */
    if (file_count == 1 && file_start == 1) {
        /* Tar-style with single file: argv[0] was treated as archive path.
         * We need to check if it's actually a file and use default naming. */
        struct stat st;
        if (stat(out_path, &st) == 0) {
            /* out_path exists as a file, so this is likely: miniblar create file.txt
             * Treat it as single input, generate default output */
            const char *input = out_path;
            if (!default_output_name(input, ".mblar", default_out, sizeof(default_out))) {
                fprintf(stderr, "miniblar: create: cannot generate output name\n");
                return EXIT_USAGE;
            }
            out_path = default_out;
            /* Re-parse: the single arg is the input file */
            file_start = 0;
            file_count = 1;
        }
    }

    /* Read all input files and collect metadata. */
    blip_archive_entry *entries = calloc((size_t)file_count, sizeof(blip_archive_entry));
    if (!entries) {
        fprintf(stderr, "miniblar: create: out of memory\n");
        return EXIT_IO;
    }

    bool show_progress = isatty(STDERR_FILENO);
    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;

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
            fprintf(stderr, "miniblar: create: cannot open '%s': %s\n",
                    path, strerror(errno));
            for (int j = 0; j < i; j++) {
                free((void *)entries[j].content);
            }
            free(entries);
            return EXIT_IO;
        }

        memset(&entries[i], 0, sizeof(entries[i]));
        entries[i].path = path;
        entries[i].path_len = strlen(path);
        entries[i].content = content;
        entries[i].content_len = content_len;
        entries[i].is_dir = 0;

        /* Collect file metadata */
        struct stat st;
        if (stat(path, &st) == 0) {
            fill_entry_metadata(&entries[i], &st);
        }

        if (show_progress) {
            bytes_done += content_len;
            progress_bar(stderr, (uint64_t)(i + 1), (uint64_t)file_count,
                         bytes_done, total_bytes);
        }
    }

    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    uint32_t create_flags = absolute_names ? BLIP_ARCHIVE_ABSOLUTE_PATHS : 0;
    int32_t rc = blip_archive_create_full(entries, (size_t)file_count, create_flags,
                                           &archive_buf, &archive_len);

    for (int i = 0; i < file_count; i++) {
        free((void *)entries[i].content);
    }
    free(entries);

    if (rc != BLIP_OK) {
        fprintf(stderr, "miniblar: create: %s\n", blip_error_string(rc));
        return EXIT_IO;
    }

    if (!write_file(out_path, archive_buf, archive_len)) {
        fprintf(stderr, "miniblar: create: cannot write '%s': %s\n",
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
        fprintf(stderr, "miniblar: list: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "miniblar: list: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "miniblar: list: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "miniblar: list: file %llu: %s\n",
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
        fprintf(stderr, "miniblar: extract: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *output_dir = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-C") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "miniblar: extract: -C requires an argument\n");
                return EXIT_USAGE;
            }
            output_dir = argv[i + 1];
            i++;
        }
    }

    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "miniblar: extract: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "miniblar: extract: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    bool show_progress = isatty(STDERR_FILENO);
    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;

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
            fprintf(stderr, "miniblar: extract: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "miniblar: extract: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)path_len, path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                fprintf(stderr, "miniblar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                fprintf(stderr, "miniblar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
            memcpy(out_path, path, path_len);
            out_path[path_len] = '\0';
        }

        if (!ensure_parent_dir(out_path)) {
            fprintf(stderr, "miniblar: extract: cannot create directory for '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        if (!write_file(out_path, data, data_len)) {
            fprintf(stderr, "miniblar: extract: cannot write '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        /* Restore file mode and mtime from archive metadata */
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
        fprintf(stderr, "miniblar: verify: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "miniblar: verify: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    if (!blip_archive_verify(buf, buf_len)) {
        fprintf(stderr, "miniblar: verify: archive hash mismatch\n");
        free(buf);
        return EXIT_VERIFY;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "miniblar: verify: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    for (uint64_t i = 0; i < count; i++) {
        rc = blip_archive_file_verify(buf, buf_len, i);
        if (rc != BLIP_OK) {
            const char *path = NULL;
            size_t path_len = 0;
            blip_archive_file_path(buf, buf_len, i, &path, &path_len);
            fprintf(stderr, "miniblar: verify: file %llu", (unsigned long long)i);
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
        fprintf(stderr, "miniblar: info: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "miniblar: info: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "miniblar: info: %s\n", blip_error_string(rc));
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
            fprintf(stderr, "miniblar: info: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "miniblar: info: file %llu: %s\n",
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

    bool ok = blip_archive_verify(buf, buf_len);
    if (ok) {
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
        fprintf(stderr, "miniblar: cat: requires <archive> <path>\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *file_path = argv[1];

    size_t buf_len = 0;
    uint8_t *buf = read_file(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "miniblar: cat: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    const uint8_t *data = NULL;
    size_t data_len = 0;
    int32_t rc = blip_archive_file_content_by_path(
        buf, buf_len, file_path, strlen(file_path), &data, &data_len);

    if (rc == BLIP_ERR_NOT_FOUND) {
        fprintf(stderr, "miniblar: cat: file not found in archive: '%s'\n", file_path);
        free(buf);
        return EXIT_VERIFY;
    } else if (rc != BLIP_OK) {
        fprintf(stderr, "miniblar: cat: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    if (data_len > 0) {
        fwrite(data, 1, data_len, stdout);
    }

    free(buf);
    return EXIT_OK;
}

/* ── cmd_peek ─────────────────────────────────────────────────────────── */

static int cmd_peek(int argc, char **argv) {
    return cmd_peek_common("miniblar", argc, argv);
}
