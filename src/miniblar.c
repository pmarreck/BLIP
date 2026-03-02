/*
 * miniblar -- Minimal BLIP Archive CLI
 *
 * Creates flat miniBlar archives (FILE entries only, no directory support,
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
static int cmd_poke(int argc, char **argv);
static int cmd_to_json(int argc, char **argv);
static int cmd_from_json(int argc, char **argv);
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
    if (strcmp(arg1, "poke") == 0)   return cmd_poke(argc - 2, argv + 2);
    if (strcmp(arg1, "to-json") == 0) return cmd_to_json(argc - 2, argv + 2);
    if (strcmp(arg1, "from-json") == 0) return cmd_from_json(argc - 2, argv + 2);

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
        case OP_POKE:    return cmd_poke(argc - 2, argv + 2);
        case OP_TO_JSON: return cmd_to_json(argc - 2, argv + 2);
        case OP_FROM_JSON: return cmd_from_json(argc - 2, argv + 2);
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
        "  create [-z [algo]] [-o <archive>] <files...>   Create a BLIP archive\n"
        "  list <archive>                     List files in archive\n"
        "  extract <archive> [-C <dir>]       Extract files from archive\n"
        "  verify <archive>                   Verify archive integrity\n"
        "  info <archive>                     Show archive information\n"
        "  cat <archive> <path>               Print file contents to stdout\n"
        "  peek <archive> [<path>] [flags]    Inspect archive structure\n"
        "  poke <archive> <path> [options]    Modify a value in archive\n"
        "  to-json <archive>                 Convert archive to JSON (stdout)\n"
        "  from-json [-o <archive>] [<json>] Convert JSON to archive\n"
        "\n"
        "Tar-style shorthand (hyphen optional):\n"
        "  miniblar cf  <archive> <files...>  Create\n"
        "  miniblar tf  <archive>             List\n"
        "  miniblar xf  <archive> [-C <dir>]  Extract\n"
        "  miniblar Vf  <archive>             Verify\n"
        "  miniblar If  <archive>             Info\n"
        "  miniblar pf  <archive> <path>      Cat\n"
        "  miniblar kf  <archive> [<path>]    Peek\n"
        "  miniblar Kf  <archive> <path>      Poke\n"
        "  miniblar jf  <archive>             To-JSON\n"
        "  miniblar Jf  ... -o <archive>      From-JSON\n"
        "\n"
        "Tar-style flags:\n"
        "  P                              Absolute names (preserve leading /)\n"
        "\n"
        "Options:\n"
        "  -z [algo]        Compress (lzma2=default, bzip2, lz4, zstd)\n"
        "  --absolute-names Preserve absolute paths in archive\n"
        "  -h, --help       Show this help\n"
        "  --version        Show version\n"
    );
}

static void print_version(void) {
    printf("miniblar %s\n", BLAR_VERSION);
}

/* ── Progress callbacks for FFI operations ────────────────────────────── */

static void create_progress_cb(uint64_t entries_done, uint64_t bytes_done,
                                void *user_ctx) {
    progrez_ctx *progress = (progrez_ctx *)user_ctx;
    if (progress) progrez_update(progress, entries_done, bytes_done);
}

static void compress_progress_cb(uint64_t bytes_done, uint64_t bytes_total,
                                  void *user_ctx) {
    (void)bytes_total;
    progrez_ctx *progress = (progrez_ctx *)user_ctx;
    if (progress) progrez_update(progress, 0, bytes_done);
}

static void write_progress_cb(uint64_t bytes_written, void *user_ctx) {
    progrez_ctx *progress = (progrez_ctx *)user_ctx;
    if (progress) progrez_update(progress, 0, bytes_written);
}

static void phase_cb(const uint8_t *label, size_t label_len, void *user_ctx) {
    progrez_ctx *progress = (progrez_ctx *)user_ctx;
    if (!progress) return;
    char buf[64];
    size_t n = label_len < sizeof(buf) - 1 ? label_len : sizeof(buf) - 1;
    memcpy(buf, label, n);
    buf[n] = '\0';
    progrez_set_label(progress, buf);
    progrez_set_indeterminate(progress);
}

/* ── cmd_create ───────────────────────────────────────────────────────── */

static int cmd_create(int argc, char **argv) {
    const char *out_path = NULL;
    int file_start = 0;
    bool absolute_names = g_absolute_names;
    uint8_t compress_algo = 0;  /* 0 = no compression */

    if (argc < 1) {
        fprintf(stderr, "miniblar: create: missing arguments\n");
        return EXIT_USAGE;
    }

    /* Scan for --absolute-names, -z, and -o before positional parsing.
     * Named options can appear anywhere in the argument list. */
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--absolute-names") == 0) {
            absolute_names = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "-z") == 0) {
            compress_algo = BLIP_COMP_LZMA2; /* default */
            /* Check for optional algorithm argument */
            if (i + 1 < argc && argv[i+1][0] != '-') {
                const char *algo = argv[i+1];
                if (strcmp(algo, "lzma2") == 0 || strcmp(algo, "lzma") == 0) {
                    compress_algo = BLIP_COMP_LZMA2;
                    for (int j = i+1; j < argc - 1; j++) argv[j] = argv[j + 1];
                    argc--;
                } else if (strcmp(algo, "bzip2") == 0 || strcmp(algo, "bz2") == 0) {
                    compress_algo = BLIP_COMP_BZIP2;
                    for (int j = i+1; j < argc - 1; j++) argv[j] = argv[j + 1];
                    argc--;
                } else if (strcmp(algo, "lz4") == 0) {
                    compress_algo = BLIP_COMP_LZ4;
                    for (int j = i+1; j < argc - 1; j++) argv[j] = argv[j + 1];
                    argc--;
                } else if (strcmp(algo, "zstd") == 0 || strcmp(algo, "zst") == 0) {
                    compress_algo = BLIP_COMP_ZSTD;
                    for (int j = i+1; j < argc - 1; j++) argv[j] = argv[j + 1];
                    argc--;
                }
                /* else: not an algo name, don't consume */
            }
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "miniblar: create: -o requires an argument\n");
                return EXIT_USAGE;
            }
            out_path = argv[i + 1];
            /* Remove -o and its argument from argv */
            for (int j = i; j < argc - 2; j++) argv[j] = argv[j + 2];
            argc -= 2;
            i--;
        }
    }

    /* If no -o was given, check if first arg is a non-existent path
     * (tar-style: cf <archive> <files...>). Otherwise all args are inputs. */
    file_start = 0;
    if (!out_path && argc >= 1) {
        struct stat st_check;
        if (stat(argv[0], &st_check) != 0) {
            /* First arg doesn't exist — treat as output path (tar-style) */
            out_path = argv[0];
            file_start = 1;
        }
    }
    int file_count = argc - file_start;

    if (file_count <= 0) {
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

    /* If no -o was given, generate default name for single input.
     * Multiple inputs without -o is an error. */
    char default_out[4096];
    if (!out_path) {
        if (file_count > 1) {
            fprintf(stderr, "miniblar: create: multiple inputs require -o <archive>\n");
            return EXIT_USAGE;
        }
        if (!default_output_name(argv[0], ".mblar", default_out, sizeof(default_out))) {
            fprintf(stderr, "miniblar: create: cannot generate output name\n");
            return EXIT_USAGE;
        }
        out_path = default_out;
    }

    /* Append .mblar extension if the output path has no extension */
    {
        const char *base = strrchr(out_path, '/');
        base = base ? base + 1 : out_path;
        if (!strchr(base, '.')) {
            size_t olen = strlen(out_path);
            if (olen + 6 + 1 > sizeof(default_out)) {
                fprintf(stderr, "miniblar: create: output path too long\n");
                return EXIT_USAGE;
            }
            if (out_path != default_out) {
                memcpy(default_out, out_path, olen);
            }
            memcpy(default_out + olen, ".mblar", 6);
            default_out[olen + 6] = '\0';
            out_path = default_out;
        }
    }

    /* Read all input files and collect metadata. */
    blip_archive_entry *entries = calloc((size_t)file_count, sizeof(blip_archive_entry));
    if (!entries) {
        fprintf(stderr, "miniblar: create: out of memory\n");
        return EXIT_IO;
    }

    uint64_t bytes_done = 0;

    /* Progress: indeterminate scanning phase */
    progrez_ctx *progress = progrez_create("Scanning");
    if (progress) {
        progrez_set_identity(progress, "miniblar", "archive creation");
        progrez_set_indeterminate(progress);
    }

    for (int i = 0; i < file_count; i++) {
        const char *path = argv[file_start + i];
        size_t content_len = 0;
        uint8_t *content = read_file(path, &content_len);
        if (!content) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
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

        bytes_done += content_len;
        if (progress) progrez_update(progress, (uint64_t)(i + 1), bytes_done);
    }

    /* Progress: switch to determinate "Creating" phase.
     * The FFI now calls back per-entry so we get real progress. */
    if (progress) {
        progrez_set_label(progress, "Creating");
        progrez_set_determinate(progress, (uint64_t)file_count, bytes_done);
    }

    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    uint32_t create_flags = absolute_names ? BLIP_ARCHIVE_ABSOLUTE_PATHS : 0;
    int32_t rc = blip_archive_create_full(entries, (size_t)file_count, create_flags,
                                           progress ? create_progress_cb : NULL,
                                           progress ? phase_cb : NULL,
                                           progress,
                                           &archive_buf, &archive_len);

    for (int i = 0; i < file_count; i++) {
        free((void *)entries[i].content);
    }
    free(entries);

    if (rc != BLIP_OK) {
        if (progress) { progrez_finish(progress); progrez_destroy(progress); }
        fprintf(stderr, "miniblar: create: %s\n", blip_error_string(rc));
        return EXIT_IO;
    }

    /* Optionally compress */
    if (compress_algo != 0) {
        if (progress) {
            progrez_set_label(progress, "Compressing");
            progrez_set_determinate(progress, 0, archive_len);
        }
        uint8_t *compressed_buf = NULL;
        size_t compressed_len = 0;
        rc = blip_compress_container(archive_buf, archive_len, compress_algo,
                                      progress ? compress_progress_cb : NULL,
                                      progress ? phase_cb : NULL,
                                      progress,
                                      &compressed_buf, &compressed_len);
        blip_free(archive_buf, archive_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "miniblar: create: compression failed: %s\n",
                    blip_error_string(rc));
            return EXIT_IO;
        }
        archive_buf = compressed_buf;
        archive_len = compressed_len;
    }

    if (progress) {
        progrez_set_label(progress, "Writing");
        progrez_set_determinate(progress, 0, archive_len);
    }

    if (!(progress ? write_file_progress(out_path, archive_buf, archive_len, write_progress_cb, progress)
                   : write_file(out_path, archive_buf, archive_len))) {
        if (progress) { progrez_finish(progress); progrez_destroy(progress); }
        fprintf(stderr, "miniblar: create: cannot write '%s': %s\n",
                out_path, strerror(errno));
        blip_free(archive_buf, archive_len);
        return EXIT_IO;
    }

    if (progress) { progrez_finish(progress); progrez_destroy(progress); }
    char size_buf[32];
    fprintf(stderr, "Created %s (%s)\n", out_path,
            format_size(archive_len, size_buf, sizeof(size_buf)));
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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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

    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;

    /* Count total bytes for progress */
    for (uint64_t i = 0; i < count; i++) {
        const uint8_t *data = NULL;
        size_t data_len = 0;
        if (blip_archive_file_content(buf, buf_len, i, &data, &data_len) == BLIP_OK) {
            total_bytes += data_len;
        }
    }

    /* Progress: determinate extraction phase */
    progrez_ctx *progress = progrez_create("Extracting");
    if (progress) {
        progrez_set_identity(progress, "miniblar", "archive extraction");
        progrez_set_determinate(progress, count, total_bytes);
    }

    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "miniblar: extract: file %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
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
                if (progress) { progrez_finish(progress); progrez_destroy(progress); }
                fprintf(stderr, "miniblar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                if (progress) { progrez_finish(progress); progrez_destroy(progress); }
                fprintf(stderr, "miniblar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
            memcpy(out_path, path, path_len);
            out_path[path_len] = '\0';
        }

        if (!ensure_parent_dir(out_path)) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "miniblar: extract: cannot create directory for '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        if (!write_file(out_path, data, data_len)) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
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

        bytes_done += data_len;
        if (progress) progrez_update(progress, i + 1, bytes_done);
    }

    if (progress) { progrez_finish(progress); progrez_destroy(progress); }
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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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

/* ── cmd_poke ─────────────────────────────────────────────────────────── */

static int cmd_poke(int argc, char **argv) {
    return cmd_poke_common("miniblar", argc, argv);
}

/* ── cmd_to_json ──────────────────────────────────────────────────────── */

static int cmd_to_json(int argc, char **argv) {
    return cmd_to_json_common("miniblar", argc, argv);
}

/* ── cmd_from_json ────────────────────────────────────────────────────── */

static int cmd_from_json(int argc, char **argv) {
    return cmd_from_json_common("miniblar", argc, argv);
}
