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
#define BLIP_ERR_INVALID_PATH     -15
#define BLIP_ERR_INVALID_JSON     -18
#define BLIP_ERR_MISSING_FIELD    -19
#define BLIP_ERR_INVALID_ENTRY    -20
#define BLIP_ERR_INVALID_TIMESTAMP -21
#define BLIP_ERR_INVALID_MODE     -22
#define BLIP_ERR_UNKNOWN          -99

/* Archive creation flags */
#define BLIP_ARCHIVE_ABSOLUTE_PATHS  0x0001u  /* preserve absolute paths (default: strip leading ./ and /) */

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
                            uint32_t flags,
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

/* Verify a single file's xh64 hash within archive.
 * For DIR entries, verifies the container hash only (no bina check). */
int32_t blip_archive_file_verify(const uint8_t *buf, size_t buf_len,
                                  uint64_t index);

/* --- Full archive (DIR + metadata) support --- */

typedef struct {
    const char *path;
    size_t path_len;
    const uint8_t *content;  /* NULL for directories */
    size_t content_len;      /* 0 for directories */
    uint8_t is_dir;          /* 1 for directory, 0 for file */
    uint16_t mode;           /* permission bits (LE uint16), 0 = not set */
    int64_t mtime_ns;        /* nanoseconds since epoch (LE int64), 0 = not set */
    int64_t ctime_ns;        /* inode change time (ns since epoch), 0 = not set */
    int64_t birthtime_ns;    /* creation time (ns since epoch), 0 = not set */
    uint32_t uid;            /* numeric user ID, 0 = not set */
    uint32_t gid;            /* numeric group ID, 0 = not set */
    const char *owner;       /* username, NULL = not set */
    size_t owner_len;        /* 0 = not set */
    const char *groupname;   /* group name, NULL = not set */
    size_t groupname_len;    /* 0 = not set */
    uint8_t xh64[8];         /* Merkle hash for dirs (pre-computed), ignored for files */
} blip_archive_entry;

/* Create a full BLIP archive with FILE + DIR entries and metadata.
 * Returns 0 on success, negative error code on failure.
 * Caller must free the output buffer with blip_free(). */
int32_t blip_archive_create_full(const blip_archive_entry *entries, size_t entry_count,
                                  uint32_t flags,
                                  uint8_t **out_buf, size_t *out_len);

/* Get the container type of an entry (5 = FILE, 7 = DIR — v2 ContainerTypeId). */
int32_t blip_archive_entry_type(const uint8_t *buf, size_t buf_len,
                                 uint64_t index, uint8_t *out_type);

/* Extract metadata from an entry. Fields not present are set to 0/NULL. */
int32_t blip_archive_entry_metadata(const uint8_t *buf, size_t buf_len,
                                     uint64_t index,
                                     uint16_t *out_mode,
                                     int64_t *out_mtime_ns,
                                     const char **out_owner,
                                     size_t *out_owner_len);

/* Normalize a path by stripping leading "./" and "/" sequences (tar-style).
 * Returns a pointer into the original path buffer (zero-copy).
 * See normalizePath() in lib.zig for full documentation and examples. */
void blip_normalize_path(const char *path, size_t path_len,
                         const char **out_path, size_t *out_path_len);

/* --- Peek / navigation API --- */

/* Navigate to a container within a BLIP buffer using a path expression.
 * Path syntax: [N] for array index, [key] for dict key.
 * Returns 0 on success. out_type receives the v2 container type ID (1-7).
 * out_data/out_data_len receive a zero-copy pointer to the container bytes. */
int32_t blip_peek(const uint8_t *buf, size_t buf_len,
                  const char *path, size_t path_len,
                  uint8_t *out_type,
                  const uint8_t **out_data, size_t *out_data_len);

/* Get element/pair count for an array-like or dict-like container. */
int32_t blip_container_count(const uint8_t *buf, size_t len, uint64_t *out_count);

/* Get the trailing xxHash64 from a container (ARRAY, DICT, MAP, FILE, DIR, DATA).
 * out_hash must point to an 8-byte buffer. */
int32_t blip_container_hash(const uint8_t *buf, size_t len, uint8_t out_hash[8]);

/* Get the key payload bytes at the given pair index from a dict-like container.
 * Returns zero-copy pointer into buf. */
int32_t blip_container_key_at(const uint8_t *buf, size_t len, uint64_t index,
                               const uint8_t **out_key, size_t *out_key_len);

/* --- Peek display flags --- */
#define BLIP_PEEK_JSON   0x01u
#define BLIP_PEEK_RAW    0x02u
#define BLIP_PEEK_HEX    0x04u
#define BLIP_PEEK_IS_TTY 0x08u

/* Full peek display: navigate + format output in Zig core.
 * Returns 0 on success, negative error code on failure.
 * Caller must free stdout/stderr buffers with blip_free(). */
int32_t blip_peek_display(const uint8_t *buf, size_t buf_len,
                           const char *path, size_t path_len,
                           uint32_t flags,
                           const uint8_t **out_stdout, size_t *out_stdout_len,
                           const uint8_t **out_stderr, size_t *out_stderr_len);

/* --- Poke API --- */

/* Modify a value in a BLIP archive at the given path expression.
 * Returns a newly allocated archive buffer with the modification applied.
 * Returns 0 on success, negative error code on failure.
 * Caller must free the output buffer with blip_free().
 *
 * Error codes: -16 = immutable target (magic bytes),
 *              -17 = not a leaf (can't poke containers) */
#define BLIP_ERR_IMMUTABLE       -16
#define BLIP_ERR_NOT_A_LEAF      -17

int32_t blip_poke(const uint8_t *buf, size_t buf_len,
                  const char *path, size_t path_len,
                  const uint8_t *new_value, size_t new_value_len,
                  uint8_t **out_buf, size_t *out_len);

/* Encode binary data as printable-binary UTF-8.
 * Caller must free the output buffer with blip_free(). */
int32_t blip_encode_printable_binary(const uint8_t *input, size_t input_len,
                                      uint8_t **out_buf, size_t *out_len);

/* --- JSON serialization/deserialization --- */

/* Convert a BLIP archive to JSON.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_to_json(const uint8_t *buf, size_t buf_len,
                     uint8_t **out_buf, size_t *out_len);

/* Convert JSON to a BLIP archive.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_from_json(const uint8_t *json_buf, size_t json_len,
                       uint8_t **out_buf, size_t *out_len);

/* --- LZMA2 compression --- */

#define BLIP_ERR_DECOMPRESSION      -23
#define BLIP_ERR_COMPRESSION        -24
#define BLIP_ERR_MISSING_SIGIL      -25
#define BLIP_ERR_INVALID_SIGIL_ORDER -26
#define BLIP_ERR_MISSING_DECOMP_LEN -27

/* Compress a BLIP container with LZMA2.
 * Input: any serialized BLIP container bytes.
 * Output: a DATA container with COMP=lzma2, DECOMP_LEN, CSUM=blake3_128 attributes.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_lzma2_compress(const uint8_t *buf, size_t buf_len,
                             uint8_t **out_buf, size_t *out_len);

/* Decompress an LP container with COMP attribute.
 * Verifies checksum before decompressing.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_lzma2_decompress(const uint8_t *buf, size_t buf_len,
                               uint8_t **out_buf, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* BLIP_H */
