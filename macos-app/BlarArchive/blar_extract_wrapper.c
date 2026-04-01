/* GUI wrapper — exposes blar_common.h functions to Swift.
 *
 * All archive creation (with container expansion) and extraction logic
 * lives in blar_common.h. This file just provides extern-linkage entry
 * points that Swift can call through the bridging header.
 *
 * progrez.h is stubbed by a local progrez.h in this directory — the GUI
 * uses NSProgressIndicator instead of terminal progress bars. */

#include "../../src/blip.h"
#include "../../src/blar_common.h"

/* ── Archive creation ─────────────────────────────────────────────────── */

/* Progress adapter: wraps 5-arg GUI callback for 3-arg FFI callback */
typedef struct {
    blar_extract_progress_fn fn;
    void *ctx;
    size_t total_files;
    uint64_t total_bytes;
} gui_create_progress_ctx_t;

static void gui_create_progress_adapter(uint64_t entries_done, uint64_t bytes_done, void *ctx) {
    gui_create_progress_ctx_t *g = (gui_create_progress_ctx_t *)ctx;
    fprintf(stderr, "[progress] entries=%llu/%zu bytes=%llu/%llu\n",
            (unsigned long long)entries_done, g->total_files,
            (unsigned long long)bytes_done, (unsigned long long)g->total_bytes);
    if (g->fn) g->fn(entries_done, bytes_done, (uint64_t)g->total_files, g->total_bytes, g->ctx);
}

/* Expansion phase progress: (done_files, total_files, ctx) → 5-arg GUI callback */
static void gui_expansion_progress_adapter(uint64_t done, uint64_t total, void *ctx) {
    gui_create_progress_ctx_t *g = (gui_create_progress_ctx_t *)ctx;
    /* Report as file counts; set bytes to 0 so Swift uses file-based fraction */
    if (g->fn) g->fn(done, 0, total, 0, g->ctx);
}

int blar_gui_create(const char *const *paths, size_t path_count,
                     uint8_t per_file_comp, uint8_t num_threads,
                     bool expand_containers, bool expand_all_zips,
                     bool use_streaming,
                     blar_extract_progress_fn progress_fn,
                     void *progress_ctx,
                     uint8_t **out_buf, size_t *out_len) {
    fprintf(stderr, "[blar_gui_create] paths=%zu, per_file_comp=%u, expand=%d, threads=%u, progress_fn=%p\n",
            path_count, per_file_comp, expand_containers, num_threads, (void*)progress_fn);
    for (size_t i = 0; i < path_count; i++)
        fprintf(stderr, "  path[%zu]: %s\n", i, paths[i]);

    entry_list_t el;
    entry_list_init(&el);
    el.expand_containers = expand_containers;
    el.expand_all_zips = expand_all_zips;
    el.num_threads = num_threads;

    /* Wire expansion progress through to GUI callback.
     * During expansion, done/total are file counts. */
    gui_create_progress_ctx_t expansion_adapter = {
        .fn = progress_fn,
        .ctx = progress_ctx,
        .total_files = 0,
        .total_bytes = 0,
    };
    if (progress_fn) {
        el.expansion_progress_fn = gui_expansion_progress_adapter;
        el.expansion_progress_ctx = &expansion_adapter;
    }

    for (size_t i = 0; i < path_count; i++) {
        if (!collect_entries_recurse(paths[i], &el)) {
            entry_list_free(&el);
            return -1;
        }
    }

    if (el.count == 0) {
        entry_list_free(&el);
        return -1;
    }

    /* Auto-detect streaming mode based on total content size */
    bool do_streaming = use_streaming;
    if (!do_streaming) {
        uint64_t est_total = 0;
        for (size_t i = 0; i < el.count; i++) {
            if (!el.entries[i].is_dir)
                est_total += el.entries[i].content_len;
        }
        if (est_total > (uint64_t)1024 * 1024 * 1024) {
            fprintf(stderr, "[blar_gui_create] auto-selecting streaming mode (%.1f GB input)\n",
                    (double)est_total / (1024.0 * 1024.0 * 1024.0));
            do_streaming = true;
        }
    }

    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;
    int32_t rc;

    if (do_streaming) {
        /* Streaming path — re-collect with metadata_only */
        entry_list_free(&el);
        entry_list_init(&el);
        el.metadata_only = true;
        el.expand_containers = expand_containers;
        el.expand_all_zips = expand_all_zips;
        el.num_threads = num_threads;
        for (size_t i = 0; i < path_count; i++) {
            if (!collect_entries_recurse(paths[i], &el)) {
                entry_list_free(&el);
                return -1;
            }
        }
        rc = blip_archive_create_streaming(el.entries, el.count,
                                            per_file_comp,
                                            expand_containers, expand_all_zips,
                                            &archive_buf, &archive_len);
    } else {
        /* In-memory path */
        if (el.expand_containers) {
            if (!expand_containers_pass(&el)) {
                entry_list_free(&el);
                return -1;
            }
        }

        uint64_t total_bytes = 0;
        for (size_t i = 0; i < el.count; i++) {
            if (!el.entries[i].is_dir)
                total_bytes += el.entries[i].content_len;
        }

        gui_create_progress_ctx_t progress_adapter = {
            .fn = progress_fn,
            .ctx = progress_ctx,
            .total_files = el.count,
            .total_bytes = total_bytes,
        };
        rc = blip_archive_create_full(el.entries, el.count, 0,
                                       per_file_comp, num_threads,
                                       progress_fn ? gui_create_progress_adapter : NULL,
                                       NULL,
                                       progress_fn ? &progress_adapter : NULL,
                                       &archive_buf, &archive_len);
    }
    entry_list_free(&el);
    if (rc != 0) return rc;

    *out_buf = archive_buf;
    *out_len = archive_len;
    return 0;
}

/* ── Archive extraction ───────────────────────────────────────────────── */

int blar_gui_extract(const uint8_t *buf, size_t buf_len,
                      const char *output_dir,
                      const blar_codec_t *codecs, size_t codec_count,
                      blar_extract_progress_fn progress_fn,
                      blar_extract_log_fn log_fn,
                      void *callback_ctx) {
    blar_codec_registry_t registry = {
        .codecs = codecs,
        .count = codec_count,
    };
    return blar_extract_to_dir(buf, buf_len, output_dir, &registry,
                                progress_fn, log_fn, callback_ctx);
}

/* ── Xattr helpers ────────────────────────────────────────────────────── */

void blar_gui_read_xattrs(const char *path,
                           blip_xattr_entry **out_xattrs, size_t *out_count,
                           uint8_t **out_resource_fork, size_t *out_resource_fork_len) {
    read_file_xattrs(path, out_xattrs, out_count, out_resource_fork, out_resource_fork_len);
}

void blar_gui_free_xattrs(blip_xattr_entry *xattrs, size_t count,
                            uint8_t *resource_fork) {
    free_file_xattrs(xattrs, count, resource_fork);
}
