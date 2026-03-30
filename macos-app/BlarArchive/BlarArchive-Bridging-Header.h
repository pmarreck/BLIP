#ifndef BlarArchive_Bridging_Header_h
#define BlarArchive_Bridging_Header_h

#include "../../src/blip.h"

/* Extraction API — subset of blar_common.h needed by the GUI app.
 * We don't include blar_common.h directly because it pulls in progrez.h
 * and other CLI dependencies. Instead, declare just what we need. */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* Codec type (name-only, for extraction dispatch) */
typedef struct {
    const char *name;
    const char *const *extensions;
    void *detect;   /* not used by extraction */
    void *expand;   /* not used by extraction */
    void *collapse; /* not used by extraction */
} blar_codec_t;

typedef struct {
    const blar_codec_t *codecs;
    size_t count;
} blar_codec_registry_t;

/* Extraction callbacks */
typedef void (*blar_extract_progress_fn)(uint64_t files_done, uint64_t bytes_done,
                                          uint64_t total_files, uint64_t total_bytes,
                                          void *ctx);
typedef void (*blar_extract_log_fn)(const char *msg, void *ctx);

/* We can't call the static function from blar_common.h directly.
 * The app will link against a thin C wrapper (blar_extract_wrapper.c)
 * that calls blar_extract_to_dir from blar_common.h. */
int blar_gui_extract(const uint8_t *buf, size_t buf_len,
                      const char *output_dir,
                      const blar_codec_t *codecs, size_t codec_count,
                      blar_extract_progress_fn progress_fn,
                      blar_extract_log_fn log_fn,
                      void *callback_ctx);

#endif
