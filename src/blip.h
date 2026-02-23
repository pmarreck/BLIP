#ifndef BLIP_H
#define BLIP_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Encode a u64 value into BLIP format.
 * Returns bytes written, or -1 on error. */
int32_t blip_encode(uint64_t value, uint8_t *out_buf, size_t out_cap);

/* Decode a BLIP value from encoded bytes.
 * Returns bytes consumed, or -1 on error. Decoded value in *out_value. */
int32_t blip_decode(const uint8_t *encoded, size_t encoded_len, uint64_t *out_value);

/* Check if encoded bytes represent a sentinel (overlong encoding). */
bool blip_is_sentinel(const uint8_t *encoded, size_t encoded_len);

/* Get the encoded size for a value without encoding. Returns -1 on error. */
int32_t blip_encoded_size(uint64_t value);

/* Container/archive operations */

typedef struct {
    const char *path;
    size_t path_len;
    const uint8_t *content;
    size_t content_len;
} blip_file_entry;

/* Create a BLIP archive from file entries.
 * Returns 0 on success, -1 on error.
 * Caller must free the output buffer with blip_free(). */
int32_t blip_archive_create(const blip_file_entry *files, size_t file_count,
                            uint8_t **out_buf, size_t *out_len);

/* Get the number of files in a BLIP archive.
 * Returns 0 on success, -1 on error. File count stored in *out_count. */
int32_t blip_archive_file_count(const uint8_t *buf, size_t buf_len, uint64_t *out_count);

/* Verify a BLIP archive's xxHash64 integrity.
 * Returns true if the hash is valid, false otherwise. */
bool blip_archive_verify(const uint8_t *buf, size_t buf_len);

/* Free a buffer allocated by blip_archive_create. */
void blip_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* BLIP_H */
