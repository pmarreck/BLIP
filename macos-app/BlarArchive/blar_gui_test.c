/* Minimal CLI to test blar_gui_create — same code path as the macOS GUI.
 * Usage: blar-gui-test <output.blar> <input_path> [input_path...]
 * Build: cc -o blar-gui-test blar_gui_test.c blar_extract_wrapper.c \
 *        -I../../src -L../../zig-out/lib -lblip -ljxl -ljxl_threads -lz \
 *        -lbrotlienc -lbrotlidec -lbrotlicommon -lhwy -lc++ */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

/* Forward declarations matching the bridging header */
typedef struct {
    const char *name;
    const char *const *extensions;
    void *detect;
    void *expand;
    void *collapse;
} blar_codec_t;

typedef struct {
    const blar_codec_t *codecs;
    size_t count;
} blar_codec_registry_t;

typedef void (*blar_extract_progress_fn)(uint64_t, uint64_t, uint64_t, uint64_t, void *);
typedef void (*blar_extract_log_fn)(const char *, void *);

extern int blar_gui_create(const char *const *paths, size_t path_count,
                            uint8_t per_file_comp, uint8_t num_threads,
                            bool expand_containers, bool expand_all_zips,
                            blar_extract_progress_fn progress_fn,
                            void *progress_ctx,
                            uint8_t **out_buf, size_t *out_len);

/* From blip.h */
extern void blip_free(uint8_t *ptr, size_t len);

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: blar-gui-test <output.blar> <input>...\n");
        fprintf(stderr, "Tests blar_gui_create (same code path as macOS GUI)\n");
        return 1;
    }

    const char *output = argv[1];
    const char **inputs = (const char **)&argv[2];
    int input_count = argc - 2;

    printf("Creating archive via blar_gui_create...\n");
    printf("  Inputs: %d path(s)\n", input_count);
    for (int i = 0; i < input_count; i++) {
        printf("    [%d] %s\n", i, inputs[i]);
    }
    printf("  Container expansion: ON\n");
    printf("  Compression: LZMA2 (per-file)\n");

    uint8_t *archive_buf = NULL;
    size_t archive_len = 0;

    int rc = blar_gui_create(inputs, (size_t)input_count,
                              1, /* per_file_comp = LZMA2 */
                              0, /* num_threads = auto */
                              true, /* expand_containers */
                              false, /* expand_all_zips */
                              NULL, NULL, /* no progress */
                              &archive_buf, &archive_len);

    if (rc != 0) {
        fprintf(stderr, "blar_gui_create failed with code %d\n", rc);
        return 1;
    }

    printf("  Archive size: %zu bytes (%.1f MB)\n", archive_len, (double)archive_len / 1024 / 1024);

    /* Write to file */
    FILE *f = fopen(output, "wb");
    if (!f) {
        fprintf(stderr, "Cannot open '%s' for writing\n", output);
        blip_free(archive_buf, archive_len);
        return 1;
    }
    fwrite(archive_buf, 1, archive_len, f);
    fclose(f);
    blip_free(archive_buf, archive_len);

    printf("  Written to: %s\n", output);

    /* Verify by listing containers */
    printf("\nVerifying with blar list...\n");
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "zig-out/bin/blar list '%s' | head -20", output);
    system(cmd);

    printf("\nContainer counts:\n");
    snprintf(cmd, sizeof(cmd), "zig-out/bin/blar list '%s' | cut -c1 | sort | uniq -c | sort -rn", output);
    system(cmd);

    return 0;
}
