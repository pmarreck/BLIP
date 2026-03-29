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

#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
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
static int cmd_text(int argc, char **argv);
static int cmd_from_text(int argc, char **argv);
static int cmd_explode(int argc, char **argv);
static int cmd_implode(int argc, char **argv);
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
    bool expand_containers; /* expand zip containers into DIR+FILE entries */
    bool expand_all_zips;   /* also expand .zip/.gz files (normally excluded) */
    uint8_t num_threads;    /* thread count for parallel work (0=auto) */
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
    el->expand_containers = false;
    el->expand_all_zips = false;
    el->num_threads = 0;
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
        "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "lz4",
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

/* Expand a zip container into DIR + FILE entries in the entry list.
 * Returns true on success, false on failure (caller should fall back to opaque). */
static bool expand_zip_container(entry_list_t *el,
                                  const uint8_t *content, size_t content_len,
                                  const blip_archive_entry *file_entry) {
    /* Check for encryption — don't expand encrypted zips */
    if (blip_zip_has_encrypted(content, content_len)) return false;

    /* Get entry count */
    uint64_t zip_count = 0;
    int32_t rc = blip_zip_entry_count(content, content_len, &zip_count);
    if (rc != BLIP_OK) return false;

    /* Create the container DIR entry (using the original file's metadata) */
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
    dir_entry.container_type = "zip";
    dir_entry.container_type_len = 3;
    dir_entry.zip_compression_method = 0xFFFF;
    dir_entry.pdf_stream_offset = UINT64_MAX;
    dir_entry.pdf_stream_length = UINT64_MAX;
    memset(dir_entry.xh64, 0, 8);

    if (!entry_list_add(el, dir_entry)) return false;

    /* Add each zip inner entry */
    for (uint64_t i = 0; i < zip_count; i++) {
        const char *inner_path = NULL;
        size_t inner_path_len = 0;
        uint16_t comp_method = 0;
        uint64_t uncomp_size = 0;
        uint16_t mtime = 0, mdate = 0;
        uint8_t is_dir = 0;

        rc = blip_zip_entry_info(content, content_len, i,
            &inner_path, &inner_path_len, &comp_method,
            &uncomp_size, &mtime, &mdate, &is_dir);
        if (rc != BLIP_OK) return false;

        /* Build combined path: archive_path/inner_path */
        size_t combined_len = file_entry->path_len + 1 + inner_path_len;
        char *combined = malloc(combined_len + 1);
        if (!combined) return false;
        memcpy(combined, file_entry->path, file_entry->path_len);
        combined[file_entry->path_len] = '/';
        memcpy(combined + file_entry->path_len + 1, inner_path, inner_path_len);
        combined[combined_len] = '\0';

        /* Strip trailing slash for dir entries (BLIP convention) */
        if (is_dir && combined_len > 0 && combined[combined_len - 1] == '/') {
            combined[--combined_len] = '\0';
        }

        if (!entry_list_add_content(el, (uint8_t *)combined)) {
            free(combined);
            return false;
        }

        int64_t entry_mtime_ns = msdos_to_ns(mtime, mdate);

        if (is_dir) {
            blip_archive_entry nested_dir;
            memset(&nested_dir, 0, sizeof(nested_dir));
            nested_dir.path = combined;
            nested_dir.path_len = combined_len;
            nested_dir.is_dir = 1;
            nested_dir.mtime_ns = entry_mtime_ns;
            nested_dir.container_type = NULL;
            nested_dir.container_type_len = 0;
            nested_dir.zip_compression_method = 0xFFFF;
            nested_dir.pdf_stream_offset = UINT64_MAX;
            nested_dir.pdf_stream_length = UINT64_MAX;
            memset(nested_dir.xh64, 0, 8);
            if (!entry_list_add(el, nested_dir)) return false;
        } else {
            /* Extract file content */
            uint8_t *data = NULL;
            size_t data_len = 0;
            rc = blip_zip_extract_entry(content, content_len, i, &data, &data_len);
            if (rc != BLIP_OK) return false;

            /* Copy to malloc'd buffer (blip_free vs free) */
            uint8_t *owned = malloc(data_len);
            if (!owned) {
                blip_free(data, data_len);
                return false;
            }
            memcpy(owned, data, data_len);
            blip_free(data, data_len);

            if (!entry_list_add_content(el, owned)) {
                free(owned);
                return false;
            }

            blip_archive_entry file_ent;
            memset(&file_ent, 0, sizeof(file_ent));
            file_ent.path = combined;
            file_ent.path_len = combined_len;
            file_ent.content = owned;
            file_ent.content_len = data_len;
            file_ent.is_dir = 0;
            file_ent.mtime_ns = entry_mtime_ns;
            file_ent.zip_compression_method = comp_method;
            file_ent.pdf_stream_offset = UINT64_MAX;
            file_ent.pdf_stream_length = UINT64_MAX;
            file_ent.container_type = NULL;
            file_ent.container_type_len = 0;
            memset(file_ent.xh64, 0, 8);
            if (!entry_list_add(el, file_ent)) return false;

            el->bytes_seen += data_len;
        }
    }

    return true;
}

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

static bool expand_pdf_container(entry_list_t *el,
                                  const uint8_t *content, size_t content_len,
                                  const blip_archive_entry *file_entry) {
    /* ── Phase 1: Expand content streams FIRST ──
     * Decompresses FlateDecode non-image streams in the original PDF so LZMA2
     * can compress the raw text/operators much better than zlib-compressed entropy.
     * This MUST happen before image detection so that image offsets in the
     * expanded PDF match the offsets that will be stored as 'po' metadata. */
    uint8_t *working_pdf = NULL;
    size_t working_len = 0;
    bool owns_working = false;

    {
        uint64_t cs_count = 0;
        uint64_t *cs_offsets = NULL, *cs_lengths = NULL;
        if (blip_pdf_content_streams(content, content_len, &cs_count,
                &cs_offsets, &cs_lengths) == BLIP_OK && cs_count > 0)
        {
            size_t rep_n = 0;
            uint64_t *rep_starts = calloc(cs_count, sizeof(uint64_t));
            uint64_t *rep_orig_lens = calloc(cs_count, sizeof(uint64_t));
            uint8_t **rep_datas = calloc(cs_count, sizeof(uint8_t *));
            size_t *rep_lens = calloc(cs_count, sizeof(size_t));

            if (rep_starts && rep_orig_lens && rep_datas && rep_lens) {
                for (uint64_t ci = 0; ci < cs_count; ci++) {
                    uint8_t *decompressed = NULL;
                    size_t decompressed_len = 0;
                    if (blip_zlib_decompress(content + cs_offsets[ci],
                            (size_t)cs_lengths[ci],
                            &decompressed, &decompressed_len) == BLIP_OK)
                    {
                        rep_starts[rep_n] = cs_offsets[ci];
                        rep_orig_lens[rep_n] = cs_lengths[ci];
                        rep_datas[rep_n] = decompressed;
                        rep_lens[rep_n] = decompressed_len;
                        rep_n++;
                    }
                }

                if (rep_n > 0) {
                    uint8_t *expanded = NULL;
                    size_t expanded_len = 0;
                    int32_t rw_rc = blip_pdf_rewrite_streams(content, content_len,
                        rep_n, rep_starts, rep_orig_lens,
                        (const uint8_t *const *)rep_datas, rep_lens,
                        &expanded, &expanded_len);
                    if (rw_rc == BLIP_OK) {
                        working_pdf = malloc(expanded_len);
                        if (working_pdf) {
                            memcpy(working_pdf, expanded, expanded_len);
                            working_len = expanded_len;
                            owns_working = true;
                        }
                        blip_free(expanded, expanded_len);
                    }
                }

                for (size_t ci = 0; ci < rep_n; ci++)
                    blip_free(rep_datas[ci], rep_lens[ci]);
            }

            free(rep_starts); free(rep_orig_lens);
            free(rep_datas); free(rep_lens);
            blip_free((uint8_t *)cs_offsets, cs_count * sizeof(*cs_offsets));
            blip_free((uint8_t *)cs_lengths, cs_count * sizeof(*cs_lengths));
        }
    }

    /* If no content stream expansion happened, work with original PDF */
    if (!working_pdf) {
        working_pdf = (uint8_t *)content; /* const-cast OK: not modified */
        working_len = content_len;
        owns_working = false;
    }

    /* ── Phase 2: Find image streams in (possibly expanded) PDF ──
     * Offsets returned here are valid for working_pdf, which becomes the shell
     * base. No delta adjustment needed. */
    uint64_t jpeg_count = 0;
    uint64_t *offsets = NULL;
    uint64_t *lengths = NULL;
    uint32_t *obj_nums = NULL;
    uint32_t *gen_nums = NULL;
    if (blip_pdf_jpeg_streams(working_pdf, working_len, &jpeg_count,
            &offsets, &lengths, &obj_nums, &gen_nums) != BLIP_OK)
        jpeg_count = 0;

    uint64_t flate_count = 0;
    uint64_t *fl_offsets = NULL, *fl_lengths = NULL;
    uint32_t *fl_obj_nums = NULL, *fl_gen_nums = NULL;
    uint16_t *fl_predictors = NULL;
    uint32_t *fl_columns = NULL, *fl_widths = NULL, *fl_heights = NULL;
    uint8_t *fl_colors = NULL, *fl_bpcs = NULL;
    if (blip_pdf_flate_streams(working_pdf, working_len, &flate_count,
            &fl_offsets, &fl_lengths, &fl_obj_nums, &fl_gen_nums,
            &fl_predictors, &fl_columns, &fl_colors, &fl_bpcs,
            &fl_widths, &fl_heights) != BLIP_OK)
        flate_count = 0;

    if (jpeg_count == 0 && flate_count == 0) {
        if (jpeg_count == 0 && offsets) {
            blip_free((uint8_t *)offsets, 0); blip_free((uint8_t *)lengths, 0);
            blip_free((uint8_t *)obj_nums, 0); blip_free((uint8_t *)gen_nums, 0);
        }
        if (owns_working) free(working_pdf);
        return false;
    }

    /* ── Phase 3: Transcode JPEGs to JXL ── */
    uint8_t **jxl_bufs = calloc(jpeg_count ? jpeg_count : 1, sizeof(uint8_t *));
    size_t *jxl_lens = calloc(jpeg_count ? jpeg_count : 1, sizeof(size_t));
    if (!jxl_bufs || !jxl_lens) { free(jxl_bufs); free(jxl_lens); goto cleanup_arrays; }

    if (jpeg_count > 0) {
        uint8_t nthreads = el->num_threads;
        if (nthreads == 0) {
            long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
            nthreads = (ncpu > 0 && ncpu < 255) ? (uint8_t)ncpu : 4;
        }
        if ((uint64_t)nthreads > jpeg_count) nthreads = (uint8_t)jpeg_count;

        if (nthreads > 1 && jpeg_count > 1) {
            jxl_transcode_ctx_t ctx = {
                .content = working_pdf, .offsets = offsets, .lengths = lengths,
                .jpeg_count = jpeg_count, .jxl_bufs = jxl_bufs, .jxl_lens = jxl_lens,
                .next_idx = 0,
            };
            pthread_t *threads = calloc(nthreads, sizeof(pthread_t));
            if (threads) {
                for (int t = 0; t < nthreads; t++)
                    pthread_create(&threads[t], NULL, jxl_transcode_worker, &ctx);
                for (int t = 0; t < nthreads; t++)
                    pthread_join(threads[t], NULL);
                free(threads);
            }
        } else {
            for (uint64_t i = 0; i < jpeg_count; i++) {
                uint8_t *jxl_data = NULL; size_t jxl_len = 0;
                if (blip_jxl_from_jpeg(working_pdf + offsets[i], (size_t)lengths[i],
                                       &jxl_data, &jxl_len) == BLIP_OK) {
                    jxl_bufs[i] = jxl_data; jxl_lens[i] = jxl_len;
                }
            }
        }
    }

    /* ── Transcode FlateDecode images to JXL ── */
    uint8_t **fl_jxl_bufs = calloc(flate_count ? flate_count : 1, sizeof(uint8_t *));
    size_t *fl_jxl_lens = calloc(flate_count ? flate_count : 1, sizeof(size_t));
    if (!fl_jxl_bufs || !fl_jxl_lens) { free(fl_jxl_bufs); free(fl_jxl_lens); goto cleanup_jpeg; }

    for (uint64_t i = 0; i < flate_count; i++) {
        /* Decompress zlib → filtered data */
        uint8_t *filtered = NULL; size_t filtered_len = 0;
        if (blip_zlib_decompress(working_pdf + fl_offsets[i], (size_t)fl_lengths[i],
                                 &filtered, &filtered_len) != BLIP_OK)
            continue;

        /* Defilter → raw pixels */
        uint8_t *pixels = NULL; size_t pixels_len = 0;
        if (blip_pdf_defilter(filtered, filtered_len,
                              fl_columns[i], fl_colors[i], fl_bpcs[i], fl_predictors[i],
                              &pixels, &pixels_len) != BLIP_OK) {
            blip_free(filtered, filtered_len);
            continue;
        }
        blip_free(filtered, filtered_len);

        /* Encode pixels → JXL lossless */
        uint8_t *jxl_data = NULL; size_t jxl_len = 0;
        uint32_t num_channels = (uint32_t)fl_colors[i];
        uint32_t bps = (uint32_t)fl_bpcs[i];
        if (blip_jxl_from_pixels(pixels, pixels_len,
                                 fl_widths[i], fl_heights[i], num_channels, bps,
                                 &jxl_data, &jxl_len) == BLIP_OK) {
            fl_jxl_bufs[i] = jxl_data;
            fl_jxl_lens[i] = jxl_len;
        }
        blip_free(pixels, pixels_len);
    }

    /* Count total successes */
    size_t jpeg_success = 0, flate_success = 0;
    for (uint64_t i = 0; i < jpeg_count; i++) if (jxl_bufs[i]) jpeg_success++;
    for (uint64_t i = 0; i < flate_count; i++) if (fl_jxl_bufs[i]) flate_success++;

    if (jpeg_success == 0 && flate_success == 0) {
        free(fl_jxl_bufs); free(fl_jxl_lens);
        goto cleanup_jpeg;
    }

    /* ── Phase 4: Build shell from working_pdf, zeroing image regions ──
     * Offsets are already correct for working_pdf. */
    size_t total_zeroed = jpeg_success + flate_success;
    uint64_t *shell_offsets = calloc(total_zeroed, sizeof(uint64_t));
    uint64_t *shell_lengths = calloc(total_zeroed, sizeof(uint64_t));
    if (!shell_offsets || !shell_lengths) {
        free(shell_offsets); free(shell_lengths);
        for (uint64_t i = 0; i < flate_count; i++)
            if (fl_jxl_bufs[i]) blip_free(fl_jxl_bufs[i], fl_jxl_lens[i]);
        free(fl_jxl_bufs); free(fl_jxl_lens);
        goto cleanup_jpeg;
    }
    size_t si = 0;
    for (uint64_t i = 0; i < jpeg_count; i++) {
        if (jxl_bufs[i]) { shell_offsets[si] = offsets[i]; shell_lengths[si] = lengths[i]; si++; }
    }
    for (uint64_t i = 0; i < flate_count; i++) {
        if (fl_jxl_bufs[i]) { shell_offsets[si] = fl_offsets[i]; shell_lengths[si] = fl_lengths[i]; si++; }
    }

    uint8_t *shell = NULL; size_t shell_len = 0;
    int32_t rc = blip_pdf_create_shell(working_pdf, working_len,
        shell_offsets, shell_lengths, total_zeroed, &shell, &shell_len);
    free(shell_offsets); free(shell_lengths);

    if (rc != BLIP_OK) {
        for (uint64_t i = 0; i < flate_count; i++)
            if (fl_jxl_bufs[i]) blip_free(fl_jxl_bufs[i], fl_jxl_lens[i]);
        free(fl_jxl_bufs); free(fl_jxl_lens);
        goto cleanup_jpeg;
    }

    /* working_pdf no longer needed — shell has the data we need */
    if (owns_working) { free(working_pdf); working_pdf = NULL; owns_working = false; }

    uint8_t *shell_owned = malloc(shell_len);
    if (!shell_owned) {
        blip_free(shell, shell_len);
        for (uint64_t i = 0; i < flate_count; i++)
            if (fl_jxl_bufs[i]) blip_free(fl_jxl_bufs[i], fl_jxl_lens[i]);
        free(fl_jxl_bufs); free(fl_jxl_lens);
        goto cleanup_jpeg;
    }
    memcpy(shell_owned, shell, shell_len);
    blip_free(shell, shell_len);

    if (!entry_list_add_content(el, shell_owned)) {
        free(shell_owned);
        for (uint64_t i = 0; i < flate_count; i++)
            if (fl_jxl_bufs[i]) blip_free(fl_jxl_bufs[i], fl_jxl_lens[i]);
        free(fl_jxl_bufs); free(fl_jxl_lens);
        goto cleanup_jpeg;
    }

    /* ── Phase 5: Create container DIR entry ── */
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
    dir_entry.container_type = "pdf";
    dir_entry.container_type_len = 3;
    dir_entry.zip_compression_method = 0xFFFF;
    dir_entry.pdf_stream_offset = UINT64_MAX;
    dir_entry.pdf_stream_length = UINT64_MAX;
    memset(dir_entry.xh64, 0, 8);
    if (!entry_list_add(el, dir_entry)) goto fail;

    /* ── Add __body__ FILE entry (the shell) ── */
    {
        size_t body_path_len = file_entry->path_len + strlen("/__body__");
        char *body_path = malloc(body_path_len + 1);
        if (!body_path) goto fail;
        memcpy(body_path, file_entry->path, file_entry->path_len);
        memcpy(body_path + file_entry->path_len, "/__body__", strlen("/__body__") + 1);
        if (!entry_list_add_content(el, (uint8_t *)body_path)) { free(body_path); goto fail; }

        blip_archive_entry body_ent;
        memset(&body_ent, 0, sizeof(body_ent));
        body_ent.path = body_path;
        body_ent.path_len = body_path_len;
        body_ent.content = shell_owned;
        body_ent.content_len = shell_len;
        body_ent.is_dir = 0;
        body_ent.mode = file_entry->mode;
        body_ent.mtime_ns = file_entry->mtime_ns;
        body_ent.zip_compression_method = 0xFFFF;
        body_ent.pdf_stream_offset = UINT64_MAX;
        body_ent.pdf_stream_length = UINT64_MAX;
        memset(body_ent.xh64, 0, 8);
        if (!entry_list_add(el, body_ent)) goto fail;
    }

    /* ── Add JPEG JXL image FILE entries ──
     * po values come from Phase 2 scan of working_pdf — correct for the shell. */
    for (uint64_t i = 0; i < jpeg_count; i++) {
        if (!jxl_bufs[i]) continue;
        uint8_t *jxl_owned = malloc(jxl_lens[i]);
        if (!jxl_owned) goto fail;
        memcpy(jxl_owned, jxl_bufs[i], jxl_lens[i]);
        blip_free(jxl_bufs[i], jxl_lens[i]); jxl_bufs[i] = NULL;
        if (!entry_list_add_content(el, jxl_owned)) { free(jxl_owned); goto fail; }

        char img_name[64];
        snprintf(img_name, sizeof(img_name), "/__img_%u_%u.jxl",
                 (unsigned)obj_nums[i], (unsigned)gen_nums[i]);
        size_t img_path_len = file_entry->path_len + strlen(img_name);
        char *img_path = malloc(img_path_len + 1);
        if (!img_path) goto fail;
        memcpy(img_path, file_entry->path, file_entry->path_len);
        memcpy(img_path + file_entry->path_len, img_name, strlen(img_name) + 1);
        if (!entry_list_add_content(el, (uint8_t *)img_path)) { free(img_path); goto fail; }

        blip_archive_entry img_ent;
        memset(&img_ent, 0, sizeof(img_ent));
        img_ent.path = img_path;
        img_ent.path_len = img_path_len;
        img_ent.content = jxl_owned;
        img_ent.content_len = jxl_lens[i];
        img_ent.is_dir = 0;
        img_ent.mode = file_entry->mode;
        img_ent.mtime_ns = file_entry->mtime_ns;
        img_ent.zip_compression_method = 0xFFFF;
        img_ent.pdf_stream_offset = offsets[i];
        img_ent.pdf_stream_length = lengths[i];
        img_ent.jxl_source_format = "jpeg";
        img_ent.jxl_source_format_len = 4;
        memset(img_ent.xh64, 0, 8);
        if (!entry_list_add(el, img_ent)) goto fail;
        el->bytes_seen += jxl_lens[i];
    }

    /* ── Add FlateDecode JXL image FILE entries ──
     * po values come from Phase 2 scan — correct for the shell, no adjustment. */
    for (uint64_t i = 0; i < flate_count; i++) {
        if (!fl_jxl_bufs[i]) continue;
        uint8_t *jxl_owned = malloc(fl_jxl_lens[i]);
        if (!jxl_owned) goto fail;
        memcpy(jxl_owned, fl_jxl_bufs[i], fl_jxl_lens[i]);
        blip_free(fl_jxl_bufs[i], fl_jxl_lens[i]); fl_jxl_bufs[i] = NULL;
        if (!entry_list_add_content(el, jxl_owned)) { free(jxl_owned); goto fail; }

        char img_name[64];
        snprintf(img_name, sizeof(img_name), "/__img_%u_%u.jxl",
                 (unsigned)fl_obj_nums[i], (unsigned)fl_gen_nums[i]);
        size_t img_path_len = file_entry->path_len + strlen(img_name);
        char *img_path = malloc(img_path_len + 1);
        if (!img_path) goto fail;
        memcpy(img_path, file_entry->path, file_entry->path_len);
        memcpy(img_path + file_entry->path_len, img_name, strlen(img_name) + 1);
        if (!entry_list_add_content(el, (uint8_t *)img_path)) { free(img_path); goto fail; }

        blip_archive_entry img_ent;
        memset(&img_ent, 0, sizeof(img_ent));
        img_ent.path = img_path;
        img_ent.path_len = img_path_len;
        img_ent.content = jxl_owned;
        img_ent.content_len = fl_jxl_lens[i];
        img_ent.is_dir = 0;
        img_ent.mode = file_entry->mode;
        img_ent.mtime_ns = file_entry->mtime_ns;
        img_ent.zip_compression_method = 0xFFFF;
        img_ent.pdf_stream_offset = fl_offsets[i];
        img_ent.pdf_stream_length = fl_lengths[i];
        img_ent.jxl_source_format = "flate";
        img_ent.jxl_source_format_len = 5;
        img_ent.flate_predictor = fl_predictors[i];
        img_ent.flate_columns = fl_columns[i];
        img_ent.flate_colors = fl_colors[i];
        img_ent.flate_bpc = fl_bpcs[i];
        memset(img_ent.xh64, 0, 8);
        if (!entry_list_add(el, img_ent)) goto fail;
        el->bytes_seen += fl_jxl_lens[i];
    }

    /* ── Cleanup and return ── */
    if (jpeg_count > 0) {
        blip_free((uint8_t *)offsets, jpeg_count * sizeof(*offsets));
        blip_free((uint8_t *)lengths, jpeg_count * sizeof(*lengths));
        blip_free((uint8_t *)obj_nums, jpeg_count * sizeof(*obj_nums));
        blip_free((uint8_t *)gen_nums, jpeg_count * sizeof(*gen_nums));
    }
    if (flate_count > 0) {
        blip_free((uint8_t *)fl_offsets, flate_count * sizeof(*fl_offsets));
        blip_free((uint8_t *)fl_lengths, flate_count * sizeof(*fl_lengths));
        blip_free((uint8_t *)fl_obj_nums, flate_count * sizeof(*fl_obj_nums));
        blip_free((uint8_t *)fl_gen_nums, flate_count * sizeof(*fl_gen_nums));
        blip_free((uint8_t *)fl_predictors, flate_count * sizeof(*fl_predictors));
        blip_free((uint8_t *)fl_columns, flate_count * sizeof(*fl_columns));
        blip_free((uint8_t *)fl_colors, flate_count * sizeof(*fl_colors));
        blip_free((uint8_t *)fl_bpcs, flate_count * sizeof(*fl_bpcs));
        blip_free((uint8_t *)fl_widths, flate_count * sizeof(*fl_widths));
        blip_free((uint8_t *)fl_heights, flate_count * sizeof(*fl_heights));
    }
    free(jxl_bufs); free(jxl_lens);
    free(fl_jxl_bufs); free(fl_jxl_lens);
    return true;

cleanup_jpeg:
    for (uint64_t i = 0; i < jpeg_count; i++)
        if (jxl_bufs[i]) blip_free(jxl_bufs[i], jxl_lens[i]);
    free(jxl_bufs); free(jxl_lens);
cleanup_arrays:
    if (owns_working) free(working_pdf);
    if (jpeg_count > 0) {
        blip_free((uint8_t *)offsets, jpeg_count * sizeof(*offsets));
        blip_free((uint8_t *)lengths, jpeg_count * sizeof(*lengths));
        blip_free((uint8_t *)obj_nums, jpeg_count * sizeof(*obj_nums));
        blip_free((uint8_t *)gen_nums, jpeg_count * sizeof(*gen_nums));
    }
    if (flate_count > 0) {
        blip_free((uint8_t *)fl_offsets, flate_count * sizeof(*fl_offsets));
        blip_free((uint8_t *)fl_lengths, flate_count * sizeof(*fl_lengths));
        blip_free((uint8_t *)fl_obj_nums, flate_count * sizeof(*fl_obj_nums));
        blip_free((uint8_t *)fl_gen_nums, flate_count * sizeof(*fl_gen_nums));
        blip_free((uint8_t *)fl_predictors, flate_count * sizeof(*fl_predictors));
        blip_free((uint8_t *)fl_columns, flate_count * sizeof(*fl_columns));
        blip_free((uint8_t *)fl_colors, flate_count * sizeof(*fl_colors));
        blip_free((uint8_t *)fl_bpcs, flate_count * sizeof(*fl_bpcs));
        blip_free((uint8_t *)fl_widths, flate_count * sizeof(*fl_widths));
        blip_free((uint8_t *)fl_heights, flate_count * sizeof(*fl_heights));
    }
    return false;

fail:
    if (owns_working) free(working_pdf);
    for (uint64_t i = 0; i < jpeg_count; i++)
        if (jxl_bufs[i]) blip_free(jxl_bufs[i], jxl_lens[i]);
    for (uint64_t i = 0; i < flate_count; i++)
        if (fl_jxl_bufs[i]) blip_free(fl_jxl_bufs[i], fl_jxl_lens[i]);
    if (jpeg_count > 0) {
        blip_free((uint8_t *)offsets, jpeg_count * sizeof(*offsets));
        blip_free((uint8_t *)lengths, jpeg_count * sizeof(*lengths));
        blip_free((uint8_t *)obj_nums, jpeg_count * sizeof(*obj_nums));
        blip_free((uint8_t *)gen_nums, jpeg_count * sizeof(*gen_nums));
    }
    if (flate_count > 0) {
        blip_free((uint8_t *)fl_offsets, flate_count * sizeof(*fl_offsets));
        blip_free((uint8_t *)fl_lengths, flate_count * sizeof(*fl_lengths));
        blip_free((uint8_t *)fl_obj_nums, flate_count * sizeof(*fl_obj_nums));
        blip_free((uint8_t *)fl_gen_nums, flate_count * sizeof(*fl_gen_nums));
        blip_free((uint8_t *)fl_predictors, flate_count * sizeof(*fl_predictors));
        blip_free((uint8_t *)fl_columns, flate_count * sizeof(*fl_columns));
        blip_free((uint8_t *)fl_colors, flate_count * sizeof(*fl_colors));
        blip_free((uint8_t *)fl_bpcs, flate_count * sizeof(*fl_bpcs));
        blip_free((uint8_t *)fl_widths, flate_count * sizeof(*fl_widths));
        blip_free((uint8_t *)fl_heights, flate_count * sizeof(*fl_heights));
    }
    free(jxl_bufs); free(jxl_lens);
    free(fl_jxl_bufs); free(fl_jxl_lens);
    return false;
}

/* Expand a PNG file by decomposing into JXL lossless pixels + metadata.
 * Returns true on success, false on failure (caller should fall back to opaque). */
static bool expand_png_container(entry_list_t *el,
                                  const uint8_t *content, size_t content_len,
                                  const blip_archive_entry *file_entry) {
    /* Skip tiny PNGs — overhead not worth it */
    if (content_len < 1024) return false;

    /* Parse PNG into pixels + metadata */
    uint8_t *pixels = NULL;
    size_t pixels_len = 0;
    uint32_t width = 0, height = 0, num_channels = 0, bits_per_sample = 0;
    uint8_t *meta = NULL;
    size_t meta_len = 0;

    if (blip_png_parse(content, content_len,
            &pixels, &pixels_len, &width, &height,
            &num_channels, &bits_per_sample,
            &meta, &meta_len) != BLIP_OK)
        return false;

    /* Encode pixels to JXL lossless */
    uint8_t *jxl_data = NULL;
    size_t jxl_len = 0;
    if (blip_jxl_from_pixels(pixels, pixels_len,
            width, height, num_channels, bits_per_sample,
            &jxl_data, &jxl_len) != BLIP_OK) {
        blip_free(pixels, pixels_len);
        blip_free(meta, meta_len);
        return false;
    }
    blip_free(pixels, pixels_len);

    /* Size check: if JXL+meta >= 90% of original, not worth expanding */
    if (jxl_len + meta_len >= (size_t)(content_len * 9 / 10)) {
        blip_free(jxl_data, jxl_len);
        blip_free(meta, meta_len);
        return false;
    }

    /* Copy JXL data to malloc'd buffer */
    uint8_t *jxl_owned = malloc(jxl_len);
    if (!jxl_owned) {
        blip_free(jxl_data, jxl_len);
        blip_free(meta, meta_len);
        return false;
    }
    memcpy(jxl_owned, jxl_data, jxl_len);
    blip_free(jxl_data, jxl_len);

    /* Copy meta to malloc'd buffer */
    uint8_t *meta_owned = malloc(meta_len);
    if (!meta_owned) {
        free(jxl_owned);
        blip_free(meta, meta_len);
        return false;
    }
    memcpy(meta_owned, meta, meta_len);
    blip_free(meta, meta_len);

    if (!entry_list_add_content(el, jxl_owned) ||
        !entry_list_add_content(el, meta_owned)) {
        return false;
    }

    /* Create container DIR entry */
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
    dir_entry.container_type = "png";
    dir_entry.container_type_len = 3;
    dir_entry.zip_compression_method = 0xFFFF;
    dir_entry.pdf_stream_offset = UINT64_MAX;
    dir_entry.pdf_stream_length = UINT64_MAX;
    memset(dir_entry.xh64, 0, 8);
    if (!entry_list_add(el, dir_entry)) return false;

    /* Add __meta__ FILE entry */
    {
        size_t meta_path_len = file_entry->path_len + strlen("/__meta__");
        char *meta_path = malloc(meta_path_len + 1);
        if (!meta_path) return false;
        memcpy(meta_path, file_entry->path, file_entry->path_len);
        memcpy(meta_path + file_entry->path_len, "/__meta__", strlen("/__meta__") + 1);
        if (!entry_list_add_content(el, (uint8_t *)meta_path)) {
            free(meta_path);
            return false;
        }

        blip_archive_entry meta_ent;
        memset(&meta_ent, 0, sizeof(meta_ent));
        meta_ent.path = meta_path;
        meta_ent.path_len = meta_path_len;
        meta_ent.content = meta_owned;
        meta_ent.content_len = meta_len;
        meta_ent.is_dir = 0;
        meta_ent.mode = file_entry->mode;
        meta_ent.mtime_ns = file_entry->mtime_ns;
        meta_ent.zip_compression_method = 0xFFFF;
        meta_ent.pdf_stream_offset = UINT64_MAX;
        meta_ent.pdf_stream_length = UINT64_MAX;
        memset(meta_ent.xh64, 0, 8);
        if (!entry_list_add(el, meta_ent)) return false;
    }

    /* Add __pixels__.jxl FILE entry */
    {
        size_t jxl_path_len = file_entry->path_len + strlen("/__pixels__.jxl");
        char *jxl_path = malloc(jxl_path_len + 1);
        if (!jxl_path) return false;
        memcpy(jxl_path, file_entry->path, file_entry->path_len);
        memcpy(jxl_path + file_entry->path_len, "/__pixels__.jxl", strlen("/__pixels__.jxl") + 1);
        if (!entry_list_add_content(el, (uint8_t *)jxl_path)) {
            free(jxl_path);
            return false;
        }

        blip_archive_entry jxl_ent;
        memset(&jxl_ent, 0, sizeof(jxl_ent));
        jxl_ent.path = jxl_path;
        jxl_ent.path_len = jxl_path_len;
        jxl_ent.content = jxl_owned;
        jxl_ent.content_len = jxl_len;
        jxl_ent.is_dir = 0;
        jxl_ent.mode = file_entry->mode;
        jxl_ent.mtime_ns = file_entry->mtime_ns;
        jxl_ent.zip_compression_method = 0xFFFF;
        jxl_ent.pdf_stream_offset = UINT64_MAX;
        jxl_ent.pdf_stream_length = UINT64_MAX;
        jxl_ent.jxl_source_format = "png";
        jxl_ent.jxl_source_format_len = 3;
        memset(jxl_ent.xh64, 0, 8);
        if (!entry_list_add(el, jxl_ent)) return false;
    }

    el->bytes_seen += jxl_len + meta_len;
    return true;
}

/* ── Codec plugin interface ───────────────────────────────────────────── */

/* A codec describes how to detect and expand a container format. */
typedef struct {
    const char *name;                   /* e.g. "pdf", "png", "zip" */
    const char *const *extensions;      /* NULL-terminated list of file extensions */
    bool (*detect)(const uint8_t *buf, size_t len);
    bool (*expand)(entry_list_t *el, const uint8_t *content, size_t content_len,
                   const blip_archive_entry *entry);
    bool (*collapse)(entry_list_t *el, const uint8_t *content, size_t content_len,
                     const blip_archive_entry *entry);  /* NULL = not implemented */
} blar_codec_t;

/* A registry holds an array of codecs. */
typedef struct {
    const blar_codec_t *codecs;
    size_t count;
} blar_codec_registry_t;

/* ── JPEG container expansion ────────────────────────────────────────── */

static bool is_jpeg(const uint8_t *buf, size_t len) {
    return len >= 3 && buf[0] == 0xFF && buf[1] == 0xD8 && buf[2] == 0xFF;
}

static bool expand_jpeg_container(entry_list_t *el,
                                   const uint8_t *content, size_t content_len,
                                   const blip_archive_entry *file_entry) {
    /* Skip tiny JPEGs */
    if (content_len < 1024) return false;

    /* Transcode JPEG → JXL lossless */
    uint8_t *jxl_data = NULL;
    size_t jxl_len = 0;
    if (blip_jxl_from_jpeg(content, content_len, &jxl_data, &jxl_len) != BLIP_OK)
        return false;

    /* Size check: if JXL >= 90% of original, not worth expanding */
    if (jxl_len >= (size_t)(content_len * 9 / 10)) {
        blip_free(jxl_data, jxl_len);
        return false;
    }

    /* Copy JXL data to malloc'd buffer */
    uint8_t *jxl_owned = malloc(jxl_len);
    if (!jxl_owned) {
        blip_free(jxl_data, jxl_len);
        return false;
    }
    memcpy(jxl_owned, jxl_data, jxl_len);
    blip_free(jxl_data, jxl_len);

    if (!entry_list_add_content(el, jxl_owned))
        return false;

    /* Create container DIR entry */
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
    dir_entry.container_type = "jpeg";
    dir_entry.container_type_len = 4;
    dir_entry.zip_compression_method = 0xFFFF;
    dir_entry.pdf_stream_offset = UINT64_MAX;
    dir_entry.pdf_stream_length = UINT64_MAX;
    memset(dir_entry.xh64, 0, 8);
    if (!entry_list_add(el, dir_entry)) return false;

    /* Add __body__.jxl FILE entry */
    {
        size_t jxl_path_len = file_entry->path_len + strlen("/__body__.jxl");
        char *jxl_path = malloc(jxl_path_len + 1);
        if (!jxl_path) return false;
        memcpy(jxl_path, file_entry->path, file_entry->path_len);
        memcpy(jxl_path + file_entry->path_len, "/__body__.jxl", strlen("/__body__.jxl") + 1);
        if (!entry_list_add_content(el, (uint8_t *)jxl_path))
            return false;

        blip_archive_entry jxl_entry;
        memset(&jxl_entry, 0, sizeof(jxl_entry));
        jxl_entry.path = jxl_path;
        jxl_entry.path_len = jxl_path_len;
        jxl_entry.content = jxl_owned;
        jxl_entry.content_len = jxl_len;
        jxl_entry.is_dir = 0;
        jxl_entry.mode = file_entry->mode;
        jxl_entry.jxl_source_format = "jpeg";
        jxl_entry.jxl_source_format_len = 4;
        jxl_entry.zip_compression_method = 0xFFFF;
        jxl_entry.pdf_stream_offset = UINT64_MAX;
        jxl_entry.pdf_stream_length = UINT64_MAX;
        if (!entry_list_add(el, jxl_entry)) return false;
    }

    return true;
}

/* ── Builtin codec structs & registry ─────────────────────────────────── */

static const char *const jpeg_extensions[] = { ".jpg", ".jpeg", ".jpe", NULL };
static const char *const pdf_extensions[] = { ".pdf", NULL };
static const char *const png_extensions[] = { ".png", NULL };
static const char *const zip_extensions[] = { ".zip", ".jar", ".war", ".ear", ".apk", ".ipa",
                                              ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp",
                                              ".epub", ".cbz", NULL };

static const blar_codec_t builtin_codecs[] = {
    {
        .name       = "jpeg",
        .extensions = jpeg_extensions,
        .detect     = is_jpeg,
        .expand     = expand_jpeg_container,
        .collapse   = NULL,
    },
    {
        .name       = "pdf",
        .extensions = pdf_extensions,
        .detect     = blip_is_pdf,
        .expand     = expand_pdf_container,
        .collapse   = NULL,
    },
    {
        .name       = "png",
        .extensions = png_extensions,
        .detect     = blip_is_png,
        .expand     = expand_png_container,
        .collapse   = NULL,
    },
    {
        .name       = "zip",
        .extensions = zip_extensions,
        .detect     = blip_is_zip,
        .expand     = expand_zip_container,
        .collapse   = NULL,
    },
};

static const blar_codec_registry_t builtin_registry = {
    .codecs = builtin_codecs,
    .count  = sizeof(builtin_codecs) / sizeof(builtin_codecs[0]),
};

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
                                               const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < reg->count; i++) {
        if (reg->codecs[i].detect && reg->codecs[i].detect(buf, len)) {
            return &reg->codecs[i];
        }
    }
    return NULL;
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
static bool expand_containers_pass(entry_list_t *el) {
    /* Count expandable files and their total bytes for progress */
    size_t expandable = 0;
    uint64_t total_expandable_bytes = 0;
    for (size_t i = 0; i < el->count; i++) {
        if (el->entries[i].is_dir) continue;
        const uint8_t *content = el->entries[i].content;
        size_t content_len = el->entries[i].content_len;
        const blar_codec_t *codec = blar_codec_detect(&builtin_registry, content, content_len);
        if (codec) {
            /* ZIP special case: skip archives unless --expand-all-zips */
            if (strcmp(codec->name, "zip") == 0 &&
                !el->expand_all_zips && is_archive_extension(el->entries[i].path)) {
                codec = NULL;
            }
        }
        if (codec) {
            expandable++;
            total_expandable_bytes += content_len;
        }
    }
    if (expandable == 0) return true;

    /* Set up progress for expansion phase */
    if (el->progress) {
        progrez_set_label(el->progress, "Expanding");
        progrez_set_determinate(el->progress, expandable, total_expandable_bytes);
        progrez_update(el->progress, 0, 0);
    }

    /* Iterate over the ORIGINAL count — expansion appends new entries
     * beyond this range, so we won't re-process them. */
    size_t original_count = el->count;
    size_t done = 0;
    uint64_t bytes_expanded = 0;
    for (size_t i = 0; i < original_count; i++) {
        if (el->entries[i].is_dir) continue;
        const uint8_t *content = el->entries[i].content;
        size_t content_len = el->entries[i].content_len;

        /* Copy the entry by value — expand_*_container() calls entry_list_add()
         * which may realloc el->entries, invalidating any pointer into it. */
        blip_archive_entry entry_copy = el->entries[i];

        bool expanded = false;

        /* Update label with current filename */
        if (el->progress) {
            const char *basename = strrchr(entry_copy.path, '/');
            basename = basename ? basename + 1 : entry_copy.path;
            char label_buf[256];
            snprintf(label_buf, sizeof(label_buf), "Expanding: %s", basename);
            progrez_set_label(el->progress, label_buf);
        }

        /* Detect and expand via codec registry */
        {
            const blar_codec_t *codec = blar_codec_detect(&builtin_registry, content, content_len);
            if (codec) {
                /* ZIP special case: skip archives unless --expand-all-zips */
                if (strcmp(codec->name, "zip") == 0 &&
                    !el->expand_all_zips && is_archive_extension(entry_copy.path)) {
                    codec = NULL;
                }
                if (codec && codec->expand(el, content, content_len, &entry_copy)) {
                    expanded = true;
                }
            }
        }

        if (expanded) {
            /* The expand_*_container functions appended new entries to el.
             * The original entry at index i was passed as file_entry
             * (used for metadata). We need to remove the opaque entry at
             * index i since the expanded DIR+children replaced it.
             * The expand functions already added the DIR entry — we just
             * need to mark this slot as consumed. Overwrite with the last
             * original entry and adjust. Actually — the expand functions
             * add entries at the end, including the DIR. So the original
             * opaque entry at index i is now stale. Remove it by shifting. */
            /* Shift remaining entries down */
            memmove(&el->entries[i], &el->entries[i + 1],
                    (el->count - i - 1) * sizeof(blip_archive_entry));
            el->count--;
            original_count--;
            i--; /* re-examine this index */
            done++;
            bytes_expanded += content_len;
            if (el->progress)
                progrez_update(el->progress, done, bytes_expanded);
        }
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
        "  --no-expand-containers  Don't expand zip containers (with -z)\n"
        "  --expand-all-zips      Also expand .zip files (normally opaque)\n"
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
    bool solid_mode = false;    /* --solid: solid compression (old behavior) */
    bool no_sort = false;       /* --no-sort: disable MIME sorting in solid mode */
    uint8_t num_threads = 0;    /* 0 = auto */
    bool force = false;        /* -f/--force: overwrite without prompting */
    bool do_encrypt = false;
    uint8_t enc_id = 1;   /* default: AES-256-GCM */
    uint8_t kdf_id = 1;   /* default: Argon2id */
    bool no_expand = false;     /* --no-expand-containers */
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

    /* Check for existing output file — prompt before overwriting */
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

    /* Check if output directory already has files — warn unless --force */
    if (!force && output_dir) {
        struct stat out_st;
        if (stat(output_dir, &out_st) == 0 && S_ISDIR(out_st.st_mode)) {
            /* Directory exists — check if non-empty */
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

    /* Container tracking: indices of container DIRs */
    uint64_t *container_indices = NULL;
    size_t container_count = 0;
    size_t container_cap = 0;

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
            free(container_indices);
            free(buf);
            return EXIT_IO;
        }

        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)path_len, path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                fprintf(stderr, "blar: extract: path too long\n");
                free(container_indices);
                free(buf);
                return EXIT_IO;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                fprintf(stderr, "blar: extract: path too long\n");
                free(container_indices);
                free(buf);
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
                        free(buf);
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
                for (size_t ci = 0; ci < container_count; ci++) {
                    const char *co_path = NULL;
                    size_t co_path_len = 0;
                    if (blip_archive_file_path(buf, buf_len, container_indices[ci],
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
                    fprintf(stderr, "blar: extract: cannot create directory '%s': %s\n",
                            out_path, strerror(errno));
                    free(container_indices);
                    free(buf);
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
                    fprintf(stderr, "blar: extract: cannot create parent dir for container '%s': %s\n",
                            out_path, strerror(errno));
                    free(container_indices);
                    free(buf);
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

    /* Progress: determinate extraction phase */
    progrez_ctx *progress = progrez_create("Extracting");
    if (progress) {
        progrez_set_identity(progress, "blar", "archive extraction");
        progrez_set_sparkline(progress, true);
        progrez_set_determinate(progress, file_entries, total_bytes);
    }

    uint64_t files_done = 0;
    uint64_t failed = 0;

    /* Second pass: extract files (resilient — continue on per-file errors) */
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
            for (size_t ci = 0; ci < container_count; ci++) {
                const char *co_path = NULL;
                size_t co_path_len = 0;
                if (blip_archive_file_path(buf, buf_len, container_indices[ci],
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
            fprintf(stderr, "\033[31mERROR: entry %llu: cannot read path: %s\033[0m\n",
                    (unsigned long long)i, blip_error_string(rc));
            failed++;
            continue;
        }

        uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, buf_len, i, &data, &data_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "\033[31mERROR: skipping '%.*s': %s\033[0m\n",
                    (int)path_len, path, blip_error_string(rc));
            failed++;
            continue;
        }

        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)path_len, path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                fprintf(stderr, "\033[31mERROR: skipping '%.*s': path too long\033[0m\n",
                        (int)path_len, path);
                blip_free_content(data, data_len);
                failed++;
                continue;
            }
        } else {
            if (path_len >= sizeof(out_path)) {
                fprintf(stderr, "\033[31mERROR: skipping '%.*s': path too long\033[0m\n",
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
            fprintf(stderr, "\033[31mERROR: skipping '%.*s': cannot create directory: %s\033[0m\n",
                    (int)path_len, path, strerror(errno));
            blip_free_content(data, data_len);
            failed++;
            continue;
        }

        if (!write_file(out_path, data, data_len)) {
            fprintf(stderr, "\033[31mERROR: skipping '%.*s': cannot write: %s\033[0m\n",
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
        if (progress) progrez_update(progress, files_done, bytes_done);
    }

    /* Third pass: re-assemble container DIRs */
    for (size_t ci = 0; ci < container_count; ci++) {
        uint64_t co_idx = container_indices[ci];
        const char *co_path = NULL;
        size_t co_path_len = 0;
        rc = blip_archive_file_path(buf, buf_len, co_idx, &co_path, &co_path_len);
        if (rc != BLIP_OK) {
            fprintf(stderr, "\033[31mERROR: container %llu: cannot read path: %s\033[0m\n",
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
            ? blar_codec_find_by_name(&builtin_registry, co_type, co_type_len)
            : NULL;
        if (co_type && !codec) {
            fprintf(stderr, "warning: codec \"%.*s\" not found for container '%.*s', skipping reconstruction\n",
                    (int)co_type_len, co_type, (int)co_path_len, co_path);
            failed++;
            continue;
        }

        /* PDF container re-assembly */
        if (codec && strcmp(codec->name, "pdf") == 0) {
            /* Find __body__ child → read shell */
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
                fprintf(stderr, "\033[31mERROR: PDF container '%.*s': no __body__ found\033[0m\n",
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
                    fprintf(stderr, "\033[31mERROR: PDF container '%.*s': image '%.*s' missing po/pl metadata\033[0m\n",
                            (int)co_path_len, co_path, (int)inner_len, inner);
                    pdf_ok = false;
                    break;
                }

                /* Read JXL content */
                uint8_t *jxl_data = NULL;
                size_t jxl_len = 0;
                rc = blip_archive_file_content(buf, buf_len, j, &jxl_data, &jxl_len);
                if (rc != BLIP_OK) {
                    fprintf(stderr, "\033[31mERROR: PDF container '%.*s': cannot read '%.*s': %s\033[0m\n",
                            (int)co_path_len, co_path, (int)inner_len, inner, blip_error_string(rc));
                    pdf_ok = false;
                    break;
                }

                if (is_flate) {
                    /* FlateDecode: JXL → pixels → refilter → zlib compress */
                    uint8_t *pixels = NULL;
                    size_t pixels_len = 0;
                    uint32_t px_w = 0, px_h = 0, px_ch = 0, px_bps = 0;
                    rc = blip_jxl_to_pixels(jxl_data, jxl_len, &pixels, &pixels_len,
                                            &px_w, &px_h, &px_ch, &px_bps);
                    blip_free_content(jxl_data, jxl_len);
                    if (rc != BLIP_OK) {
                        fprintf(stderr, "\033[31mERROR: PDF container '%.*s': JXL pixel decode failed for '%.*s'\033[0m\n",
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
                        fprintf(stderr, "\033[31mERROR: PDF container '%.*s': refilter failed for '%.*s'\033[0m\n",
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
                        fprintf(stderr, "\033[31mERROR: PDF container '%.*s': zlib compress failed for '%.*s'\033[0m\n",
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
                    /* JPEG: JXL → JPEG (bit-exact, same size) */
                    uint8_t *jpeg_data = NULL;
                    size_t jpeg_len = 0;
                    rc = blip_jxl_to_jpeg(jxl_data, jxl_len, &jpeg_data, &jpeg_len);
                    blip_free_content(jxl_data, jxl_len);
                    if (rc != BLIP_OK) {
                        fprintf(stderr, "\033[31mERROR: PDF container '%.*s': JXL decode failed for '%.*s'\033[0m\n",
                                (int)co_path_len, co_path, (int)inner_len, inner);
                        pdf_ok = false;
                        break;
                    }

                    if (jpeg_len != pl) {
                        fprintf(stderr, "\033[31mERROR: PDF container '%.*s': JPEG length mismatch for '%.*s': "
                                "expected %llu, got %zu\033[0m\n",
                                (int)co_path_len, co_path, (int)inner_len, inner,
                                (unsigned long long)pl, jpeg_len);
                        blip_free(jpeg_data, jpeg_len);
                        pdf_ok = false;
                        break;
                    }

                    if (po + pl > shell_len) {
                        fprintf(stderr, "\033[31mERROR: PDF container '%.*s': offset+length exceeds shell for '%.*s'\033[0m\n",
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
                    /* Replace pdf_buf with rewritten version.
                     * rewritePdfWithStreams returns Zig-allocated memory;
                     * copy to malloc'd buffer so free() works later. */
                    free(pdf_buf);
                    pdf_buf = malloc(rewritten_len);
                    if (pdf_buf) {
                        memcpy(pdf_buf, rewritten, rewritten_len);
                    } else {
                        /* OOM fallback: use Zig buffer directly (will crash on free) */
                        pdf_buf = rewritten;
                        rewritten = NULL;
                    }
                    shell_len = rewritten_len;
                    if (rewritten) blip_free(rewritten, rewritten_len);
                } else if (rc == BLIP_ERR_XREF_STREAM) {
                    /* Xref stream PDF — can't rewrite, leave FlateDecode zeroed */
                    fprintf(stderr, "WARNING: PDF '%.*s': xref stream PDF, "
                            "FlateDecode images left as zeroed regions\n",
                            (int)co_path_len, co_path);
                } else {
                    fprintf(stderr, "WARNING: PDF '%.*s': rewrite failed (rc=%d), "
                            "FlateDecode images may be missing\n",
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

            /* ── Recompress content streams ──
             * During ingestion, FlateDecode non-image streams were decompressed
             * for better LZMA2 compression. Now we need to recompress them.
             * The dict still says /Filter /FlateDecode but stream data is raw.
             * Find these streams (they won't have a valid zlib header) and compress. */
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
                        for (uint64_t ci = 0; ci < cs_count; ci++) {
                            const uint8_t *sdata = pdf_buf + cs_offs[ci];
                            size_t slen = (size_t)cs_lens[ci];
                            /* Skip if already zlib-compressed (valid header) */
                            if (slen >= 2 && (sdata[0] & 0x0F) == 0x08 &&
                                ((uint16_t)sdata[0] * 256 + sdata[1]) % 31 == 0)
                                continue;
                            /* Compress raw data back to zlib */
                            uint8_t *compressed = NULL;
                            size_t compressed_len = 0;
                            if (blip_zlib_compress(sdata, slen,
                                    &compressed, &compressed_len) == BLIP_OK)
                            {
                                cs_starts[cs_rep_n] = cs_offs[ci];
                                cs_orig[cs_rep_n] = cs_lens[ci];
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
                            for (size_t ci = 0; ci < cs_rep_n; ci++)
                                blip_free(cs_datas[ci], cs_sizes[ci]);
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
                fprintf(stderr, "\033[31mERROR: PDF container '%.*s': cannot create parent dir: %s\033[0m\n",
                        (int)co_path_len, co_path, strerror(errno));
                free(pdf_buf);
                failed++;
                continue;
            }

            if (!write_file(out_path, pdf_buf, shell_len)) {
                fprintf(stderr, "\033[31mERROR: PDF container '%.*s': cannot write: %s\033[0m\n",
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
            if (progress) progrez_update(progress, files_done, bytes_done);
            continue;
        }

        /* PNG container re-assembly */
        if (codec && strcmp(codec->name, "jpeg") == 0) {
            /* JPEG container: find __body__.jxl, transcode JXL → JPEG */
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
                fprintf(stderr, "\033[31mERROR: JPEG container '%.*s': missing __body__.jxl\033[0m\n",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            /* Transcode JXL → JPEG (bit-exact) */
            uint8_t *jpeg_data = NULL;
            size_t jpeg_len = 0;
            rc = blip_jxl_to_jpeg(jxl_data, jxl_data_len, &jpeg_data, &jpeg_len);
            blip_free_content(jxl_data, jxl_data_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "\033[31mERROR: JPEG container '%.*s': JXL → JPEG decode failed\033[0m\n",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            /* Write reconstructed JPEG */
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
                fprintf(stderr, "\033[31mERROR: JPEG container '%.*s': cannot create parent dir: %s\033[0m\n",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(jpeg_data, jpeg_len);
                failed++;
                continue;
            }

            if (!write_file(out_path, jpeg_data, jpeg_len)) {
                fprintf(stderr, "\033[31mERROR: JPEG container '%.*s': cannot write: %s\033[0m\n",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(jpeg_data, jpeg_len);
                failed++;
                continue;
            }
            blip_free(jpeg_data, jpeg_len);

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
                times[1].tv_sec = co_mtime_ns / 1000000000LL;
                times[1].tv_nsec = co_mtime_ns % 1000000000LL;
                utimensat(AT_FDCWD, out_path, times, 0);
            }

            /* Restore xattrs */
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
            if (progress) progrez_update(progress, files_done, bytes_done);
            continue;
        }

        if (codec && strcmp(codec->name, "png") == 0) {
            /* Find __meta__ and __pixels__.jxl children */
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
                fprintf(stderr, "\033[31mERROR: PNG container '%.*s': missing %s%s%s\033[0m\n",
                        (int)co_path_len, co_path,
                        found_meta ? "" : "__meta__",
                        (!found_meta && !found_pixels) ? " and " : "",
                        found_pixels ? "" : "__pixels__.jxl");
                if (meta_data) blip_free_content(meta_data, meta_data_len);
                if (jxl_data) blip_free_content(jxl_data, jxl_data_len);
                failed++;
                continue;
            }

            /* Decode JXL → raw pixels */
            uint8_t *pixels = NULL;
            size_t pixels_len = 0;
            uint32_t width = 0, height = 0, num_channels = 0, bits_per_sample = 0;
            rc = blip_jxl_to_pixels(jxl_data, jxl_data_len,
                    &pixels, &pixels_len, &width, &height,
                    &num_channels, &bits_per_sample);
            blip_free_content(jxl_data, jxl_data_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "\033[31mERROR: PNG container '%.*s': JXL decode failed\033[0m\n",
                        (int)co_path_len, co_path);
                blip_free_content(meta_data, meta_data_len);
                failed++;
                continue;
            }

            /* Re-encode pixels + metadata → PNG */
            uint8_t *png_data = NULL;
            size_t png_len = 0;
            rc = blip_png_encode(pixels, pixels_len,
                    width, height, num_channels, bits_per_sample,
                    meta_data, meta_data_len,
                    &png_data, &png_len);
            blip_free(pixels, pixels_len);
            blip_free_content(meta_data, meta_data_len);
            if (rc != BLIP_OK) {
                fprintf(stderr, "\033[31mERROR: PNG container '%.*s': PNG encode failed\033[0m\n",
                        (int)co_path_len, co_path);
                failed++;
                continue;
            }

            /* Write the reconstructed PNG */
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
                fprintf(stderr, "\033[31mERROR: PNG container '%.*s': cannot create parent dir: %s\033[0m\n",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(png_data, png_len);
                failed++;
                continue;
            }

            if (!write_file(out_path, png_data, png_len)) {
                fprintf(stderr, "\033[31mERROR: PNG container '%.*s': cannot write: %s\033[0m\n",
                        (int)co_path_len, co_path, strerror(errno));
                blip_free(png_data, png_len);
                failed++;
                continue;
            }
            blip_free(png_data, png_len);

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
                times[1].tv_sec = co_mtime_ns / 1000000000LL;
                times[1].tv_nsec = co_mtime_ns % 1000000000LL;
                utimensat(AT_FDCWD, out_path, times, 0);
            }

            /* Restore xattrs */
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
            if (progress) progrez_update(progress, files_done, bytes_done);
            continue;
        }

        /* ZIP container re-assembly — collect child entries */
        size_t child_cap = 32;
        size_t child_count = 0;
        blip_zip_write_entry *zip_entries = malloc(child_cap * sizeof(blip_zip_write_entry));
        size_t buf_cap = child_cap * 2; /* files add 2 bufs each (data + name) */
        uint8_t **child_bufs = malloc(buf_cap * sizeof(uint8_t *)); /* buffers to free */
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

            /* Check if this entry is a direct child of the container */
            if (j_path_len <= co_path_len + 1 ||
                memcmp(j_path, co_path, co_path_len) != 0 ||
                j_path[co_path_len] != '/') {
                continue;
            }

            /* Strip container prefix to get inner path */
            const char *inner_path = j_path + co_path_len + 1;
            size_t inner_path_len = j_path_len - co_path_len - 1;

            uint8_t j_type = 0;
            blip_archive_entry_type(buf, buf_len, j, &j_type);

            /* Get mtime for MS-DOS timestamps */
            uint16_t j_mode = 0;
            int64_t j_mtime_ns = 0;
            const char *j_owner = NULL;
            size_t j_owner_len = 0;
            blip_archive_entry_metadata(buf, buf_len, j, &j_mode, &j_mtime_ns, &j_owner, &j_owner_len);
            uint16_t dos_time = 0, dos_date = 0;
            ns_to_msdos(j_mtime_ns, &dos_time, &dos_date);

            /* Grow arrays if needed (child_bufs grows ~2x faster: files add 2 bufs each) */
            if (child_count >= child_cap || child_buf_count + 2 >= buf_cap) {
                child_cap *= 2;
                buf_cap = child_cap * 2;
                blip_zip_write_entry *new_ze = realloc(zip_entries, child_cap * sizeof(blip_zip_write_entry));
                uint8_t **new_cb = realloc(child_bufs, buf_cap * sizeof(uint8_t *));
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
                /* Nested DIR inside container → zip directory entry */
                /* Add trailing slash for zip directory convention */
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
                ze.compression_method = 0; /* store for dirs */
                ze.mtime = dos_time;
                ze.mdate = dos_date;
                ze.external_attributes = 0x10 << 16; /* MS-DOS directory attribute */
                zip_entries[child_count++] = ze;
            } else {
                /* FILE inside container → zip file entry */
                uint8_t *data = NULL;
                size_t data_len = 0;
                rc = blip_archive_file_content(buf, buf_len, j, &data, &data_len);
                if (rc != BLIP_OK) {
                    fprintf(stderr, "\033[31mERROR: container child '%.*s': %s\033[0m\n",
                            (int)j_path_len, j_path, blip_error_string(rc));
                    container_ok = false;
                    break;
                }

                /* Copy to malloc'd buffer */
                uint8_t *owned = malloc(data_len > 0 ? data_len : 1);
                if (!owned) {
                    blip_free_content(data, data_len);
                    container_ok = false;
                    break;
                }
                if (data_len > 0) memcpy(owned, data, data_len);
                blip_free_content(data, data_len);
                child_bufs[child_buf_count++] = owned;

                /* Duplicate inner_path for the entry */
                char *fname = strndup(inner_path, inner_path_len);
                if (!fname) { container_ok = false; break; }
                child_bufs[child_buf_count++] = (uint8_t *)fname;

                /* Get original zip compression method if stored */
                uint16_t zc_method = 0; /* default: store */
                blip_archive_entry_zip_comp(buf, buf_len, j, &zc_method);
                if (zc_method == 0xFFFF) zc_method = 8; /* default to deflate */

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

        /* Create the zip */
        uint8_t *zip_buf = NULL;
        size_t zip_len = 0;
        rc = blip_zip_create(zip_entries, child_count, &zip_buf, &zip_len);

        /* Free child buffers */
        for (size_t k = 0; k < child_buf_count; k++) free(child_bufs[k]);
        free(child_bufs);
        free(zip_entries);

        if (rc != BLIP_OK) {
            fprintf(stderr, "\033[31mERROR: container '%.*s': zip creation failed: %s\033[0m\n",
                    (int)co_path_len, co_path, blip_error_string(rc));
            failed++;
            continue;
        }

        /* Write the zip file */
        char out_path[4096];
        if (output_dir) {
            int n = snprintf(out_path, sizeof(out_path), "%s/%.*s",
                             output_dir, (int)co_path_len, co_path);
            if (n < 0 || (size_t)n >= sizeof(out_path)) {
                fprintf(stderr, "\033[31mERROR: container '%.*s': path too long\033[0m\n",
                        (int)co_path_len, co_path);
                blip_free(zip_buf, zip_len);
                failed++;
                continue;
            }
        } else {
            if (co_path_len >= sizeof(out_path)) {
                blip_free(zip_buf, zip_len);
                failed++;
                continue;
            }
            memcpy(out_path, co_path, co_path_len);
            out_path[co_path_len] = '\0';
        }

        if (!ensure_parent_dir(out_path)) {
            fprintf(stderr, "\033[31mERROR: container '%.*s': cannot create parent dir: %s\033[0m\n",
                    (int)co_path_len, co_path, strerror(errno));
            blip_free(zip_buf, zip_len);
            failed++;
            continue;
        }

        /* Copy to malloc'd buffer for write_file */
        uint8_t *write_buf = malloc(zip_len);
        if (write_buf) {
            memcpy(write_buf, zip_buf, zip_len);
        }
        blip_free(zip_buf, zip_len);
        if (!write_buf) { failed++; continue; }

        if (!write_file(out_path, write_buf, zip_len)) {
            fprintf(stderr, "\033[31mERROR: container '%.*s': cannot write: %s\033[0m\n",
                    (int)co_path_len, co_path, strerror(errno));
            free(write_buf);
            failed++;
            continue;
        }
        free(write_buf);

        /* Restore container DIR metadata (mode, mtime, xattrs) on the resulting file */
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

        /* Restore xattrs on container file */
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
        if (progress) progrez_update(progress, files_done, bytes_done);
    }

    free(container_indices);

    if (progress) { progrez_finish(progress); progrez_destroy(progress); }
    free(buf);

    if (failed > 0) {
        fprintf(stderr, "\n%llu extracted, %llu failed\n",
                (unsigned long long)files_done, (unsigned long long)failed);
        return EXIT_IO;
    }
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
            /* DIR entry — show with trailing / */
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
            /* blank line — skip */
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
        /* path is like "dir/sub/file.txt" — basename is "file.txt", parent is output_dir/dir/sub */
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
