#ifndef BLIP_H
#define BLIP_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/* Error codes returned by BLIP FFI functions.
 * Most functions return 0 on success and a negative code on error.
 * Use blip_error_string() to get a human-readable description. */
#define BLIP_OK                       0
#define BLIP_ERR_INVALID_TYPE        -1
#define BLIP_ERR_INVALID_LENGTH      -2
#define BLIP_ERR_BOUNDS              -3
#define BLIP_ERR_MISSING_KEY         -4
#define BLIP_ERR_DUPLICATE_KEY       -5
#define BLIP_ERR_KEYS_NOT_SORTED     -6
#define BLIP_ERR_HASH_MISMATCH       -7
#define BLIP_ERR_INDEX_OOB           -8
#define BLIP_ERR_INVALID_MAGIC       -9
#define BLIP_ERR_BUFFER_TOO_SMALL   -10
#define BLIP_ERR_UNEXPECTED_EOF     -11
#define BLIP_ERR_OVERFLOW           -12
#define BLIP_ERR_ALLOC              -13
#define BLIP_ERR_NOT_FOUND          -14
#define BLIP_ERR_INVALID_PATH       -15
#define BLIP_ERR_NULL_HANDLE        -16
#define BLIP_ERR_MISSING_SIGIL      -25
#define BLIP_ERR_INVALID_SIGIL_ORD  -26
#define BLIP_ERR_MISSING_DECOMP_LEN -27
#define BLIP_ERR_INVALID_SEGMENT    -50
#define BLIP_ERR_MISSING_SEGMENTS   -51
#define BLIP_ERR_INCONSISTENT_TOTAL -52
#define BLIP_ERR_SEGMENT_GAP        -53
#define BLIP_ERR_SEGMENT_DUP        -54
#define BLIP_ERR_UNKNOWN            -99

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Varint encode / decode (the core BLIP spec)
 * ------------------------------------------------------------------------- */

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

/* ---------------------------------------------------------------------------
 * Error / memory utilities
 * ------------------------------------------------------------------------- */

/* Return a static, NUL-terminated description for a BLIP error code. */
const char *blip_error_string(int32_t error_code);

/* Free a buffer that BLIP allocated for the caller (page-allocator-backed). */
void blip_free(uint8_t *ptr, size_t len);

/* ---------------------------------------------------------------------------
 * Generic LP-envelope navigation (peek)
 * ------------------------------------------------------------------------- */

/* Navigate to a container within a BLIP buffer using a path expression.
 * Path syntax: [N] for array index, [key] for dict key.
 * Returns 0 on success.  *out_type receives the container type ID;
 * *out_data / *out_data_len receive a zero-copy view into `buf`. */
int32_t blip_peek(const uint8_t *buf, size_t buf_len,
                  const char *path, size_t path_len,
                  uint8_t *out_type,
                  const uint8_t **out_data, size_t *out_data_len);

/* Get element/pair count for an array-like or dict-like container. */
int32_t blip_container_count(const uint8_t *buf, size_t len, uint64_t *out_count);

/* Get the trailing xxHash64 from a container. */
int32_t blip_container_hash(const uint8_t *buf, size_t len, uint8_t out_hash[8]);

/* Get the key payload bytes at the given pair index from a dict-like container. */
int32_t blip_container_key_at(const uint8_t *buf, size_t len, uint64_t index,
                              const uint8_t **out_key, size_t *out_key_len);

/* ---- DictIndex: opt-in fast DICT access (opaque handle) ---- */
/* Build over a DICT/MAP/DIR container. Caller MUST keep `buf` alive until
   blip_dict_index_free. *out_handle receives an opaque handle on success.
   *out_handle is set to NULL on error. */
int32_t blip_dict_index_build(const uint8_t *buf, size_t len, void **out_handle);
int32_t blip_dict_index_count(const void *handle, uint64_t *out_count);
/* out_found = 1 if found (out_index set), else 0 (out_index set to 0). Return 0=ok, negative=error. */
int32_t blip_dict_index_find(const void *handle, const uint8_t *key, size_t key_len,
                             uint8_t *out_found, uint64_t *out_index);
/* out_ptr aliases the caller's buf (no copy); valid while handle and buf live. */
int32_t blip_dict_index_key_at(const void *handle, uint64_t index,
                               const uint8_t **out_ptr, size_t *out_len);
int32_t blip_dict_index_value_at(const void *handle, uint64_t index,
                                 const uint8_t **out_ptr, size_t *out_len);
void blip_dict_index_free(void *handle);

/* Full peek display: navigate + format output in Zig core.
 * Returns 0 on success, negative error code on failure.
 * Caller must free *out_stdout and *out_stderr buffers with blip_free(). */
int32_t blip_peek_display(const uint8_t *buf, size_t buf_len,
                          const char *path, size_t path_len,
                          uint32_t flags,
                          const uint8_t **out_stdout, size_t *out_stdout_len,
                          const uint8_t **out_stderr, size_t *out_stderr_len);

/* ---------------------------------------------------------------------------
 * Printable-binary encode/decode
 * ------------------------------------------------------------------------- */

/* Decode a printable-binary UTF-8 buffer back to raw bytes.
 * Caller must free *out_buf with blip_free(). */
int32_t blip_decode_printable_binary(const uint8_t *encoded, size_t encoded_len,
                                     uint8_t **out_buf, size_t *out_len);

/* Encode binary data as printable-binary UTF-8.
 * Caller must free *out_buf with blip_free(). */
int32_t blip_encode_printable_binary(const uint8_t *input, size_t input_len,
                                     uint8_t **out_buf, size_t *out_len);

/* ---------------------------------------------------------------------------
 * SEGMENT (Layer 5 transport-fragmentation primitive)
 * ------------------------------------------------------------------------- */

typedef struct blip_segment {
    const uint8_t *data;
    size_t len;
} blip_segment_t;

/* Chunk an arbitrary byte buffer into SEGMENT containers of at most
 * `max_payload` bytes of VAL each.  csum_id: 0 = no per-segment checksum,
 * otherwise a ChecksumId u8. Returns 0 on success.
 * Caller must free *out_segments with blip_segment_array_free. */
int32_t blip_segment_chunk(const uint8_t *data, size_t data_len,
                           size_t max_payload, uint64_t stream_id, uint8_t csum_id,
                           blip_segment_t **out_segments, size_t *out_count);

/* Free an array returned by blip_segment_chunk, including each segment's data. */
void blip_segment_array_free(blip_segment_t *segments, size_t count);

/* Reassemble a list of SEGMENT-container byte slices into the original payload.
 * Caller must free *out_buf with blip_free. */
int32_t blip_segment_reassemble(const blip_segment_t *segments, size_t count,
                                uint64_t expected_stream_id,
                                uint8_t **out_buf, size_t *out_len);

/* Quick check: 0 = not a segment, 1 = is a segment, negative = parse error. */
int32_t blip_segment_is_segment(const uint8_t *data, size_t data_len);

/* Read just the (I, M, N) header from a SEGMENT container, without reassembly.
 * If N is NIL, *out_total is 0 and *out_total_is_nil is 1. */
int32_t blip_segment_header(const uint8_t *data, size_t data_len,
                            uint64_t *out_stream_id, uint64_t *out_seg_index,
                            uint64_t *out_total, uint8_t *out_total_is_nil);

/* ---------------------------------------------------------------------------
 * Hash helper
 * ------------------------------------------------------------------------- */

/* Compute xxHash64 of a byte buffer. Compatible with `xxhsum -H64`. */
uint64_t blip_xxhash64(const uint8_t *data, size_t data_len);

#ifdef __cplusplus
}
#endif

#endif /* BLIP_H */
