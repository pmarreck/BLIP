/* Thin wrapper to expose blar_extract_to_dir() from blar_common.h
 * to the macOS GUI app. blar_common.h is a header-only library with
 * static functions — this compilation unit instantiates them and
 * provides an extern-linkage entry point for Swift.
 *
 * progrez.h is stubbed by a local progrez.h in this directory
 * (included via -I before the real one). The GUI app uses
 * NSProgressIndicator instead of terminal progress bars. */

#include "../../src/blip.h"
#include "../../src/blar_common.h"

/* Read xattrs and resource fork for a file — wraps blar_common.h static function */
void blar_gui_read_xattrs(const char *path,
                           blip_xattr_entry **out_xattrs, size_t *out_count,
                           uint8_t **out_resource_fork, size_t *out_resource_fork_len) {
    read_file_xattrs(path, out_xattrs, out_count, out_resource_fork, out_resource_fork_len);
}

/* Free xattr data */
void blar_gui_free_xattrs(blip_xattr_entry *xattrs, size_t count,
                            uint8_t *resource_fork) {
    free_file_xattrs(xattrs, count, resource_fork);
}

/* Extern-linkage wrapper callable from Swift */
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
