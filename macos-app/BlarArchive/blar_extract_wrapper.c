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
