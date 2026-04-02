/*
 * blar -- Full BLIP Archive CLI
 *
 * A tar-like command-line tool for creating and manipulating BLIP archives
 * with directory support and file metadata (mode, mtime, owner).
 *
 * Usage:
 *   blar create [-o <archive>] <files/dirs...>
 *   blar list <archive>
 *   blar extract <archive> [-C dir]
 *   blar verify <archive>
 *   blar info [--json] <archive>
 *   blar cat <archive> <path>
 *
 * Tar-style shorthand (hyphen optional):
 *   blar cf  <archive> <files/dirs...>
 *   blar tf  <archive>
 *   blar xf  <archive> [-C <dir>]
 *   blar Vf  <archive>
 *   blar If  <archive>
 *   blar pf  <archive> <path>
 */

#include "blar_common.h"


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
static int cmd_text(int argc, char **argv);
static int cmd_from_text(int argc, char **argv);
static int cmd_explode(int argc, char **argv);
static int cmd_implode(int argc, char **argv);
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
    if (strcmp(arg1, "--about") == 0) {
#ifdef __aarch64__
        printf("blar %s -- BLAR archive tool (aarch64)\n", BLAR_VERSION);
#elif defined(__x86_64__)
        printf("blar %s -- BLAR archive tool (x86_64)\n", BLAR_VERSION);
#else
        printf("blar %s -- BLAR archive tool\n", BLAR_VERSION);
#endif
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
    if (strcmp(arg1, "text") == 0) return cmd_text(argc - 2, argv + 2);
    if (strcmp(arg1, "from-text") == 0) return cmd_from_text(argc - 2, argv + 2);
    if (strcmp(arg1, "explode") == 0) return cmd_explode(argc - 2, argv + 2);
    if (strcmp(arg1, "implode") == 0) return cmd_implode(argc - 2, argv + 2);

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

    /* Smart defaults: infer command from first argument */

    /* Check if any argument is -z (implies create with compression) */
    bool has_z = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-z") == 0) { has_z = true; break; }
    }

    /* Check if first arg looks like a .blar file (by extension or magic) */
    size_t arg1_len = strlen(arg1);
    bool looks_like_blar = false;
    if (arg1_len > 5 && strcmp(arg1 + arg1_len - 5, ".blar") == 0) {
        looks_like_blar = true;
    } else {
        /* Check magic bytes */
        FILE *f = fopen(arg1, "rb");
        if (f) {
            uint8_t magic[8];
            size_t n = fread(magic, 1, sizeof(magic), f);
            fclose(f);
            if (n >= 5 && (blip_is_compressed(magic, n) ||
                           blip_is_encrypted(magic, n))) {
                looks_like_blar = true;
            } else if (n >= 5) {
                /* Check for BLAR/MBAR magic inside the outer ARRAY */
                /* Simple heuristic: not a known archive format → check stat */
            }
        }
    }

    if (looks_like_blar && !has_z) {
        /* .blar file without -z → default to extract */
        return cmd_extract(argc - 1, argv + 1);
    }

    /* Check if first arg is an existing file or directory → default to create */
    struct stat st_smart;
    if (stat(arg1, &st_smart) == 0) {
        /* Existing path → create archive from it */
        return cmd_create(argc - 1, argv + 1);
    }

    /* -z flag present but no recognized command → create with compression */
    if (has_z) {
        return cmd_create(argc - 1, argv + 1);
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
        "Full BLIP archive tool with directory and metadata support.\n"
        "For flat file-only archives, use 'miniblar'.\n"
        "\n"
        "Commands:\n"
        "  create [-z [algo]] [-e [cipher]] [-o <archive>] <files/dirs...>  Create archive\n"
        "  list <archive>                         List entries in archive\n"
        "  extract <archive> [-C <dir>]           Extract archive contents\n"
        "  verify <archive>                       Verify archive integrity\n"
        "  info [--json] <archive>                Show archive information\n"
        "  cat <archive> <path>                   Print file contents to stdout\n"
        "  peek <archive> [<path>] [flags]        Inspect archive structure\n"
        "  poke <archive> <path> [options]        Modify a value in archive\n"
        "  to-json <archive>                     Convert archive to JSON (stdout)\n"
        "  from-json [-o <archive>] [<json>]     Convert JSON to archive\n"
        "  text <archive> [-o <output>]          Dump as human-readable text\n"
        "  from-text <input.txt> -o <out.blar> [-z]  Rebuild archive from text\n"
        "  explode <archive> -C <output_dir>         Extract to dir tree + __meta__.json\n"
        "  implode <directory> -o <archive> [-z]      Rebuild archive from dir tree\n"
        "\n"
        "Smart defaults (no subcommand needed):\n"
        "  blar mydir/                            Create archive from directory\n"
        "  blar archive.blar                      Extract (detects .blar extension)\n"
        "  blar -z mydir/                         Create with compression\n"
        "\n"
        "Tar-style shorthand (hyphen optional):\n"
        "  blar cf  <archive> <files/dirs...>     Create\n"
        "  blar tf  <archive>                     List\n"
        "  blar xf  <archive> [-C <dir>]          Extract\n"
        "  blar Vf  <archive>                     Verify\n"
        "  blar If  <archive>                     Info\n"
        "  blar pf  <archive> <path>              Cat\n"
        "  blar kf  <archive> [<path>] [flags]    Peek\n"
        "  blar Kf  <archive> <path> [options]   Poke\n"
        "  blar jf  <archive>                    To-JSON\n"
        "  blar Jf  ... -o <archive>             From-JSON\n"
        "\n"
        "Tar-style flags:\n"
        "  P                             Absolute names (preserve leading /)\n"
        "\n"
        "Options:\n"
        "  -z [algo]        Compress (lzma2=default, bzip2, lz4, zstd)\n"
        "                   Default: per-file compression\n"
        "  --solid          Solid compression (whole archive, better ratio)\n"
        "                   Auto-enables MIME-type sorting\n"
        "  --no-sort        Disable MIME sorting (only with --solid)\n"
        "  -j <N>, --threads <N>  Thread count (0=auto, default: 0)\n"
        "  -f, --force      Overwrite without prompting (create and extract)\n"
        "  -e [cipher]      Encrypt archive (aes=default, chacha)\n"
        "                   Password: BLIP_PASSWORD env var, or interactive prompt\n"
        "  --kdf <name>     KDF for encryption (argon2=default, pbkdf2)\n"
        "  --streaming             Use streaming mode (low memory, for large archives)\n"
        "  --no-expand-containers  Don't expand containers (PDF/JPEG/PNG/BMP/TGA/\n"
        "                         TIFF/GIF/ZIP/gzip/tar/WAV/AIFF/FITS/DICOM/NIfTI)\n"
        "  --expand-all-zips      Also expand .zip files (normally opaque)\n"
        "  --absolute-names Preserve absolute paths in archive\n"
        "  -h, --help       Show this help\n"
        "  --version        Show version\n"
        "  --about          Show one-line description\n"
    );
}

static void print_version(void) {
    printf("blar %s\n", BLAR_VERSION);
}

/* ── Progress callbacks for FFI operations ────────────────────────────── */

static void create_progress_cb(uint64_t entries_done, uint64_t bytes_done,
                                void *user_ctx) {
    progrez_ctx *progress = (progrez_ctx *)user_ctx;
    if (progress) progrez_update(progress, entries_done, bytes_done);
}

static void compress_progress_cb(uint64_t bytes_done, uint64_t bytes_total,
                                  void *user_ctx) {
    (void)bytes_total; /* already set via progrez_set_determinate */
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
    /* Copy label to a null-terminated buffer for progrez_set_label */
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
    int input_start = 0;
    bool absolute_names = g_absolute_names;
    uint8_t compress_algo = 0;  /* 0 = no compression */
    bool solid_mode = false;    /* --solid: solid compression (old behavior) */
    bool no_sort = false;       /* --no-sort: disable MIME sorting in solid mode */
    uint8_t num_threads = 0;    /* 0 = auto */
    bool force = false;        /* -f/--force: overwrite without prompting */
    bool do_encrypt = false;
    uint8_t enc_id = 1;   /* default: AES-256-GCM */
    uint8_t kdf_id = 1;   /* default: Argon2id */
    bool no_expand = false;     /* --no-expand-containers */
    bool use_streaming = false; /* --streaming */
    bool expand_all = false;    /* --expand-all-zips */

    if (argc < 1) {
        fprintf(stderr, "blar: create: missing arguments\n");
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
        } else if (strcmp(argv[i], "-e") == 0) {
            do_encrypt = true;
            /* Check for optional cipher argument */
            if (i + 1 < argc && argv[i+1][0] != '-') {
                const char *cipher = argv[i+1];
                if (strcmp(cipher, "aes") == 0 || strcmp(cipher, "aes-256-gcm") == 0) {
                    enc_id = 1;
                    /* Consume the cipher arg */
                    for (int j = i+1; j < argc - 1; j++) argv[j] = argv[j + 1];
                    argc--;
                } else if (strcmp(cipher, "chacha") == 0 || strcmp(cipher, "chacha20") == 0 ||
                           strcmp(cipher, "chacha20-poly1305") == 0) {
                    enc_id = 2;
                    for (int j = i+1; j < argc - 1; j++) argv[j] = argv[j + 1];
                    argc--;
                }
                /* else: not a cipher name, don't consume it */
            }
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "--kdf") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: create: --kdf requires an argument\n");
                return EXIT_USAGE;
            }
            const char *kdf_name = argv[i+1];
            if (strcmp(kdf_name, "argon2") == 0 || strcmp(kdf_name, "argon2id") == 0) {
                kdf_id = 1;
            } else if (strcmp(kdf_name, "pbkdf2") == 0 || strcmp(kdf_name, "pbkdf2-sha256") == 0) {
                kdf_id = 2;
            } else {
                fprintf(stderr, "blar: create: unknown KDF '%s' (use 'argon2' or 'pbkdf2')\n", kdf_name);
                return EXIT_USAGE;
            }
            for (int j = i; j < argc - 2; j++) argv[j] = argv[j + 2];
            argc -= 2;
            i--;
        } else if (strcmp(argv[i], "--solid") == 0) {
            solid_mode = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--force") == 0) {
            force = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "--no-sort") == 0) {
            no_sort = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "--streaming") == 0) {
            use_streaming = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "--no-expand-containers") == 0) {
            no_expand = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "--expand-all-zips") == 0) {
            expand_all = true;
            for (int j = i; j < argc - 1; j++) argv[j] = argv[j + 1];
            argc--;
            i--;
        } else if (strcmp(argv[i], "-j") == 0 || strcmp(argv[i], "--threads") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: create: %s requires an argument\n", argv[i]);
                return EXIT_USAGE;
            }
            int t = atoi(argv[i+1]);
            if (t < 0 || t > 255) {
                fprintf(stderr, "blar: create: thread count must be 0-255\n");
                return EXIT_USAGE;
            }
            num_threads = (uint8_t)t;
            for (int j = i; j < argc - 2; j++) argv[j] = argv[j + 2];
            argc -= 2;
            i--;
        } else if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: create: -o requires an argument\n");
                return EXIT_USAGE;
            }
            out_path = argv[i + 1];
            for (int j = i; j < argc - 2; j++) argv[j] = argv[j + 2];
            argc -= 2;
            i--;
        }
    }

    /* If no -o was given, check if first arg is a non-existent path
     * (tar-style: cf <archive> <files...>). Otherwise all args are inputs. */
    input_start = 0;
    if (!out_path && argc >= 1) {
        struct stat st_check;
        if (stat(argv[0], &st_check) != 0) {
            /* First arg doesn't exist -- treat as output path (tar-style) */
            out_path = argv[0];
            input_start = 1;
        }
    }
    int input_count = argc - input_start;

    if (input_count <= 0) {
        fprintf(stderr, "blar: create: no input files/directories specified\n");
        return EXIT_USAGE;
    }

    /* If no -o was given, generate default name for single input.
     * Multiple inputs without -o is an error. */
    char default_out[4096];
    if (!out_path) {
        if (input_count > 1) {
            fprintf(stderr, "blar: create: multiple inputs require -o <archive>\n");
            return EXIT_USAGE;
        }
        if (!default_output_name(argv[0], ".blar", default_out, sizeof(default_out))) {
            fprintf(stderr, "blar: create: cannot generate output name\n");
            return EXIT_USAGE;
        }
        out_path = default_out;
    }

    /* Append .blar extension if the output path has no extension */
    {
        const char *base = strrchr(out_path, '/');
        base = base ? base + 1 : out_path;
        if (!strchr(base, '.')) {
            size_t olen = strlen(out_path);
            if (olen + 5 + 1 > sizeof(default_out)) {
                fprintf(stderr, "blar: create: output path too long\n");
                return EXIT_USAGE;
            }
            if (out_path != default_out) {
                memcpy(default_out, out_path, olen);
            }
            memcpy(default_out + olen, ".blar", 5);
            default_out[olen + 5] = '\0';
            out_path = default_out;
        }
    }

    /* Check for existing output file -- prompt before overwriting */
    if (!force) {
        struct stat out_st;
        if (stat(out_path, &out_st) == 0) {
            if (isatty(STDIN_FILENO)) {
                fprintf(stderr, "blar: '%s' already exists. Overwrite? (y/N) ", out_path);
                int ch = getchar();
                if (ch != 'y' && ch != 'Y') {
                    fprintf(stderr, "blar: not overwriting\n");
                    return EXIT_USAGE;
                }
                /* Consume rest of line */
                while (ch != '\n' && ch != EOF) ch = getchar();
            } else {
                fprintf(stderr, "blar: '%s' already exists (use -f to overwrite)\n", out_path);
                return EXIT_USAGE;
            }
        }
    }

    /* Collect all entries (files and directories, recursively) */
    entry_list_t el;
    entry_list_init(&el);
    /* Container expansion: enabled by default when -z is used */
    if (compress_algo != 0 && !no_expand) {
        el.expand_containers = true;
        el.expand_all_zips = expand_all;
    }
    el.num_threads = num_threads;

    /* Progress: indeterminate scanning phase */
    progrez_ctx *progress = progrez_create("Scanning");
    if (progress) {
        progrez_set_identity(progress, "blar", "archive creation");
        progrez_set_sparkline(progress, true);
        progrez_set_indeterminate(progress);
        el.progress = progress;
    }

    for (int i = 0; i < input_count; i++) {
        if (!collect_entries_recurse(argv[input_start + i], &el)) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            entry_list_free(&el);
            return EXIT_IO;
        }
    }

    if (el.count == 0) {
        if (progress) { progrez_finish(progress); progrez_destroy(progress); }
        fprintf(stderr, "blar: create: no entries to archive\n");
        entry_list_free(&el);
        return EXIT_USAGE;
    }

    /* Auto-detect streaming mode for large archives.
     * Threshold configurable via BLAR_STREAMING_THRESHOLD (bytes, default 1GB).
     * Set to 0 to always stream, or very large to never auto-stream. */
    if (!use_streaming) {
        uint64_t threshold = (uint64_t)1024 * 1024 * 1024; /* 1 GB default */
        const char *env_thresh = getenv("BLAR_STREAMING_THRESHOLD");
        if (env_thresh) {
            char *end;
            uint64_t val = strtoull(env_thresh, &end, 10);
            if (end != env_thresh) threshold = val;
        }
        uint64_t est_total = 0;
        for (size_t i = 0; i < el.count; i++) {
            if (!el.entries[i].is_dir)
                est_total += el.entries[i].content_len;
        }
        if (est_total > threshold) {
            fprintf(stderr, "blar: auto-selecting streaming mode (%.1f GB input, threshold %.1f GB)\n",
                    (double)est_total / (1024.0 * 1024.0 * 1024.0),
                    (double)threshold / (1024.0 * 1024.0 * 1024.0));
            use_streaming = true;
        }
    }

    /* ── Streaming path: low memory, processes files one at a time ── */
    if (use_streaming) {
        /* metadata_only was set before collection -- no file content loaded */

        uint8_t *archive_buf = NULL;
        size_t archive_len = 0;
        int32_t rc2 = blip_archive_create_streaming(
            el.entries, el.count,
            compress_algo,
            el.expand_containers, el.expand_all_zips,
            &archive_buf, &archive_len);

        entry_list_free(&el);
        if (rc2 != 0) {
            fprintf(stderr, "blar: create: streaming archive creation failed (rc=%d)\n", rc2);
            return EXIT_IO;
        }

        /* Write to output */
        if (!write_file(out_path, archive_buf, archive_len)) {
            fprintf(stderr, "blar: create: cannot write '%s': %s\n", out_path, strerror(errno));
            blip_free(archive_buf, archive_len);
            return EXIT_IO;
        }

        fprintf(stderr, "Created %s (%s, streaming mode)\n", out_path,
                format_size(archive_len, (char[32]){0}, 32));
        blip_free(archive_buf, archive_len);
        return EXIT_OK;
    }

    /* Container expansion pass: separate phase with its own progress bar */
    if (el.expand_containers) {
        if (!expand_containers_pass(&el)) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            entry_list_free(&el);
            return EXIT_IO;
        }
    }

    /* Progress: switch to determinate "Creating" phase.
     * The FFI now calls back per-entry so we get real progress.
     * Reset counters since scanning left them at final values. */
    if (progress) {
        progrez_set_label(progress, "Creating");
        progrez_set_determinate(progress, el.count, el.bytes_seen);
        progrez_update(progress, 0, 0);
    }

    /* Determine per-file vs solid compression.
     * Default when -z is used: per-file compression.
     * --solid: solid compression (wrap entire archive). */
    uint8_t per_file_comp = 0;
    if (compress_algo != 0 && !solid_mode) {
        per_file_comp = compress_algo;
    }

    /* MIME-sort entries for solid compression (improves ratio) */
    if (compress_algo != 0 && solid_mode && !no_sort) {
        mime_sort_entries(el.entries, el.count);
    }

    /* Create the archive via FFI (with progress callback) */
    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    uint32_t create_flags = absolute_names ? BLIP_ARCHIVE_ABSOLUTE_PATHS : 0;
    int32_t rc = blip_archive_create_full(el.entries, el.count, create_flags,
                                           per_file_comp, num_threads,
                                           progress ? create_progress_cb : NULL,
                                           progress ? phase_cb : NULL,
                                           progress,
                                           &archive_buf, &archive_len);
    uint64_t original_bytes = el.bytes_seen;
    entry_list_free(&el);

    if (rc != BLIP_OK) {
        if (progress) { progrez_finish(progress); progrez_destroy(progress); }
        fprintf(stderr, "blar: create: %s\n", blip_error_string(rc));
        return EXIT_IO;
    }

    /* Solid compression: wrap entire archive in one compressed LP */
    if (compress_algo != 0 && solid_mode) {
        if (progress) {
            progrez_set_label(progress, "Compressing");
            progrez_set_determinate(progress, 0, archive_len);
            progrez_update(progress, 0, 0);
        }
        uint8_t *compressed_buf = NULL;
        size_t compressed_len = 0;
        rc = blip_compress_container(archive_buf, archive_len, compress_algo, num_threads,
                                      progress ? compress_progress_cb : NULL,
                                      progress ? phase_cb : NULL,
                                      progress,
                                      &compressed_buf, &compressed_len);
        blip_free(archive_buf, archive_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: create: compression failed: %s\n",
                    blip_error_string(rc));
            return EXIT_IO;
        }
        archive_buf = compressed_buf;
        archive_len = compressed_len;
    }

    /* Optionally encrypt (outermost layer -- after compression) */
    if (do_encrypt) {
        if (progress) {
            progrez_set_label(progress, "Encrypting");
            progrez_set_indeterminate(progress);
        }
        const char *password = get_password();
        if (!password) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: create: password required for encryption\n");
            blip_free(archive_buf, archive_len);
            return EXIT_IO;
        }
        uint8_t *encrypted_buf = NULL;
        size_t encrypted_len = 0;
        rc = blip_encrypt_container(archive_buf, archive_len,
                                     password, strlen(password),
                                     enc_id, kdf_id,
                                     &encrypted_buf, &encrypted_len);
        blip_free(archive_buf, archive_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: create: encryption failed: %s\n",
                    blip_error_string(rc));
            return EXIT_IO;
        }
        archive_buf = encrypted_buf;
        archive_len = encrypted_len;
    }

    if (progress) {
        progrez_set_label(progress, "Writing");
        progrez_set_determinate(progress, 0, archive_len);
        progrez_update(progress, 0, 0);
    }

    if (!(progress ? write_file_progress(out_path, archive_buf, archive_len, write_progress_cb, progress)
                   : write_file(out_path, archive_buf, archive_len))) {
        if (progress) { progrez_finish(progress); progrez_destroy(progress); }
        fprintf(stderr, "blar: create: cannot write '%s': %s\n",
                out_path, strerror(errno));
        blip_free(archive_buf, archive_len);
        return EXIT_IO;
    }

    if (progress) { progrez_finish(progress); progrez_destroy(progress); }
    char size_buf[32];
    if (original_bytes > 0 && archive_len < original_bytes) {
        char orig_buf[32];
        double pct = (double)archive_len / (double)original_bytes * 100.0;
        fprintf(stderr, "Created %s (%s -> %s, %.2f%% of original)\n", out_path,
                format_size(original_bytes, orig_buf, sizeof(orig_buf)),
                format_size(archive_len, size_buf, sizeof(size_buf)), pct);
    } else {
        fprintf(stderr, "Created %s (%s)\n", out_path,
                format_size(archive_len, size_buf, sizeof(size_buf)));
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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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
        /* Get entry type */
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);
        char type_char = (entry_type == 0x07) ? 'd' : '-';

        /* Check for container DIR */
        if (entry_type == 0x07) {
            const char *co_type = NULL;
            size_t co_type_len = 0;
            if (blip_archive_entry_container_type(buf, buf_len, i,
                    &co_type, &co_type_len) == BLIP_OK && co_type != NULL) {
                const blar_codec_t *codec = blar_codec_find_by_name(&builtin_registry, co_type, co_type_len);
                if (codec) {
                    if (strcmp(codec->name, "pdf") == 0) type_char = 'p';
                    else if (strcmp(codec->name, "png") == 0) type_char = 'n';
                    else if (strcmp(codec->name, "jpeg") == 0) type_char = 'j';
                    else if (strcmp(codec->name, "gz") == 0) type_char = 'g';
                    else if (strcmp(codec->name, "bmp") == 0) type_char = 'b';
                    else if (strcmp(codec->name, "tar") == 0) type_char = 't';
                    else if (strcmp(codec->name, "tiff") == 0) type_char = 'i';
                    else if (strcmp(codec->name, "gif") == 0) type_char = 'f';
                    else if (strcmp(codec->name, "tga") == 0) type_char = 'a';
                    else if (strcmp(codec->name, "wav") == 0) type_char = 'w';
                    else if (strcmp(codec->name, "aiff") == 0) type_char = 'w';
                    else if (strcmp(codec->name, "fits") == 0) type_char = 's';
                    else if (strcmp(codec->name, "dicom") == 0) type_char = 'm';
                    else if (strcmp(codec->name, "nifti") == 0) type_char = 'r';
                    else type_char = 'z';
                } else {
                    type_char = '?';  /* unknown codec */
                }
            }
        }

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: list: entry %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }
        printf("%c %.*s\n", type_char, (int)path_len, path);
    }

    free(buf);
    return EXIT_OK;
}

/* ── cmd_extract ──────────────────────────────────────────────────────── */

/* Adapter callbacks: wrap progrez + fprintf for CLI use */
typedef struct {
    progrez_ctx *progress;
    uint64_t total_files;
    uint64_t total_bytes;
} extract_cli_ctx_t;

static void extract_cli_progress(uint64_t files_done, uint64_t bytes_done,
                                  uint64_t total_files, uint64_t total_bytes,
                                  void *ctx) {
    extract_cli_ctx_t *cli = (extract_cli_ctx_t *)ctx;
    if (!cli->progress) return;
    /* On first call (totals report), set up determinate mode */
    if (cli->total_files == 0 && total_files > 0) {
        cli->total_files = total_files;
        cli->total_bytes = total_bytes;
        progrez_set_determinate(cli->progress, total_files, total_bytes);
    }
    progrez_update(cli->progress, files_done, bytes_done);
}

static void extract_cli_log(const char *msg, void *ctx) {
    (void)ctx;
    fprintf(stderr, "%s\n", msg);
}

static int cmd_extract(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: extract: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *output_dir = NULL;
    bool force = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-C") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: extract: -C requires an argument\n");
                return EXIT_USAGE;
            }
            output_dir = argv[i + 1];
            i++;
        } else if (strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--force") == 0) {
            force = true;
        }
    }

    /* Check if output directory already has files -- warn unless --force */
    if (!force && output_dir) {
        struct stat out_st;
        if (stat(output_dir, &out_st) == 0 && S_ISDIR(out_st.st_mode)) {
            /* Directory exists -- check if non-empty */
            DIR *d = opendir(output_dir);
            if (d) {
                struct dirent *de;
                bool has_files = false;
                while ((de = readdir(d)) != NULL) {
                    if (de->d_name[0] == '.' && (de->d_name[1] == '\0' ||
                        (de->d_name[1] == '.' && de->d_name[2] == '\0')))
                        continue;
                    has_files = true;
                    break;
                }
                closedir(d);
                if (has_files) {
                    if (isatty(STDIN_FILENO)) {
                        fprintf(stderr, "blar: extract: '%s' is non-empty. "
                                "Overwrite existing files? (y/N) ", output_dir);
                        int ch = getchar();
                        if (ch != 'y' && ch != 'Y') {
                            fprintf(stderr, "blar: extract: aborted\n");
                            return EXIT_USAGE;
                        }
                        while (ch != '\n' && ch != EOF) ch = getchar();
                    } else {
                        fprintf(stderr, "blar: extract: '%s' is non-empty "
                                "(use -f to overwrite)\n", output_dir);
                        return EXIT_USAGE;
                    }
                }
            }
        }
    }

    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: extract: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    /* Set up progress bar */
    progrez_ctx *progress = progrez_create("Extracting");
    if (progress) {
        progrez_set_identity(progress, "blar", "archive extraction");
        progrez_set_sparkline(progress, true);
    }

    extract_cli_ctx_t cli_ctx = { .progress = progress, .total_files = 0, .total_bytes = 0 };

    int result = blar_extract_to_dir(buf, buf_len, output_dir, &builtin_registry,
                                      extract_cli_progress, extract_cli_log, &cli_ctx);

    if (progress) { progrez_finish(progress); progrez_destroy(progress); }
    free(buf);
    return result;
}

/* ── cmd_verify ───────────────────────────────────────────────────────── */

static int cmd_verify(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: verify: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: verify: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    if (!blip_archive_verify(buf, buf_len)) {
        fprintf(stderr, "blar: verify: archive hash mismatch\n");
        free(buf);
        return EXIT_VERIFY;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: verify: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    uint64_t file_count = 0;
    uint64_t dir_count = 0;

    for (uint64_t i = 0; i < count; i++) {
        rc = blip_archive_file_verify(buf, buf_len, i);
        if (rc != BLIP_OK) {
            const char *path = NULL;
            size_t path_len = 0;
            blip_archive_file_path(buf, buf_len, i, &path, &path_len);
            fprintf(stderr, "blar: verify: entry %llu", (unsigned long long)i);
            if (path) {
                fprintf(stderr, " ('%.*s')", (int)path_len, path);
            }
            fprintf(stderr, ": %s\n", blip_error_string(rc));
            free(buf);
            return EXIT_VERIFY;
        }

        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);
        if (entry_type == 0x07) {
            dir_count++;
            /* Also verify Merkle hash for DIR entries */
            rc = blip_archive_verify_merkle(buf, buf_len, i);
            if (rc != BLIP_OK) {
                const char *path = NULL;
                size_t path_len = 0;
                blip_archive_file_path(buf, buf_len, i, &path, &path_len);
                fprintf(stderr, "blar: verify: dir %llu", (unsigned long long)i);
                if (path) {
                    fprintf(stderr, " ('%.*s')", (int)path_len, path);
                }
                fprintf(stderr, ": Merkle hash mismatch\n");
                free(buf);
                return EXIT_VERIFY;
            }
        } else {
            file_count++;
        }
    }

    printf("OK: %llu files, %llu directories verified\n",
           (unsigned long long)file_count, (unsigned long long)dir_count);
    free(buf);
    return EXIT_OK;
}

/* ── JSON helpers ─────────────────────────────────────────────────────── */

/* Print a JSON-escaped string (handles ", \, control chars). */
static void json_print_escaped(FILE *f, const char *s, size_t len) {
    fputc('"', f);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  fputs("\\\"", f); break;
        case '\\': fputs("\\\\", f); break;
        case '\b': fputs("\\b", f);  break;
        case '\f': fputs("\\f", f);  break;
        case '\n': fputs("\\n", f);  break;
        case '\r': fputs("\\r", f);  break;
        case '\t': fputs("\\t", f);  break;
        default:
            if (c < 0x20) fprintf(f, "\\u%04x", c);
            else fputc(c, f);
        }
    }
    fputc('"', f);
}

/* ── cmd_info ─────────────────────────────────────────────────────────── */

static int cmd_info(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: info: missing archive path\n");
        return EXIT_USAGE;
    }

    /* Parse flags */
    bool json_mode = false;
    const char *archive_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json_mode = true;
        } else if (!archive_path) {
            archive_path = argv[i];
        }
    }
    if (!archive_path) {
        fprintf(stderr, "blar: info: missing archive path\n");
        return EXIT_USAGE;
    }

    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
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

    uint64_t file_count = 0;
    uint64_t dir_count = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);
        if (entry_type == 0x07) dir_count++;
        else file_count++;
    }

    if (json_mode) {
        /* ── JSON output ── */
        printf("{\n");
        printf("  \"archive\": "); json_print_escaped(stdout, archive_path, strlen(archive_path)); printf(",\n");
        printf("  \"size\": %llu,\n", (unsigned long long)buf_len);
        printf("  \"files\": %llu,\n", (unsigned long long)file_count);
        printf("  \"directories\": %llu,\n", (unsigned long long)dir_count);
        printf("  \"entries\": [\n");

        uint64_t total_content = 0;
        for (uint64_t i = 0; i < count; i++) {
            uint8_t entry_type = 0;
            blip_archive_entry_type(buf, buf_len, i, &entry_type);
            bool is_dir = (entry_type == 0x07);

            const char *path = NULL;
            size_t path_len = 0;
            rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "blar: info: entry %llu: %s\n",
                        (unsigned long long)i, blip_error_string(rc));
                free(buf);
                return EXIT_IO;
            }

            /* Full metadata */
            uint16_t mode = 0;
            int64_t mtime_ns = 0, ctime_ns = 0, birthtime_ns = 0;
            uint32_t uid = 0, gid = 0;
            const char *owner = NULL, *groupname = NULL;
            size_t owner_len = 0, groupname_len = 0;
            blip_archive_entry_metadata_full(buf, buf_len, i,
                &mode, &mtime_ns, &ctime_ns, &birthtime_ns,
                &uid, &gid, &owner, &owner_len, &groupname, &groupname_len);

            printf("    {");
            printf("\"type\": \"%s\"", is_dir ? "directory" : "file");
            printf(", \"path\": "); json_print_escaped(stdout, path, path_len);
            printf(", \"mode\": %u", (unsigned)mode);

            if (!is_dir) {
                uint8_t *data = NULL;
                size_t data_len = 0;
                rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
                if (rc == BLIP_OK) {
                    printf(", \"size\": %llu", (unsigned long long)data_len);
                    total_content += data_len;
                    blip_free_content(data, data_len);
                }
            }

            if (mtime_ns != 0)     printf(", \"mtime_ns\": %lld", (long long)mtime_ns);
            if (ctime_ns != 0)     printf(", \"ctime_ns\": %lld", (long long)ctime_ns);
            if (birthtime_ns != 0) printf(", \"birthtime_ns\": %lld", (long long)birthtime_ns);
            if (uid != 0)          printf(", \"uid\": %u", (unsigned)uid);
            if (gid != 0)          printf(", \"gid\": %u", (unsigned)gid);
            if (owner && owner_len > 0) {
                printf(", \"owner\": "); json_print_escaped(stdout, owner, owner_len);
            }
            if (groupname && groupname_len > 0) {
                printf(", \"group\": "); json_print_escaped(stdout, groupname, groupname_len);
            }

            /* Container metadata */
            if (is_dir) {
                const char *co_type = NULL;
                size_t co_type_len = 0;
                if (blip_archive_entry_container_type(buf, buf_len, i,
                        &co_type, &co_type_len) == BLIP_OK && co_type != NULL) {
                    printf(", \"container_type\": ");
                    json_print_escaped(stdout, co_type, co_type_len);
                }
            } else {
                uint16_t zc_method = 0xFFFF;
                if (blip_archive_entry_zip_comp(buf, buf_len, i,
                        &zc_method) == BLIP_OK && zc_method != 0xFFFF) {
                    printf(", \"zip_compression_method\": %u", (unsigned)zc_method);
                }
                uint64_t po_val = UINT64_MAX;
                if (blip_archive_entry_pdf_offset(buf, buf_len, i,
                        &po_val) == BLIP_OK && po_val != UINT64_MAX) {
                    printf(", \"pdf_stream_offset\": %llu", (unsigned long long)po_val);
                }
                uint64_t pl_val = UINT64_MAX;
                if (blip_archive_entry_pdf_length(buf, buf_len, i,
                        &pl_val) == BLIP_OK && pl_val != UINT64_MAX) {
                    printf(", \"pdf_stream_length\": %llu", (unsigned long long)pl_val);
                }
                const char *jx_fmt = NULL;
                size_t jx_fmt_len = 0;
                if (blip_archive_entry_jxl_source(buf, buf_len, i,
                        &jx_fmt, &jx_fmt_len) == BLIP_OK && jx_fmt != NULL) {
                    printf(", \"jxl_source_format\": \"%.*s\"", (int)jx_fmt_len, jx_fmt);
                }
            }

            printf("}%s\n", (i + 1 < count) ? "," : "");
        }

        printf("  ],\n");
        printf("  \"total_content\": %llu,\n", (unsigned long long)total_content);

        bool ok = blip_archive_verify(buf, buf_len);
        if (ok) {
            for (uint64_t i = 0; i < count; i++) {
                if (blip_archive_file_verify(buf, buf_len, i) != BLIP_OK) {
                    ok = false;
                    break;
                }
            }
        }
        printf("  \"integrity\": \"%s\"\n", ok ? "ok" : "failed");
        printf("}\n");

        free(buf);
        return ok ? EXIT_OK : EXIT_VERIFY;
    }

    /* ── Human-readable output ── */
    printf("Archive:     %s\n", archive_path);
    printf("Size:        %llu bytes\n", (unsigned long long)buf_len);
    printf("Files:       %llu\n", (unsigned long long)file_count);
    printf("Directories: %llu\n", (unsigned long long)dir_count);
    printf("\n");

    uint64_t total_content = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);
        char type_char = (entry_type == 0x07) ? 'd' : '-';

        /* Check for container DIR in human-readable output */
        if (entry_type == 0x07) {
            const char *co_type = NULL;
            size_t co_type_len = 0;
            if (blip_archive_entry_container_type(buf, buf_len, i,
                    &co_type, &co_type_len) == BLIP_OK && co_type != NULL) {
                const blar_codec_t *codec = blar_codec_find_by_name(&builtin_registry, co_type, co_type_len);
                if (codec) {
                    if (strcmp(codec->name, "pdf") == 0) type_char = 'p';
                    else if (strcmp(codec->name, "png") == 0) type_char = 'n';
                    else if (strcmp(codec->name, "jpeg") == 0) type_char = 'j';
                    else if (strcmp(codec->name, "gz") == 0) type_char = 'g';
                    else if (strcmp(codec->name, "bmp") == 0) type_char = 'b';
                    else if (strcmp(codec->name, "tar") == 0) type_char = 't';
                    else if (strcmp(codec->name, "tiff") == 0) type_char = 'i';
                    else if (strcmp(codec->name, "gif") == 0) type_char = 'f';
                    else if (strcmp(codec->name, "tga") == 0) type_char = 'a';
                    else if (strcmp(codec->name, "wav") == 0) type_char = 'w';
                    else if (strcmp(codec->name, "aiff") == 0) type_char = 'w';
                    else if (strcmp(codec->name, "fits") == 0) type_char = 's';
                    else if (strcmp(codec->name, "dicom") == 0) type_char = 'm';
                    else if (strcmp(codec->name, "nifti") == 0) type_char = 'r';
                    else type_char = 'z';
                } else {
                    type_char = '?';  /* unknown codec */
                }
            }
        }

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: info: entry %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        if (entry_type == 0x07) {
            /* DIR: show metadata */
            uint16_t mode = 0;
            int64_t mtime_ns = 0;
            const char *owner = NULL;
            size_t owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);
            const char *trail = (path_len > 0 && path[path_len - 1] == '/') ? "" : "/";
            printf("%c %04o  %.*s%s\n", type_char, mode, (int)path_len, path, trail);
        } else {
            uint8_t *data = NULL;
            size_t data_len = 0;
            rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "blar: info: entry %llu: %s\n",
                        (unsigned long long)i, blip_error_string(rc));
                free(buf);
                return EXIT_IO;
            }

            uint16_t mode = 0;
            int64_t mtime_ns = 0;
            const char *owner = NULL;
            size_t owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);
            printf("%c %04o  %8llu  %.*s\n", type_char, mode,
                   (unsigned long long)data_len, (int)path_len, path);
            total_content += data_len;
            blip_free_content(data, data_len);
        }
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
        fprintf(stderr, "blar: cat: requires <archive> <path>\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *file_path = argv[1];

    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: cat: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint8_t *data = NULL;
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

    blip_free_content(data, data_len);
    free(buf);
    return EXIT_OK;
}

/* ── cmd_peek ─────────────────────────────────────────────────────────── */

static int cmd_peek(int argc, char **argv) {
    return cmd_peek_common("blar", argc, argv);
}

/* ── cmd_poke ─────────────────────────────────────────────────────────── */

static int cmd_poke(int argc, char **argv) {
    return cmd_poke_common("blar", argc, argv);
}

/* ── cmd_to_json ──────────────────────────────────────────────────────── */

static int cmd_to_json(int argc, char **argv) {
    return cmd_to_json_common("blar", argc, argv);
}

/* ── cmd_from_json ────────────────────────────────────────────────────── */

static int cmd_from_json(int argc, char **argv) {
    return cmd_from_json_common("blar", argc, argv);
}

/* ── cmd_text ─────────────────────────────────────────────────────────── */

static void text_indent(FILE *out, int depth) {
    for (int i = 0; i < depth; i++) fprintf(out, "  ");
}

static void text_write_payload(FILE *out, const uint8_t *data, size_t data_len,
                                int depth) {
    /* Encode to printable-binary */
    uint8_t *pb = NULL;
    size_t pb_len = 0;
    int32_t rc = blip_encode_printable_binary(data, data_len, &pb, &pb_len);
    if (rc != BLIP_OK || !pb) {
        text_indent(out, depth);
        fprintf(out, "|<encode error>|\n");
        return;
    }

    /* Wrap at ~76 chars per line */
    const size_t wrap = 72; /* leave room for indent + delimiters */
    size_t pos = 0;
    while (pos < pb_len) {
        size_t chunk = pb_len - pos;
        if (chunk > wrap) chunk = wrap;
        text_indent(out, depth);
        fprintf(out, "|%.*s|\n", (int)chunk, pb + pos);
        pos += chunk;
    }

    blip_free(pb, pb_len);
}

static int cmd_text(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: text: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *output_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: text: -o requires an argument\n");
                return EXIT_USAGE;
            }
            output_path = argv[i + 1];
            i++;
        }
    }

    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: text: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: text: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    FILE *out = stdout;
    if (output_path) {
        out = fopen(output_path, "w");
        if (!out) {
            fprintf(stderr, "blar: text: cannot open '%s': %s\n",
                    output_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }
    }

    fprintf(out, "BLAR/1\n");

    int depth = 0;

    /* DIR path stack for tracking nesting depth */
    const char **dir_paths = NULL;
    size_t *dir_path_lens = NULL;
    int dir_stack_cap = 0;

    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: text: entry %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            if (output_path) fclose(out);
            free(dir_paths);
            free(dir_path_lens);
            free(buf);
            return EXIT_IO;
        }

        /* Pop DIR stack: if current path is not under the top DIR, pop.
         * DIR paths from the FFI don't have trailing /, so we check
         * that the current path starts with "dirpath/" */
        while (depth > 0) {
            const char *top_dir = dir_paths[depth - 1];
            size_t top_len = dir_path_lens[depth - 1];
            /* Check if current path starts with "top_dir/" */
            if (path_len > top_len &&
                path[top_len] == '/' &&
                memcmp(path, top_dir, top_len) == 0) {
                break; /* still inside this DIR */
            }
            depth--;
        }

        /* Get metadata */
        uint16_t mode = 0;
        int64_t mtime_ns = 0;
        const char *owner = NULL;
        size_t owner_len = 0;
        blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns,
                                     &owner, &owner_len);

        /* Extract just the basename for display (last component of path) */
        const char *display_name = path;
        size_t display_len = path_len;
        if (entry_type == 0x07) {
            /* DIR: show just the last directory component with trailing / */
            /* For "a/b/c/", show "c/" at the proper depth */
            /* Find the second-to-last slash */
            size_t name_end = path_len;
            if (name_end > 0 && path[name_end - 1] == '/') name_end--; /* skip trailing / */
            size_t name_start = 0;
            for (size_t j = 0; j < name_end; j++) {
                if (path[j] == '/') name_start = j + 1;
            }
            display_name = path + name_start;
            display_len = path_len - name_start; /* includes trailing / */
        } else {
            /* FILE: show just the filename */
            size_t name_start = 0;
            for (size_t j = 0; j < path_len; j++) {
                if (path[j] == '/') name_start = j + 1;
            }
            display_name = path + name_start;
            display_len = path_len - name_start;
        }

        if (entry_type == 0x07) {
            /* DIR entry -- show with trailing / */
            text_indent(out, depth);
            if (display_len > 0 && display_name[display_len - 1] == '/')
                fprintf(out, "DIR \"%.*s\"", (int)display_len, display_name);
            else
                fprintf(out, "DIR \"%.*s/\"", (int)display_len, display_name);

            /* Container type */
            const char *co_type = NULL;
            size_t co_type_len = 0;
            if (blip_archive_entry_container_type(buf, buf_len, i,
                    &co_type, &co_type_len) == BLIP_OK && co_type != NULL) {
                fprintf(out, " co=%.*s", (int)co_type_len, co_type);
            }

            if (mode != 0)
                fprintf(out, " mode=%04o", mode);
            if (mtime_ns != 0) {
                int64_t mtime_sec = mtime_ns / 1000000000LL;
                fprintf(out, " mtime=%lld", (long long)mtime_sec);
            }
            fprintf(out, "\n");

            /* Push this DIR onto the stack */
            if (depth >= dir_stack_cap) {
                int new_cap = dir_stack_cap == 0 ? 16 : dir_stack_cap * 2;
                dir_paths = realloc(dir_paths, (size_t)new_cap * sizeof(const char *));
                dir_path_lens = realloc(dir_path_lens, (size_t)new_cap * sizeof(size_t));
                dir_stack_cap = new_cap;
            }
            dir_paths[depth] = path;
            dir_path_lens[depth] = path_len;
            depth++;
        } else {
            /* FILE entry */
            text_indent(out, depth);
            fprintf(out, "FILE \"%.*s\"", (int)display_len, display_name);

            /* JXL source format */
            const char *jx_fmt = NULL;
            size_t jx_fmt_len = 0;
            if (blip_archive_entry_jxl_source(buf, buf_len, i,
                    &jx_fmt, &jx_fmt_len) == BLIP_OK && jx_fmt != NULL) {
                fprintf(out, " jx=%.*s", (int)jx_fmt_len, jx_fmt);
            }

            /* PDF stream offset/length */
            uint64_t po = UINT64_MAX;
            uint64_t pl = UINT64_MAX;
            blip_archive_entry_pdf_offset(buf, buf_len, i, &po);
            blip_archive_entry_pdf_length(buf, buf_len, i, &pl);
            if (po != UINT64_MAX)
                fprintf(out, " po=%llu", (unsigned long long)po);
            if (pl != UINT64_MAX)
                fprintf(out, " pl=%llu", (unsigned long long)pl);

            if (mode != 0)
                fprintf(out, " mode=%04o", mode);
            if (mtime_ns != 0) {
                int64_t mtime_sec = mtime_ns / 1000000000LL;
                fprintf(out, " mtime=%lld", (long long)mtime_sec);
            }
            fprintf(out, "\n");

            /* Get file content and write payload */
            uint8_t *data = NULL;
            size_t data_len = 0;
            rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
            if (rc == BLIP_OK && data != NULL && data_len > 0) {
                text_write_payload(out, data, data_len, depth + 1);
                blip_free_content(data, data_len);
            }
        }
    }

    free(dir_paths);
    free(dir_path_lens);

    if (output_path) fclose(out);
    free(buf);
    return EXIT_OK;
}

/* ── cmd_from_text ────────────────────────────────────────────────────── */

/* Parse key=value metadata pairs from the portion of a text line after the
 * quoted filename.  Recognised keys:
 *   mode=ONNN  (octal)          mtime=N  (decimal seconds → mtime_ns)
 *   co=X  (container_type)      jx=X     (jxl_source_format)
 *   po=N  (pdf_stream_offset)   pl=N     (pdf_stream_length)
 *   fp=N  (flate_predictor)     fc=N     (flate_columns)
 *   fl=N  (flate_colors)        fb=N     (flate_bpc)                    */
static void parse_text_metadata(const char *start, const char *end,
                                 blip_archive_entry *entry) {
    const char *p = start;
    while (p < end) {
        /* skip whitespace */
        while (p < end && (*p == ' ' || *p == '\t')) p++;
        if (p >= end) break;

        /* find '=' */
        const char *eq = p;
        while (eq < end && *eq != '=') eq++;
        if (eq >= end) break;

        size_t key_len = (size_t)(eq - p);
        const char *val = eq + 1;
        const char *val_end = val;
        while (val_end < end && *val_end != ' ' && *val_end != '\t' &&
               *val_end != '\n' && *val_end != '\r') val_end++;

        if (key_len == 4 && memcmp(p, "mode", 4) == 0) {
            entry->mode = (uint16_t)strtoul(val, NULL, 8);
        } else if (key_len == 5 && memcmp(p, "mtime", 5) == 0) {
            entry->mtime_ns = strtoll(val, NULL, 10) * 1000000000LL;
        } else if (key_len == 2 && memcmp(p, "co", 2) == 0) {
            size_t vlen = (size_t)(val_end - val);
            char *s = malloc(vlen + 1);
            if (s) { memcpy(s, val, vlen); s[vlen] = '\0'; }
            entry->container_type = s;
            entry->container_type_len = vlen;
        } else if (key_len == 2 && memcmp(p, "jx", 2) == 0) {
            size_t vlen = (size_t)(val_end - val);
            char *s = malloc(vlen + 1);
            if (s) { memcpy(s, val, vlen); s[vlen] = '\0'; }
            entry->jxl_source_format = s;
            entry->jxl_source_format_len = vlen;
        } else if (key_len == 2 && memcmp(p, "po", 2) == 0) {
            entry->pdf_stream_offset = strtoull(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "pl", 2) == 0) {
            entry->pdf_stream_length = strtoull(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "fp", 2) == 0) {
            entry->flate_predictor = (uint16_t)strtoul(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "fc", 2) == 0) {
            entry->flate_columns = (uint32_t)strtoul(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "fl", 2) == 0) {
            entry->flate_colors = (uint8_t)strtoul(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "fb", 2) == 0) {
            entry->flate_bpc = (uint8_t)strtoul(val, NULL, 10);
        }

        p = val_end;
    }
}

/* Accumulator for payload lines (|...|) between entries */
typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} payload_buf_t;

static void payload_buf_init(payload_buf_t *pb) {
    pb->data = NULL;
    pb->len = 0;
    pb->cap = 0;
}

static bool payload_buf_append(payload_buf_t *pb, const uint8_t *chunk, size_t chunk_len) {
    if (pb->len + chunk_len > pb->cap) {
        size_t new_cap = pb->cap == 0 ? 256 : pb->cap * 2;
        while (new_cap < pb->len + chunk_len) new_cap *= 2;
        uint8_t *tmp = realloc(pb->data, new_cap);
        if (!tmp) return false;
        pb->data = tmp;
        pb->cap = new_cap;
    }
    memcpy(pb->data + pb->len, chunk, chunk_len);
    pb->len += chunk_len;
    return true;
}

static void payload_buf_reset(payload_buf_t *pb) {
    pb->len = 0;
}

static void payload_buf_free(payload_buf_t *pb) {
    free(pb->data);
    pb->data = NULL;
    pb->len = 0;
    pb->cap = 0;
}

/* Flush accumulated payload into the most-recently-added FILE entry */
static bool flush_payload(payload_buf_t *pb, entry_list_t *el) {
    if (pb->len == 0 || el->count == 0) return true;

    /* Decode the accumulated printable-binary text */
    uint8_t *decoded = NULL;
    size_t decoded_len = 0;
    int32_t rc = blip_decode_printable_binary(pb->data, pb->len,
                                               &decoded, &decoded_len);
    if (rc != 0) return false;

    /* Copy to a malloc'd buffer so entry_list_free can free() it */
    uint8_t *content = (uint8_t *)malloc(decoded_len);
    if (!content) {
        blip_free(decoded, decoded_len);
        return false;
    }
    memcpy(content, decoded, decoded_len);
    blip_free(decoded, decoded_len);

    /* Patch the last entry */
    el->entries[el->count - 1].content = content;
    el->entries[el->count - 1].content_len = decoded_len;
    entry_list_add_content(el, content);

    payload_buf_reset(pb);
    return true;
}

static int cmd_from_text(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: from-text: missing input text file\n");
        return EXIT_USAGE;
    }

    const char *input_path = NULL;
    const char *output_path = NULL;
    uint8_t compress_algo = 0;

    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: from-text: -o requires an argument\n");
                return EXIT_USAGE;
            }
            output_path = argv[++i];
        } else if (strcmp(argv[i], "-z") == 0) {
            compress_algo = BLIP_COMP_LZMA2;
            /* Check for optional algorithm argument */
            if (i + 1 < argc && argv[i+1][0] != '-') {
                const char *algo = argv[i+1];
                if (strcmp(algo, "lzma2") == 0 || strcmp(algo, "lzma") == 0) {
                    compress_algo = BLIP_COMP_LZMA2; i++;
                } else if (strcmp(algo, "bzip2") == 0 || strcmp(algo, "bz2") == 0) {
                    compress_algo = BLIP_COMP_BZIP2; i++;
                } else if (strcmp(algo, "lz4") == 0) {
                    compress_algo = BLIP_COMP_LZ4; i++;
                } else if (strcmp(algo, "zstd") == 0 || strcmp(algo, "zst") == 0) {
                    compress_algo = BLIP_COMP_ZSTD; i++;
                }
            }
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            fprintf(stdout,
                "Usage: blar from-text <input.txt> -o <output.blar> [-z [algo]]\n"
                "\n"
                "Rebuild a BLIP archive from the text form produced by 'blar text'.\n");
            return EXIT_OK;
        } else if (argv[i][0] != '-') {
            if (!input_path)
                input_path = argv[i];
            else {
                fprintf(stderr, "blar: from-text: unexpected argument '%s'\n", argv[i]);
                return EXIT_USAGE;
            }
        } else {
            fprintf(stderr, "blar: from-text: unknown option '%s'\n", argv[i]);
            return EXIT_USAGE;
        }
    }

    if (!input_path) {
        fprintf(stderr, "blar: from-text: missing input text file\n");
        return EXIT_USAGE;
    }
    if (!output_path) {
        fprintf(stderr, "blar: from-text: -o <output> is required\n");
        return EXIT_USAGE;
    }

    /* Read the text file */
    size_t text_len = 0;
    uint8_t *text_buf = read_file(input_path, &text_len);
    if (!text_buf) {
        fprintf(stderr, "blar: from-text: cannot open '%s': %s\n",
                input_path, strerror(errno));
        return EXIT_IO;
    }

    /* Parse line by line */
    const char *text = (const char *)text_buf;
    const char *text_end = text + text_len;
    const char *line = text;

    /* Verify header */
    const char *nl = memchr(line, '\n', (size_t)(text_end - line));
    if (!nl) {
        fprintf(stderr, "blar: from-text: invalid text (no header line)\n");
        free(text_buf);
        return EXIT_IO;
    }
    size_t hdr_len = (size_t)(nl - line);
    if (hdr_len < 6 || memcmp(line, "BLAR/1", 6) != 0) {
        fprintf(stderr, "blar: from-text: expected BLAR/1 header\n");
        free(text_buf);
        return EXIT_IO;
    }
    line = nl + 1;

    entry_list_t el;
    entry_list_init(&el);

    /* DIR path stack: full path prefix at each depth */
    char **dir_stack = NULL;   /* malloc'd full-path strings */
    int dir_stack_count = 0;
    int dir_stack_cap = 0;

    payload_buf_t payload;
    payload_buf_init(&payload);
    int ret = EXIT_OK;

    while (line < text_end) {
        /* Find end of line */
        nl = memchr(line, '\n', (size_t)(text_end - line));
        const char *line_end = nl ? nl : text_end;
        size_t line_len = (size_t)(line_end - line);

        /* Measure indent */
        size_t indent = 0;
        while (indent < line_len && line[indent] == ' ') indent++;
        int depth = (int)(indent / 2);
        const char *content_start = line + indent;
        size_t content_len = line_len - indent;

        if (content_len == 0) {
            /* blank line -- skip */
            line = nl ? nl + 1 : text_end;
            continue;
        }

        if (content_start[0] == '|') {
            /* Payload line: extract text between first | and last | */
            const char *pstart = content_start + 1;
            const char *pend = content_start + content_len;
            /* Find closing | */
            if (pend > pstart && pend[-1] == '|') pend--;

            if (pend > pstart) {
                if (!payload_buf_append(&payload, (const uint8_t *)pstart,
                                        (size_t)(pend - pstart))) {
                    fprintf(stderr, "blar: from-text: out of memory\n");
                    ret = EXIT_IO;
                    goto cleanup;
                }
            }
        } else if (content_len >= 5 &&
                   (memcmp(content_start, "DIR ", 4) == 0 ||
                    memcmp(content_start, "FILE ", 5) == 0)) {
            /* Flush any pending payload for the previous FILE entry */
            if (!flush_payload(&payload, &el)) {
                fprintf(stderr, "blar: from-text: failed to decode payload\n");
                ret = EXIT_IO;
                goto cleanup;
            }

            bool is_dir = (content_start[0] == 'D');
            /* Find quoted name: skip to first '"' */
            const char *q1 = memchr(content_start, '"', content_len);
            if (!q1) {
                fprintf(stderr, "blar: from-text: missing quoted name\n");
                ret = EXIT_IO;
                goto cleanup;
            }
            q1++; /* skip opening quote */
            const char *q2 = memchr(q1, '"', (size_t)(line_end - q1));
            if (!q2) {
                fprintf(stderr, "blar: from-text: unterminated quote\n");
                ret = EXIT_IO;
                goto cleanup;
            }
            size_t name_len = (size_t)(q2 - q1);

            /* Pop DIR stack to match current depth */
            while (dir_stack_count > depth) {
                dir_stack_count--;
                free(dir_stack[dir_stack_count]);
                dir_stack[dir_stack_count] = NULL;
            }

            /* Build full path: top-of-stack prefix + basename.
             * Each dir_stack entry is a full prefix (e.g. "deep/a/b/"),
             * so we only use the top entry, not concatenate all. */
            size_t prefix_len = 0;
            if (dir_stack_count > 0) {
                prefix_len = strlen(dir_stack[dir_stack_count - 1]);
            }

            size_t full_path_len = prefix_len + name_len;
            /* For DIRs in the text, the name already has trailing / (e.g. "sub/").
             * In the archive, DIR paths do NOT have trailing /.
             * So we strip the trailing / for the archive path. */
            size_t archive_path_len = full_path_len;
            if (is_dir && name_len > 0 && q1[name_len - 1] == '/') {
                archive_path_len = full_path_len - 1;
            }

            char *full_path = malloc(archive_path_len + 1);
            if (!full_path) {
                fprintf(stderr, "blar: from-text: out of memory\n");
                ret = EXIT_IO;
                goto cleanup;
            }
            if (prefix_len > 0) {
                memcpy(full_path, dir_stack[dir_stack_count - 1], prefix_len);
            }
            /* Copy the basename (up to archive_path_len - prefix_len chars) */
            size_t name_copy = archive_path_len - prefix_len;
            memcpy(full_path + prefix_len, q1, name_copy);
            full_path[archive_path_len] = '\0';

            /* Build archive entry */
            blip_archive_entry entry;
            memset(&entry, 0, sizeof(entry));
            entry.path = full_path;
            entry.path_len = archive_path_len;
            entry.is_dir = is_dir ? 1 : 0;
            entry.pdf_stream_offset = UINT64_MAX;
            entry.pdf_stream_length = UINT64_MAX;
            entry.zip_compression_method = 0xFFFF;

            /* Parse metadata after closing quote */
            const char *meta_start = q2 + 1;
            if (meta_start < line_end) {
                parse_text_metadata(meta_start, line_end, &entry);
            }

            entry_list_add(&el, entry);
            entry_list_add_content(&el, (uint8_t *)full_path);

            /* If co= was parsed, register that string for cleanup */
            if (entry.container_type) {
                entry_list_add_content(&el, (uint8_t *)(char *)entry.container_type);
            }
            if (entry.jxl_source_format) {
                entry_list_add_content(&el, (uint8_t *)(char *)entry.jxl_source_format);
            }

            if (is_dir) {
                /* Push onto DIR stack: store the full prefix including this dir + "/" */
                if (dir_stack_count >= dir_stack_cap) {
                    int new_cap = dir_stack_cap == 0 ? 16 : dir_stack_cap * 2;
                    char **tmp = realloc(dir_stack, (size_t)new_cap * sizeof(char *));
                    if (!tmp) {
                        fprintf(stderr, "blar: from-text: out of memory\n");
                        ret = EXIT_IO;
                        goto cleanup;
                    }
                    dir_stack = tmp;
                    dir_stack_cap = new_cap;
                }
                /* The prefix for children is full_path + "/" */
                size_t plen = archive_path_len + 1;
                char *prefix = malloc(plen + 1);
                if (!prefix) {
                    fprintf(stderr, "blar: from-text: out of memory\n");
                    ret = EXIT_IO;
                    goto cleanup;
                }
                memcpy(prefix, full_path, archive_path_len);
                prefix[archive_path_len] = '/';
                prefix[plen] = '\0';
                dir_stack[dir_stack_count++] = prefix;
            }
        }
        /* else: skip unrecognized lines */

        line = nl ? nl + 1 : text_end;
    }

    /* Flush any trailing payload */
    if (!flush_payload(&payload, &el)) {
        fprintf(stderr, "blar: from-text: failed to decode trailing payload\n");
        ret = EXIT_IO;
        goto cleanup;
    }

    if (el.count == 0) {
        fprintf(stderr, "blar: from-text: no entries found\n");
        ret = EXIT_IO;
        goto cleanup;
    }

    /* Build the archive */
    {
        uint8_t *archive_buf = NULL;
        size_t archive_len = 0;
        int32_t rc = blip_archive_create_full(el.entries, el.count, 0, 0, 0,
                                               NULL, NULL, NULL,
                                               &archive_buf, &archive_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: from-text: archive creation failed: %s\n",
                    blip_error_string(rc));
            ret = EXIT_IO;
            goto cleanup;
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
                fprintf(stderr, "blar: from-text: compression failed: %s\n",
                        blip_error_string(rc));
                ret = EXIT_IO;
                goto cleanup;
            }
            archive_buf = compressed_buf;
            archive_len = compressed_len;
        }

        if (!write_file(output_path, archive_buf, archive_len)) {
            fprintf(stderr, "blar: from-text: cannot write '%s': %s\n",
                    output_path, strerror(errno));
            blip_free(archive_buf, archive_len);
            ret = EXIT_IO;
            goto cleanup;
        }

        blip_free(archive_buf, archive_len);
    }

cleanup:
    payload_buf_free(&payload);
    for (int i = 0; i < dir_stack_count; i++) free(dir_stack[i]);
    free(dir_stack);
    entry_list_free(&el);
    free(text_buf);
    return ret;
}

/* ── Explode: extract archive to directory tree with __meta__.json sidecars ─ */

/* Metadata entry for one file/dir in a parent directory. */
typedef struct {
    char basename[1024];    /* entry basename (with trailing / for dirs) */
    uint16_t mode;
    int64_t mtime_s;        /* seconds since epoch */
    char co[64];            /* container type, empty if none */
    char jx[64];            /* jxl source format, empty if none */
    uint64_t po;            /* pdf offset, UINT64_MAX if not set */
    uint64_t pl;            /* pdf length, UINT64_MAX if not set */
} explode_meta_entry_t;

/* Dynamic array of meta entries grouped by parent directory. */
typedef struct {
    char parent_dir[4096];  /* output filesystem path of the parent dir */
    explode_meta_entry_t *entries;
    size_t count;
    size_t capacity;
} explode_meta_group_t;

static bool explode_meta_group_add(explode_meta_group_t *g, const explode_meta_entry_t *e) {
    if (g->count >= g->capacity) {
        size_t new_cap = g->capacity == 0 ? 16 : g->capacity * 2;
        explode_meta_entry_t *new_arr = realloc(g->entries, new_cap * sizeof(explode_meta_entry_t));
        if (!new_arr) return false;
        g->entries = new_arr;
        g->capacity = new_cap;
    }
    g->entries[g->count++] = *e;
    return true;
}

/* Find or create a meta group for the given parent directory. */
static explode_meta_group_t *explode_find_or_create_group(
    explode_meta_group_t **groups, size_t *group_count, size_t *group_cap,
    const char *parent_dir)
{
    for (size_t i = 0; i < *group_count; i++) {
        if (strcmp((*groups)[i].parent_dir, parent_dir) == 0)
            return &(*groups)[i];
    }
    if (*group_count >= *group_cap) {
        size_t new_cap = *group_cap == 0 ? 16 : (*group_cap) * 2;
        explode_meta_group_t *new_arr = realloc(*groups, new_cap * sizeof(explode_meta_group_t));
        if (!new_arr) return NULL;
        *groups = new_arr;
        *group_cap = new_cap;
    }
    explode_meta_group_t *g = &(*groups)[(*group_count)++];
    memset(g, 0, sizeof(*g));
    snprintf(g->parent_dir, sizeof(g->parent_dir), "%s", parent_dir);
    return g;
}

/* Write a JSON string with minimal escaping (backslash and double-quote). */
static void fprint_json_string(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') fputc('\\', f);
        fputc(*s, f);
    }
    fputc('"', f);
}

/* Write a __meta__.json file for one group. */
static bool write_meta_json(const explode_meta_group_t *g) {
    char meta_path[4096];
    snprintf(meta_path, sizeof(meta_path), "%s/__meta__.json", g->parent_dir);

    FILE *f = fopen(meta_path, "w");
    if (!f) return false;

    fprintf(f, "{\n");
    for (size_t i = 0; i < g->count; i++) {
        const explode_meta_entry_t *e = &g->entries[i];
        fprintf(f, "  ");
        fprint_json_string(f, e->basename);
        fprintf(f, ": {\"mode\": %u, \"mtime\": %lld",
                (unsigned)e->mode, (long long)e->mtime_s);
        if (e->co[0] != '\0') {
            fprintf(f, ", \"co\": ");
            fprint_json_string(f, e->co);
        }
        if (e->jx[0] != '\0') {
            fprintf(f, ", \"jx\": ");
            fprint_json_string(f, e->jx);
        }
        if (e->po != UINT64_MAX) {
            fprintf(f, ", \"po\": %llu", (unsigned long long)e->po);
        }
        if (e->pl != UINT64_MAX) {
            fprintf(f, ", \"pl\": %llu", (unsigned long long)e->pl);
        }
        fprintf(f, "}%s\n", (i + 1 < g->count) ? "," : "");
    }
    fprintf(f, "}\n");
    fclose(f);
    return true;
}

static int cmd_explode(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: explode: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *output_dir = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-C") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: explode: -C requires an argument\n");
                return EXIT_USAGE;
            }
            output_dir = argv[i + 1];
            i++;
        }
    }

    if (!output_dir) {
        fprintf(stderr, "blar: explode: -C <output_dir> is required\n");
        return EXIT_USAGE;
    }

    /* Read and transparently decrypt/decompress the archive */
    size_t buf_len = 0;
    uint8_t *buf = read_archive(archive_path, &buf_len);
    if (!buf) {
        fprintf(stderr, "blar: explode: cannot open '%s': %s\n",
                archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, buf_len, &count);
    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: explode: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_IO;
    }

    /* Create the output directory */
    if (!mkdirp(output_dir)) {
        fprintf(stderr, "blar: explode: cannot create output directory '%s': %s\n",
                output_dir, strerror(errno));
        free(buf);
        return EXIT_IO;
    }

    /* Metadata groups (one per unique parent directory) */
    explode_meta_group_t *groups = NULL;
    size_t group_count = 0;
    size_t group_cap = 0;
    int ret = EXIT_OK;

    /* Pass 1: create directories and extract files */
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: explode: entry %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            ret = EXIT_IO;
            goto explode_cleanup;
        }

        /* Build full output path */
        char out_path[4096];
        int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                         output_dir, (int)path_len, path);
        if (n < 0 || (size_t)n >= sizeof(out_path)) {
            fprintf(stderr, "blar: explode: path too long\n");
            ret = EXIT_IO;
            goto explode_cleanup;
        }

        if (entry_type == 0x07) {
            /* Directory */
            if (!mkdirp(out_path)) {
                fprintf(stderr, "blar: explode: cannot create directory '%s': %s\n",
                        out_path, strerror(errno));
                ret = EXIT_IO;
                goto explode_cleanup;
            }
        } else if (entry_type == 0x05) {
            /* File: ensure parent dir exists, then write content */
            if (!ensure_parent_dir(out_path)) {
                fprintf(stderr, "blar: explode: cannot create parent directory for '%s': %s\n",
                        out_path, strerror(errno));
                ret = EXIT_IO;
                goto explode_cleanup;
            }

            uint8_t *content = NULL;
            size_t content_len = 0;
            rc = blip_archive_file_content(buf, buf_len, i, &content, &content_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "blar: explode: cannot read content of '%.*s': %s\n",
                        (int)path_len, path, blip_error_string(rc));
                ret = EXIT_IO;
                goto explode_cleanup;
            }

            FILE *f = fopen(out_path, "wb");
            if (!f) {
                fprintf(stderr, "blar: explode: cannot write '%s': %s\n",
                        out_path, strerror(errno));
                blip_free_content(content, content_len);
                ret = EXIT_IO;
                goto explode_cleanup;
            }
            if (content_len > 0) {
                fwrite(content, 1, content_len, f);
            }
            fclose(f);
            blip_free_content(content, content_len);
        }

        /* Set mode if available */
        uint16_t mode = 0;
        int64_t mtime_ns = 0;
        const char *owner = NULL;
        size_t owner_len = 0;
        blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);

        if (mode != 0) {
            chmod(out_path, mode);
        }
    }

    /* Pass 2: build and write __meta__.json sidecars */
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);

        const char *path = NULL;
        size_t path_len = 0;
        blip_archive_file_path(buf, buf_len, i, &path, &path_len);

        /* Get metadata */
        uint16_t mode = 0;
        int64_t mtime_ns = 0;
        const char *owner = NULL;
        size_t owner_len = 0;
        blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);

        /* Get optional container/jxl/pdf metadata */
        const char *co_type = NULL;
        size_t co_type_len = 0;
        blip_archive_entry_container_type(buf, buf_len, i, &co_type, &co_type_len);

        const char *jx_fmt = NULL;
        size_t jx_fmt_len = 0;
        blip_archive_entry_jxl_source(buf, buf_len, i, &jx_fmt, &jx_fmt_len);

        uint64_t po = UINT64_MAX;
        blip_archive_entry_pdf_offset(buf, buf_len, i, &po);

        uint64_t pl = UINT64_MAX;
        blip_archive_entry_pdf_length(buf, buf_len, i, &pl);

        /* Determine basename and parent directory */
        /* path is like "dir/sub/file.txt" -- basename is "file.txt", parent is output_dir/dir/sub */
        char path_str[4096];
        snprintf(path_str, sizeof(path_str), "%.*s", (int)path_len, path);

        /* For directories, strip trailing slash for path parsing, add back to basename */
        size_t effective_len = path_len;
        bool is_dir = (entry_type == 0x07);

        /* Find the last slash to split parent/basename */
        const char *last_slash = NULL;
        for (size_t j = 0; j < effective_len; j++) {
            if (path_str[j] == '/') last_slash = &path_str[j];
        }

        char parent_path[4096];
        char basename[1024];

        if (last_slash) {
            /* Has parent component(s) */
            size_t parent_part_len = (size_t)(last_slash - path_str);
            snprintf(parent_path, sizeof(parent_path), "%s/%.*s",
                     output_dir, (int)parent_part_len, path_str);
            snprintf(basename, sizeof(basename), "%s%s",
                     last_slash + 1, is_dir ? "/" : "");
        } else {
            /* Top-level entry */
            snprintf(parent_path, sizeof(parent_path), "%s", output_dir);
            snprintf(basename, sizeof(basename), "%s%s",
                     path_str, is_dir ? "/" : "");
        }

        /* Build meta entry */
        explode_meta_entry_t meta;
        memset(&meta, 0, sizeof(meta));
        snprintf(meta.basename, sizeof(meta.basename), "%s", basename);
        meta.mode = mode;
        meta.mtime_s = mtime_ns / 1000000000LL;
        meta.po = po;
        meta.pl = pl;
        if (co_type && co_type_len > 0) {
            snprintf(meta.co, sizeof(meta.co), "%.*s", (int)co_type_len, co_type);
        }
        if (jx_fmt && jx_fmt_len > 0) {
            snprintf(meta.jx, sizeof(meta.jx), "%.*s", (int)jx_fmt_len, jx_fmt);
        }

        /* Add to the appropriate group */
        explode_meta_group_t *grp = explode_find_or_create_group(
            &groups, &group_count, &group_cap, parent_path);
        if (!grp || !explode_meta_group_add(grp, &meta)) {
            fprintf(stderr, "blar: explode: out of memory\n");
            ret = EXIT_IO;
            goto explode_cleanup;
        }
    }

    /* Write __meta__.json for each group */
    for (size_t gi = 0; gi < group_count; gi++) {
        if (!write_meta_json(&groups[gi])) {
            fprintf(stderr, "blar: explode: cannot write __meta__.json in '%s': %s\n",
                    groups[gi].parent_dir, strerror(errno));
            ret = EXIT_IO;
            goto explode_cleanup;
        }
    }

explode_cleanup:
    for (size_t gi = 0; gi < group_count; gi++) {
        free(groups[gi].entries);
    }
    free(groups);
    free(buf);
    return ret;
}

/* ── Implode: rebuild archive from directory tree + __meta__.json sidecars ── */

/* Parsed metadata for one entry from __meta__.json. */
typedef struct {
    char basename[1024];
    uint16_t mode;
    int64_t mtime_s;
    char co[64];
    char jx[64];
    uint64_t po;
    uint64_t pl;
} implode_meta_entry_t;

typedef struct {
    implode_meta_entry_t *entries;
    size_t count;
    size_t capacity;
} implode_meta_t;

/* Skip whitespace in JSON. */
static const char *json_skip_ws(const char *p, const char *end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

/* Parse a JSON string starting at p (which points to the opening quote).
 * Writes the unescaped string into buf (up to buf_size-1 chars).
 * Returns pointer past the closing quote, or NULL on error. */
static const char *json_parse_string(const char *p, const char *end,
                                      char *buf, size_t buf_size) {
    if (p >= end || *p != '"') return NULL;
    p++; /* skip opening quote */
    size_t len = 0;
    while (p < end && *p != '"') {
        if (*p == '\\' && p + 1 < end) {
            p++;
            if (len < buf_size - 1) buf[len++] = *p;
            p++;
        } else {
            if (len < buf_size - 1) buf[len++] = *p;
            p++;
        }
    }
    if (p >= end) return NULL;
    buf[len] = '\0';
    p++; /* skip closing quote */
    return p;
}

/* Parse a JSON integer (possibly negative) starting at p.
 * Returns pointer past the number, or NULL on error. */
static const char *json_parse_int64(const char *p, const char *end, int64_t *out) {
    if (p >= end) return NULL;
    bool neg = false;
    if (*p == '-') { neg = true; p++; }
    if (p >= end || *p < '0' || *p > '9') return NULL;
    int64_t val = 0;
    while (p < end && *p >= '0' && *p <= '9') {
        val = val * 10 + (*p - '0');
        p++;
    }
    *out = neg ? -val : val;
    return p;
}

static const char *json_parse_uint64(const char *p, const char *end, uint64_t *out) {
    if (p >= end || *p < '0' || *p > '9') return NULL;
    uint64_t val = 0;
    while (p < end && *p >= '0' && *p <= '9') {
        val = val * 10 + (*p - '0');
        p++;
    }
    *out = val;
    return p;
}

/* Parse __meta__.json content into an implode_meta_t.
 * Returns true on success. */
static bool parse_meta_json(const char *json, size_t json_len, implode_meta_t *meta) {
    const char *p = json;
    const char *end = json + json_len;

    p = json_skip_ws(p, end);
    if (p >= end || *p != '{') return false;
    p++;

    while (p < end) {
        p = json_skip_ws(p, end);
        if (p >= end) return false;
        if (*p == '}') break;

        /* Parse key (basename) */
        implode_meta_entry_t entry;
        memset(&entry, 0, sizeof(entry));
        entry.po = UINT64_MAX;
        entry.pl = UINT64_MAX;

        p = json_parse_string(p, end, entry.basename, sizeof(entry.basename));
        if (!p) return false;

        p = json_skip_ws(p, end);
        if (p >= end || *p != ':') return false;
        p++;

        p = json_skip_ws(p, end);
        if (p >= end || *p != '{') return false;
        p++;

        /* Parse value object fields */
        while (p < end) {
            p = json_skip_ws(p, end);
            if (p >= end) return false;
            if (*p == '}') { p++; break; }

            /* Parse field name */
            char field[64];
            p = json_parse_string(p, end, field, sizeof(field));
            if (!p) return false;

            p = json_skip_ws(p, end);
            if (p >= end || *p != ':') return false;
            p++;
            p = json_skip_ws(p, end);
            if (p >= end) return false;

            /* Parse field value */
            if (strcmp(field, "mode") == 0) {
                int64_t val = 0;
                p = json_parse_int64(p, end, &val);
                if (!p) return false;
                entry.mode = (uint16_t)val;
            } else if (strcmp(field, "mtime") == 0) {
                p = json_parse_int64(p, end, &entry.mtime_s);
                if (!p) return false;
            } else if (strcmp(field, "co") == 0) {
                p = json_parse_string(p, end, entry.co, sizeof(entry.co));
                if (!p) return false;
            } else if (strcmp(field, "jx") == 0) {
                p = json_parse_string(p, end, entry.jx, sizeof(entry.jx));
                if (!p) return false;
            } else if (strcmp(field, "po") == 0) {
                p = json_parse_uint64(p, end, &entry.po);
                if (!p) return false;
            } else if (strcmp(field, "pl") == 0) {
                p = json_parse_uint64(p, end, &entry.pl);
                if (!p) return false;
            } else {
                /* Skip unknown value: string or number */
                if (*p == '"') {
                    char skip[1024];
                    p = json_parse_string(p, end, skip, sizeof(skip));
                    if (!p) return false;
                } else {
                    int64_t skip_val;
                    p = json_parse_int64(p, end, &skip_val);
                    if (!p) return false;
                }
            }

            p = json_skip_ws(p, end);
            if (p < end && *p == ',') p++;
        }

        /* Add entry to meta */
        if (meta->count >= meta->capacity) {
            size_t new_cap = meta->capacity == 0 ? 16 : meta->capacity * 2;
            implode_meta_entry_t *new_arr = realloc(meta->entries,
                new_cap * sizeof(implode_meta_entry_t));
            if (!new_arr) return false;
            meta->entries = new_arr;
            meta->capacity = new_cap;
        }
        meta->entries[meta->count++] = entry;

        p = json_skip_ws(p, end);
        if (p < end && *p == ',') p++;
    }

    return true;
}

/* Find metadata for a basename in the parsed meta. Returns NULL if not found. */
static const implode_meta_entry_t *find_meta(const implode_meta_t *meta,
                                              const char *basename) {
    for (size_t i = 0; i < meta->count; i++) {
        if (strcmp(meta->entries[i].basename, basename) == 0)
            return &meta->entries[i];
    }
    return NULL;
}

/* Recursively walk a directory and add entries to the entry list.
 * prefix: archive path prefix (e.g. "" for root, "subdir/" for nested).
 * dir_path: filesystem path of the directory. */
static bool implode_walk(entry_list_t *el, const char *dir_path, const char *prefix) {
    /* Read __meta__.json if present */
    implode_meta_t meta;
    memset(&meta, 0, sizeof(meta));

    char meta_path[4096];
    snprintf(meta_path, sizeof(meta_path), "%s/__meta__.json", dir_path);

    size_t meta_json_len = 0;
    uint8_t *meta_json = read_file(meta_path, &meta_json_len);
    if (meta_json) {
        if (!parse_meta_json((const char *)meta_json, meta_json_len, &meta)) {
            fprintf(stderr, "blar: implode: warning: cannot parse %s\n", meta_path);
        }
        free(meta_json);
    }

    /* List directory entries, sorted */
    struct dirent **namelist = NULL;
    int n = scandir(dir_path, &namelist, NULL, alphasort);
    if (n < 0) {
        fprintf(stderr, "blar: implode: cannot read directory '%s': %s\n",
                dir_path, strerror(errno));
        free(meta.entries);
        return false;
    }

    bool ok = true;

    for (int i = 0; i < n; i++) {
        const char *name = namelist[i]->d_name;

        /* Skip . and .. */
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
            free(namelist[i]);
            continue;
        }

        /* Skip reserved sidecar files */
        if (strcmp(name, "__meta__.json") == 0 || strcmp(name, "__archive__.json") == 0) {
            free(namelist[i]);
            continue;
        }

        /* Build filesystem path and archive path */
        char fs_path[4096];
        snprintf(fs_path, sizeof(fs_path), "%s/%s", dir_path, name);

        char archive_path[4096];
        if (prefix[0] == '\0') {
            snprintf(archive_path, sizeof(archive_path), "%s", name);
        } else {
            snprintf(archive_path, sizeof(archive_path), "%s%s", prefix, name);
        }

        struct stat st;
        if (stat(fs_path, &st) != 0) {
            fprintf(stderr, "blar: implode: cannot stat '%s': %s\n",
                    fs_path, strerror(errno));
            free(namelist[i]);
            ok = false;
            break;
        }

        if (S_ISDIR(st.st_mode)) {
            /* Look up metadata with trailing slash */
            char dir_basename[1024];
            snprintf(dir_basename, sizeof(dir_basename), "%s/", name);
            const implode_meta_entry_t *me = find_meta(&meta, dir_basename);

            /* Create DIR entry */
            blip_archive_entry entry;
            memset(&entry, 0, sizeof(entry));
            entry.pdf_stream_offset = UINT64_MAX;
            entry.pdf_stream_length = UINT64_MAX;
            entry.zip_compression_method = 0xFFFF;

            char *path_dup = entry_list_strdup(el, archive_path);
            if (!path_dup) { ok = false; free(namelist[i]); break; }
            entry.path = path_dup;
            entry.path_len = strlen(path_dup);
            entry.is_dir = 1;

            if (me) {
                entry.mode = me->mode;
                entry.mtime_ns = me->mtime_s * 1000000000LL;
                if (me->co[0] != '\0') {
                    char *co_dup = entry_list_strdup(el, me->co);
                    if (co_dup) {
                        entry.container_type = co_dup;
                        entry.container_type_len = strlen(co_dup);
                    }
                }
            } else {
                entry.mode = (uint16_t)(st.st_mode & 0777);
            }

            if (!entry_list_add(el, entry)) { ok = false; free(namelist[i]); break; }

            /* Recurse into subdirectory */
            char sub_prefix[4096];
            snprintf(sub_prefix, sizeof(sub_prefix), "%s/", archive_path);
            if (!implode_walk(el, fs_path, sub_prefix)) {
                ok = false;
                free(namelist[i]);
                break;
            }
        } else if (S_ISREG(st.st_mode)) {
            /* Look up metadata (no trailing slash) */
            const implode_meta_entry_t *me = find_meta(&meta, name);

            /* Read file content */
            size_t content_len = 0;
            uint8_t *content = read_file(fs_path, &content_len);
            if (!content && st.st_size > 0) {
                fprintf(stderr, "blar: implode: cannot read '%s': %s\n",
                        fs_path, strerror(errno));
                ok = false;
                free(namelist[i]);
                break;
            }

            /* Track the content buffer for cleanup */
            if (content) {
                if (!entry_list_add_content(el, content)) {
                    free(content);
                    ok = false;
                    free(namelist[i]);
                    break;
                }
            }

            blip_archive_entry entry;
            memset(&entry, 0, sizeof(entry));
            entry.pdf_stream_offset = UINT64_MAX;
            entry.pdf_stream_length = UINT64_MAX;
            entry.zip_compression_method = 0xFFFF;

            char *path_dup = entry_list_strdup(el, archive_path);
            if (!path_dup) { ok = false; free(namelist[i]); break; }
            entry.path = path_dup;
            entry.path_len = strlen(path_dup);
            entry.content = content;
            entry.content_len = content_len;
            entry.is_dir = 0;

            if (me) {
                entry.mode = me->mode;
                entry.mtime_ns = me->mtime_s * 1000000000LL;
                if (me->jx[0] != '\0') {
                    char *jx_dup = entry_list_strdup(el, me->jx);
                    if (jx_dup) {
                        entry.jxl_source_format = jx_dup;
                        entry.jxl_source_format_len = strlen(jx_dup);
                    }
                }
                if (me->po != UINT64_MAX) entry.pdf_stream_offset = me->po;
                if (me->pl != UINT64_MAX) entry.pdf_stream_length = me->pl;
            } else {
                entry.mode = (uint16_t)(st.st_mode & 0777);
            }

            if (!entry_list_add(el, entry)) { ok = false; free(namelist[i]); break; }
        }
        /* Skip symlinks, devices, etc. */

        free(namelist[i]);
    }

    free(namelist);
    free(meta.entries);
    return ok;
}

static int cmd_implode(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: implode: missing directory path\n");
        return EXIT_USAGE;
    }

    const char *input_dir = NULL;
    const char *output_path = NULL;
    bool do_compress = false;

    /* Parse arguments: <directory> -o <output> [-z] */
    int i = 0;
    while (i < argc) {
        if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "blar: implode: -o requires an argument\n");
                return EXIT_USAGE;
            }
            output_path = argv[i + 1];
            i += 2;
        } else if (strcmp(argv[i], "-z") == 0) {
            do_compress = true;
            i++;
        } else {
            if (!input_dir) {
                input_dir = argv[i];
            }
            i++;
        }
    }

    if (!input_dir) {
        fprintf(stderr, "blar: implode: missing directory path\n");
        return EXIT_USAGE;
    }
    if (!output_path) {
        fprintf(stderr, "blar: implode: -o <output.blar> is required\n");
        return EXIT_USAGE;
    }

    /* Verify input is a directory */
    struct stat dir_st;
    if (stat(input_dir, &dir_st) != 0 || !S_ISDIR(dir_st.st_mode)) {
        fprintf(stderr, "blar: implode: '%s' is not a directory\n", input_dir);
        return EXIT_USAGE;
    }

    /* Walk the directory tree and collect entries */
    entry_list_t el;
    entry_list_init(&el);

    if (!implode_walk(&el, input_dir, "")) {
        entry_list_free(&el);
        return EXIT_IO;
    }

    if (el.count == 0) {
        fprintf(stderr, "blar: implode: no entries found in '%s'\n", input_dir);
        entry_list_free(&el);
        return EXIT_IO;
    }

    /* Create archive */
    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    int32_t rc = blip_archive_create_full(el.entries, el.count, 0, 0, 0,
                                           NULL, NULL, NULL,
                                           &archive_buf, &archive_len);
    entry_list_free(&el);

    if (rc != BLIP_OK) {
        fprintf(stderr, "blar: implode: archive creation failed: %s\n",
                blip_error_string(rc));
        return EXIT_IO;
    }

    /* Optionally compress */
    if (do_compress) {
        uint8_t *compressed_buf = NULL;
        size_t compressed_len = 0;
        rc = blip_compress_container(archive_buf, archive_len, BLIP_COMP_LZMA2, 0,
                                      NULL, NULL, NULL,
                                      &compressed_buf, &compressed_len);
        blip_free(archive_buf, archive_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: implode: compression failed: %s\n",
                    blip_error_string(rc));
            return EXIT_IO;
        }
        archive_buf = compressed_buf;
        archive_len = compressed_len;
    }

    /* Write output file */
    if (!write_file(output_path, archive_buf, archive_len)) {
        fprintf(stderr, "blar: implode: cannot write '%s': %s\n",
                output_path, strerror(errno));
        blip_free(archive_buf, archive_len);
        return EXIT_IO;
    }

    blip_free(archive_buf, archive_len);
    return EXIT_OK;
}
/* rebuild 1774972745 */
