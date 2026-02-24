#ifndef BLIP_H
#define BLIP_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/* Error codes for new archive access functions.
 * Legacy functions (blip_encode, blip_decode, etc.) still return -1 on error. */
#define BLIP_OK                    0
#define BLIP_ERR_INVALID_TYPE     -1
#define BLIP_ERR_INVALID_LENGTH   -2
#define BLIP_ERR_BOUNDS           -3
#define BLIP_ERR_MISSING_KEY      -4
#define BLIP_ERR_DUPLICATE_KEY    -5
#define BLIP_ERR_KEYS_NOT_SORTED  -6
#define BLIP_ERR_HASH_MISMATCH   -7
#define BLIP_ERR_INDEX_OOB        -8
#define BLIP_ERR_INVALID_MAGIC    -9
#define BLIP_ERR_BUFFER_TOO_SMALL -10
#define BLIP_ERR_UNEXPECTED_EOF   -11
#define BLIP_ERR_OVERFLOW         -12
#define BLIP_ERR_ALLOC            -13
#define BLIP_ERR_NOT_FOUND        -14
#define BLIP_ERR_UNKNOWN          -99

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

/* Get a human-readable error string for an error code. */
const char *blip_error_string(int32_t error_code);

/* Get file path from archive by index (zero-copy pointer into buf). */
int32_t blip_archive_file_path(const uint8_t *buf, size_t buf_len,
                                uint64_t index,
                                const char **out_path, size_t *out_path_len);

/* Get file content from archive by index (zero-copy pointer into buf). */
int32_t blip_archive_file_content(const uint8_t *buf, size_t buf_len,
                                   uint64_t index,
                                   const uint8_t **out_data, size_t *out_data_len);

/* Get file content by path (zero-copy pointer into buf). */
int32_t blip_archive_file_content_by_path(const uint8_t *buf, size_t buf_len,
                                           const char *path, size_t path_len,
                                           const uint8_t **out_data, size_t *out_data_len);

/* Verify a single file's xh64 hash within archive. */
int32_t blip_archive_file_verify(const uint8_t *buf, size_t buf_len,
                                  uint64_t index);

#ifdef __cplusplus
}
#endif

#endif /* BLIP_H */
