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
 *   blar info <archive>
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

#include <dirent.h>
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
} entry_list_t;

static void entry_list_init(entry_list_t *el) {
    el->entries = NULL;
    el->count = 0;
    el->capacity = 0;
    el->content_bufs = NULL;
    el->content_count = 0;
    el->content_capacity = 0;
    el->progress = NULL;
    el->bytes_seen = 0;
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
        if (!entry_list_add(el, entry)) return false;
        if (el->progress) progrez_update(el->progress, el->count, el->bytes_seen);

        return collect_dir_children(path, el);
    } else if (S_ISREG(st.st_mode)) {
        size_t content_len = 0;
        uint8_t *content = read_file(path, &content_len);
        if (!content) {
            fprintf(stderr, "blar: create: cannot read '%s': %s\n",
                    path, strerror(errno));
            return false;
        }
        if (!entry_list_add_content(el, content)) {
            free(content);
            return false;
        }

        blip_archive_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.path = owned_path;
        entry.path_len = strlen(owned_path);
        entry.content = content;
        entry.content_len = content_len;
        entry.is_dir = 0;
        fill_entry_metadata(&entry, &st);
        if (!entry_list_add(el, entry)) return false;
        el->bytes_seen += content_len;
        if (el->progress) progrez_update(el->progress, el->count, el->bytes_seen);
    }

    return true;
}

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
        "  info <archive>                         Show archive information\n"
        "  cat <archive> <path>                   Print file contents to stdout\n"
        "  peek <archive> [<path>] [flags]        Inspect archive structure\n"
        "  poke <archive> <path> [options]        Modify a value in archive\n"
        "  to-json <archive>                     Convert archive to JSON (stdout)\n"
        "  from-json [-o <archive>] [<json>]     Convert JSON to archive\n"
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
        "  -e [cipher]      Encrypt archive (aes=default, chacha)\n"
        "  --kdf <name>     KDF for encryption (argon2=default, pbkdf2)\n"
        "  --absolute-names Preserve absolute paths in archive\n"
        "  -h, --help       Show this help\n"
        "  --version        Show version\n"
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
    bool do_encrypt = false;
    uint8_t enc_id = 1;   /* default: AES-256-GCM */
    uint8_t kdf_id = 1;   /* default: Argon2id */

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
            /* First arg doesn't exist — treat as output path (tar-style) */
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

    /* Collect all entries (files and directories, recursively) */
    entry_list_t el;
    entry_list_init(&el);

    /* Progress: indeterminate scanning phase */
    progrez_ctx *progress = progrez_create("Scanning");
    if (progress) {
        progrez_set_identity(progress, "blar", "archive creation");
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

    /* Progress: switch to determinate "Creating" phase.
     * The FFI now calls back per-entry so we get real progress. */
    if (progress) {
        progrez_set_label(progress, "Creating");
        progrez_set_determinate(progress, el.count, el.bytes_seen);
    }

    /* Create the archive via FFI (with progress callback) */
    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    uint32_t create_flags = absolute_names ? BLIP_ARCHIVE_ABSOLUTE_PATHS : 0;
    int32_t rc = blip_archive_create_full(el.entries, el.count, create_flags,
                                           progress ? create_progress_cb : NULL,
                                           progress ? phase_cb : NULL,
                                           progress,
                                           &archive_buf, &archive_len);
    entry_list_free(&el);

    if (rc != BLIP_OK) {
        if (progress) { progrez_finish(progress); progrez_destroy(progress); }
        fprintf(stderr, "blar: create: %s\n", blip_error_string(rc));
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
            fprintf(stderr, "blar: create: compression failed: %s\n",
                    blip_error_string(rc));
            return EXIT_IO;
        }
        archive_buf = compressed_buf;
        archive_len = compressed_len;
    }

    /* Optionally encrypt (outermost layer — after compression) */
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
    fprintf(stderr, "Created %s (%s)\n", out_path,
            format_size(archive_len, size_buf, sizeof(size_buf)));
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

static int cmd_extract(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: extract: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
    const char *output_dir = NULL;

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
    uint8_t *buf = read_archive(archive_path, &buf_len);
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

    uint64_t total_bytes = 0;
    uint64_t bytes_done = 0;
    uint64_t file_entries = 0; /* count of non-dir entries for progress */

    /* First pass: create directories, count bytes for progress */
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "blar: extract: entry %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

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

        if (entry_type == 0x07) {
            /* DIR entry: create directory */
            uint16_t mode = 0;
            int64_t mtime_ns = 0;
            const char *owner = NULL;
            size_t owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, i, &mode, &mtime_ns, &owner, &owner_len);

            if (!mkdirp(out_path)) {
                fprintf(stderr, "blar: extract: cannot create directory '%s': %s\n",
                        out_path, strerror(errno));
                free(buf);
                return EXIT_IO;
            }
            if (mode != 0) {
                chmod(out_path, mode);
            }
            /* mtime for directories is set after all files are extracted */
        } else {
            /* FILE entry: count bytes for progress */
            const uint8_t *data = NULL;
            size_t data_len = 0;
            if (blip_archive_file_content(buf, buf_len, i, &data, &data_len) == BLIP_OK) {
                total_bytes += data_len;
            }
            file_entries++;
        }
    }

    /* Progress: determinate extraction phase */
    progrez_ctx *progress = progrez_create("Extracting");
    if (progress) {
        progrez_set_identity(progress, "blar", "archive extraction");
        progrez_set_determinate(progress, file_entries, total_bytes);
    }

    uint64_t files_done = 0;

    /* Second pass: extract files */
    for (uint64_t i = 0; i < count; i++) {
        uint8_t entry_type = 0;
        blip_archive_entry_type(buf, buf_len, i, &entry_type);
        if (entry_type == 0x07) continue; /* skip DIR entries */

        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, i, &path, &path_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: extract: entry %llu: %s\n",
                    (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_IO;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: extract: entry %llu: %s\n",
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
                fprintf(stderr, "blar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                if (progress) { progrez_finish(progress); progrez_destroy(progress); }
                fprintf(stderr, "blar: extract: path too long\n");
                free(buf);
                return EXIT_IO;
            }
            memcpy(out_path, path, path_len);
            out_path[path_len] = '\0';
        }

        /* Ensure parent dirs exist (for implicit directories) */
        if (!ensure_parent_dir(out_path)) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: extract: cannot create directory for '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        if (!write_file(out_path, data, data_len)) {
            if (progress) { progrez_finish(progress); progrez_destroy(progress); }
            fprintf(stderr, "blar: extract: cannot write '%s': %s\n",
                    out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

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

        bytes_done += data_len;
        files_done++;
        if (progress) progrez_update(progress, files_done, bytes_done);
    }

    if (progress) { progrez_finish(progress); progrez_destroy(progress); }
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

/* ── cmd_info ─────────────────────────────────────────────────────────── */

static int cmd_info(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "blar: info: missing archive path\n");
        return EXIT_USAGE;
    }

    const char *archive_path = argv[0];
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
            const uint8_t *data = NULL;
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
