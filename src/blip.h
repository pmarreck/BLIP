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

/* Get file content from archive by index.
 * Handles per-file compression transparently (decompresses if needed).
 * Caller must free the returned buffer with blip_free_content(). */
int32_t blip_archive_file_content(const uint8_t *buf, size_t buf_len,
                                   uint64_t index,
                                   uint8_t **out_data, size_t *out_data_len);

/* Get file content by path.
 * Handles per-file compression transparently (decompresses if needed).
 * Caller must free the returned buffer with blip_free_content(). */
int32_t blip_archive_file_content_by_path(const uint8_t *buf, size_t buf_len,
                                           const char *path, size_t path_len,
                                           uint8_t **out_data, size_t *out_data_len);

/* Free content returned by blip_archive_file_content or blip_archive_file_content_by_path. */
void blip_free_content(uint8_t *data, size_t len);

/* Verify a single file's xh64 hash within archive.
 * For DIR entries, verifies the container hash only (no bina check). */
int32_t blip_archive_file_verify(const uint8_t *buf, size_t buf_len,
                                  uint64_t index);

/* Verify a DIR entry's Merkle hash by recomputing from child FILE checksums.
 * Returns 0 if valid, BLIP_ERR_HASH_MISMATCH if stale/wrong, negative on error. */
int32_t blip_archive_verify_merkle(const uint8_t *buf, size_t buf_len,
                                    uint64_t index);

/* --- Full archive (DIR + metadata) support --- */

/* An extended attribute name-value pair. */
typedef struct {
    const char *name;
    size_t name_len;
    const uint8_t *value;
    size_t value_len;
} blip_xattr_entry;

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
    const blip_xattr_entry *xattrs;   /* extended attributes, NULL = none */
    size_t xattr_count;               /* 0 = none */
    const uint8_t *resource_fork;     /* resource fork data (macOS), NULL = none */
    size_t resource_fork_len;         /* 0 = none */
    const char *container_type;       /* "zip" etc., NULL = normal dir */
    size_t container_type_len;        /* 0 = not a container */
    uint16_t zip_compression_method;  /* original zip method (0=store, 8=deflate), 0xFFFF = not set */
    uint64_t pdf_stream_offset;       /* byte offset of JPEG stream in PDF body, UINT64_MAX = not set */
    uint64_t pdf_stream_length;       /* original JPEG stream data length, UINT64_MAX = not set */
    const char *jxl_source_format;    /* source format (e.g. "jpeg", "flate"), NULL = not set */
    size_t jxl_source_format_len;     /* 0 = not set */
    uint16_t flate_predictor;         /* PDF /Predictor (10-15 for PNG variants), 0 = not set */
    uint32_t flate_columns;          /* PDF /Columns (image width in pixels), 0 = not set */
    uint8_t flate_colors;            /* PDF /Colors (channel count), 0 = not set */
    uint8_t flate_bpc;               /* PDF /BitsPerComponent, 0 = not set */
} blip_archive_entry;

/* Progress callback for archive creation.
 * Called after each entry is serialized with cumulative counts.
 * entries_done: entries serialized so far
 * bytes_done: cumulative content bytes serialized so far */
typedef void (*blip_progress_fn)(uint64_t entries_done, uint64_t bytes_done,
                                  void *user_ctx);

/* Phase callback for archive creation.
 * Called when the operation transitions to a new phase (e.g., "Assembling").
 * label/label_len: UTF-8 phase name (not null-terminated). */
typedef void (*blip_phase_fn)(const uint8_t *label, size_t label_len,
                               void *user_ctx);

/* Create a full BLIP archive with FILE + DIR entries and metadata.
 * per_file_comp_algo: 0=none, BLIP_COMP_LZMA2/BZIP2/LZ4/ZSTD for per-file compression.
 *   When non-zero, each file's DATA is individually compressed; outer archive is NOT compressed.
 *   For solid compression, pass 0 here and call blip_compress_container() on the result.
 * progress_fn: optional callback for per-entry progress (NULL to skip).
 * phase_fn: optional callback for phase transitions (NULL to skip).
 * progress_ctx: shared user context for both callbacks.
 * Returns 0 on success, negative error code on failure.
 * Caller must free the output buffer with blip_free(). */
int32_t blip_archive_create_full(const blip_archive_entry *entries, size_t entry_count,
                                  uint32_t flags, uint8_t per_file_comp_algo,
                                  uint8_t num_threads,
                                  blip_progress_fn progress_fn,
                                  blip_phase_fn phase_fn,
                                  void *progress_ctx,
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

/* Extract full metadata from an entry (all timestamps, uid/gid, groupname). */
int32_t blip_archive_entry_metadata_full(const uint8_t *buf, size_t buf_len,
    uint64_t index,
    uint16_t *out_mode, int64_t *out_mtime_ns, int64_t *out_ctime_ns, int64_t *out_birthtime_ns,
    uint32_t *out_uid, uint32_t *out_gid,
    const char **out_owner, size_t *out_owner_len,
    const char **out_groupname, size_t *out_groupname_len);

/* Extract xattrs and resource fork from an archive entry.
 * Returns heap-allocated arrays; caller must free with blip_free_xattrs().
 * For FILE entries: reads forks DICT (element 2), "rf" key → resource_fork, rest → xattrs.
 * For DIR entries: reads "xa" key from the DIR dict.
 * Returns 0 on success, negative error code on failure. */
int32_t blip_archive_entry_xattrs(const uint8_t *buf, size_t buf_len, uint64_t index,
                                   blip_xattr_entry **out_xattrs, size_t *out_count,
                                   uint8_t **out_resource_fork, size_t *out_resource_fork_len);

/* Free xattr data returned by blip_archive_entry_xattrs.
 * Frees the xattr array and resource fork buffer. */
void blip_free_xattrs(blip_xattr_entry *xattrs, size_t count,
                       uint8_t *resource_fork, size_t resource_fork_len);

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

/* Decode printable-binary UTF-8 back to raw bytes.
 * Caller must free the output buffer with blip_free(). */
int32_t blip_decode_printable_binary(const uint8_t *encoded, size_t encoded_len,
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

/* --- Compression --- */

/* Compression algorithm IDs */
#define BLIP_COMP_LZMA2  1
#define BLIP_COMP_BZIP2  2
#define BLIP_COMP_LZ4    3
#define BLIP_COMP_ZSTD   4

#define BLIP_ERR_DECOMPRESSION      -23
#define BLIP_ERR_COMPRESSION        -24
#define BLIP_ERR_MISSING_SIGIL      -25
#define BLIP_ERR_INVALID_SIGIL_ORDER -26
#define BLIP_ERR_MISSING_DECOMP_LEN -27
#define BLIP_ERR_UNSUPPORTED_COMPRESSION -32

/* Encryption errors */
#define BLIP_ERR_AUTH_FAILED       -28
#define BLIP_ERR_PASSWORD_REQUIRED -29
#define BLIP_ERR_ENCRYPTION        -30
#define BLIP_ERR_DECRYPTION        -31

/* ZIP container errors */
#define BLIP_ERR_INVALID_ZIP       -33
#define BLIP_ERR_ENCRYPTED_ZIP     -34
#define BLIP_ERR_ZIP64             -35
#define BLIP_ERR_ZIP_UNSUPPORTED   -36

/* PDF/JXL errors */
#define BLIP_ERR_INVALID_PDF       -37
#define BLIP_ERR_JXL_ENCODE        -38
#define BLIP_ERR_JXL_DECODE        -39

/* Check if a buffer is a compressed LP container (has COMP attribute). */
bool blip_is_compressed(const uint8_t *buf, size_t buf_len);

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

/* Progress callback for compression: (bytes_done, bytes_total, user_ctx). */
typedef void (*blip_compress_progress_fn)(uint64_t bytes_done, uint64_t bytes_total,
                                           void *user_ctx);

/* Compress a BLIP container with the specified algorithm.
 * algo_id: BLIP_COMP_LZMA2, BLIP_COMP_BZIP2, BLIP_COMP_LZ4, or BLIP_COMP_ZSTD.
 * progress_fn: optional callback for compression byte progress (NULL to skip).
 * phase_fn: optional callback for phase transitions (NULL to skip).
 * progress_ctx: shared user context for both callbacks.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_compress_container(const uint8_t *buf, size_t buf_len,
                                 uint8_t algo_id, uint8_t num_threads,
                                 blip_compress_progress_fn progress_fn,
                                 blip_phase_fn phase_fn,
                                 void *progress_ctx,
                                 uint8_t **out_buf, size_t *out_len);

/* Decompress a compressed LP container (any supported algorithm).
 * Reads the algorithm from the LP header's COMP attribute.
 * Verifies checksum before decompressing.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_decompress_container(const uint8_t *buf, size_t buf_len,
                                   uint8_t **out_buf, size_t *out_len);

/* --- Encryption --- */

/* Check if a buffer is an encrypted LP container (has ENC attribute). */
bool blip_is_encrypted(const uint8_t *buf, size_t buf_len);

/* Encrypt a serialized container.
 * enc_id: 1=AES-256-GCM, 2=ChaCha20-Poly1305
 * kdf_id: 1=Argon2id, 2=PBKDF2-SHA256
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_encrypt_container(const uint8_t *buf, size_t buf_len,
                                const char *password, size_t password_len,
                                uint8_t enc_id, uint8_t kdf_id,
                                uint8_t **out_buf, size_t *out_len);

/* Decrypt an encrypted LP container.
 * Returns 0 on success, negative error code on failure.
 * Caller must free output buffer with blip_free(). */
int32_t blip_decrypt_container(const uint8_t *buf, size_t buf_len,
                                const char *password, size_t password_len,
                                uint8_t **out_buf, size_t *out_len);

/* --- ZIP container operations --- */

/* Check if buffer starts with ZIP magic bytes (PK\x03\x04). */
bool blip_is_zip(const uint8_t *buf, size_t buf_len);

/* Check if a ZIP buffer contains any encrypted entries. */
bool blip_zip_has_encrypted(const uint8_t *buf, size_t buf_len);

/* Get the number of entries in a ZIP buffer. */
int32_t blip_zip_entry_count(const uint8_t *buf, size_t buf_len, uint64_t *out_count);

/* Get info about a specific ZIP entry by index. */
int32_t blip_zip_entry_info(const uint8_t *buf, size_t buf_len, uint64_t index,
    const char **out_path, size_t *out_path_len, uint16_t *out_comp_method,
    uint64_t *out_uncompressed_size, uint16_t *out_mtime, uint16_t *out_mdate,
    uint8_t *out_is_dir);

/* Extract (decompress) a specific ZIP entry by index.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_zip_extract_entry(const uint8_t *buf, size_t buf_len, uint64_t index,
    uint8_t **out_data, size_t *out_data_len);

/* Entry for creating a ZIP archive. */
typedef struct {
    const char *filename;
    size_t filename_len;
    const uint8_t *content;
    size_t content_len;
    uint16_t compression_method;
    uint16_t mtime;
    uint16_t mdate;
    uint32_t external_attributes;
} blip_zip_write_entry;

/* Create a ZIP archive from entries.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_zip_create(const blip_zip_write_entry *entries, size_t count,
    uint8_t **out_buf, size_t *out_len);

/* Read container_type from a DIR entry in a BLIP archive.
 * Sets out_type to NULL if not a container dir. */
int32_t blip_archive_entry_container_type(const uint8_t *buf, size_t buf_len,
    uint64_t index, const char **out_type, size_t *out_type_len);

/* Read zip_compression_method from a FILE entry in a BLIP archive.
 * Sets out_method to 0xFFFF if not set. */
int32_t blip_archive_entry_zip_comp(const uint8_t *buf, size_t buf_len,
    uint64_t index, uint16_t *out_method);

/* --- PDF container operations --- */

/* Check if buffer starts with PDF magic bytes (%PDF-). */
bool blip_is_pdf(const uint8_t *buf, size_t buf_len);

/* Count JPEG streams in a PDF buffer. */
int32_t blip_pdf_jpeg_count(const uint8_t *buf, size_t buf_len, uint64_t *out_count);

/* Get info about a specific JPEG stream in a PDF by index. */
int32_t blip_pdf_jpeg_info(const uint8_t *buf, size_t buf_len, uint64_t idx,
    uint64_t *out_offset, uint64_t *out_length, uint32_t *out_obj_num, uint32_t *out_gen_num);

/* Find all JPEG streams in a PDF and return their info in parallel arrays.
 * Single scan — much faster than calling jpeg_count + jpeg_info in a loop.
 * Caller must free output arrays with blip_free(). */
int32_t blip_pdf_jpeg_streams(const uint8_t *buf, size_t buf_len,
    uint64_t *out_count, uint64_t **out_offsets, uint64_t **out_lengths,
    uint32_t **out_obj_nums, uint32_t **out_gen_nums);

/* Create a PDF shell by zeroing JPEG stream regions.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_pdf_create_shell(const uint8_t *buf, size_t buf_len,
    const uint64_t *offsets, const uint64_t *lengths, size_t stream_count,
    uint8_t **out_shell, size_t *out_shell_len);

/* --- JPEG XL operations --- */

/* Losslessly transcode JPEG to JPEG XL.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_jxl_from_jpeg(const uint8_t *jpeg, size_t jpeg_len,
    uint8_t **out_jxl, size_t *out_jxl_len);

/* Losslessly transcode JPEG XL back to JPEG.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_jxl_to_jpeg(const uint8_t *jxl, size_t jxl_len,
    uint8_t **out_jpeg, size_t *out_jpeg_len);

/* Encode raw pixels to JXL lossless.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_jxl_from_pixels(const uint8_t *pixels, size_t pixels_len,
    uint32_t width, uint32_t height, uint32_t num_channels, uint32_t bits_per_sample,
    uint8_t **out_jxl, size_t *out_jxl_len);

/* Decode JXL to raw pixels.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_jxl_to_pixels(const uint8_t *jxl, size_t jxl_len,
    uint8_t **out_pixels, size_t *out_pixels_len,
    uint32_t *out_width, uint32_t *out_height,
    uint32_t *out_num_channels, uint32_t *out_bits_per_sample);

/* --- PNG operations --- */

/* Check if buffer starts with PNG signature. */
bool blip_is_png(const uint8_t *buf, size_t buf_len);

/* Parse a PNG into raw pixels and metadata (pre/post IDAT chunks).
 * Metadata format: [u32_be head_len][pre-IDAT bytes][post-IDAT bytes]
 * Caller must free out_pixels and out_meta with blip_free(). */
int32_t blip_png_parse(const uint8_t *png, size_t png_len,
    uint8_t **out_pixels, size_t *out_pixels_len,
    uint32_t *out_width, uint32_t *out_height,
    uint32_t *out_num_channels, uint32_t *out_bits_per_sample,
    uint8_t **out_meta, size_t *out_meta_len);

/* Encode raw pixels + metadata back to a PNG.
 * Caller must free returned buffer with blip_free(). */
int32_t blip_png_encode(
    const uint8_t *pixels, size_t pixels_len,
    uint32_t width, uint32_t height, uint32_t num_channels, uint32_t bits_per_sample,
    const uint8_t *meta, size_t meta_len,
    uint8_t **out_png, size_t *out_png_len);

/* --- FlateDecode (PDF) operations --- */

#define BLIP_ERR_FLATE -41

/* Find all FlateDecode image streams in a PDF (Predictor >= 10 only).
 * Returns stream info in parallel arrays. Caller must free with blip_free(). */
int32_t blip_pdf_flate_streams(const uint8_t *buf, size_t buf_len,
    uint64_t *out_count,
    uint64_t **out_offsets, uint64_t **out_lengths,
    uint32_t **out_obj_nums, uint32_t **out_gen_nums,
    uint16_t **out_predictors, uint32_t **out_columns,
    uint8_t **out_colors, uint8_t **out_bpcs,
    uint32_t **out_widths, uint32_t **out_heights);

/* Decompress zlib data. Caller must free output with blip_free(). */
int32_t blip_zlib_decompress(const uint8_t *data, size_t data_len,
    uint8_t **out, size_t *out_len);

/* Compress data with zlib. Caller must free output with blip_free(). */
int32_t blip_zlib_compress(const uint8_t *data, size_t data_len,
    uint8_t **out, size_t *out_len);

/* Decompress gzip data. Caller must free output with blip_free(). */
int32_t blip_gz_decompress(const uint8_t *data, size_t data_len,
    uint8_t **out, size_t *out_len);

/* Compress data to gzip format. Caller must free output with blip_free(). */
int32_t blip_gz_compress(const uint8_t *data, size_t data_len,
    uint8_t **out, size_t *out_len);

/* Check if buffer starts with gzip magic bytes (0x1f 0x8b). */
bool blip_is_gz(const uint8_t *buf, size_t buf_len);

/* Remove PNG-style row filters from FlateDecode data.
 * Returns raw pixels. Caller must free with blip_free(). */
int32_t blip_pdf_defilter(const uint8_t *data, size_t data_len,
    uint32_t columns, uint8_t colors, uint8_t bpc, uint16_t predictor,
    uint8_t **out, size_t *out_len);

/* Re-apply PNG-style row filters to pixels for FlateDecode.
 * Caller must free with blip_free(). */
int32_t blip_pdf_refilter(const uint8_t *pixels, size_t pixels_len,
    uint32_t columns, uint8_t colors, uint8_t bpc, uint16_t predictor,
    uint8_t **out, size_t *out_len);

/* Rewrite a PDF shell, replacing stream data regions that may differ in size.
 * Updates /Length values and rebuilds the xref table.
 * Returns 0 on success, -42 if xref streams (skip rewrite), negative on error.
 * Caller must free output with blip_free(). */
#define BLIP_ERR_XREF_STREAM -42
int32_t blip_pdf_rewrite_streams(const uint8_t *shell, size_t shell_len,
    size_t count,
    const uint64_t *stream_starts, const uint64_t *original_lengths,
    const uint8_t *const *new_datas, const size_t *new_data_lens,
    uint8_t **out, size_t *out_len);

#define BLIP_ERR_INVALID_PNG -40

/* Find all non-image FlateDecode content streams in a PDF.
 * Returns parallel arrays of offsets and lengths. Caller frees with blip_free(). */
int32_t blip_pdf_content_streams(const uint8_t *buf, size_t buf_len,
    uint64_t *out_count, uint64_t **out_offsets, uint64_t **out_lengths);

/* Read pdf_stream_offset from a FILE entry.
 * Sets out to UINT64_MAX if not set. */
int32_t blip_archive_entry_pdf_offset(const uint8_t *buf, size_t buf_len,
    uint64_t index, uint64_t *out);

/* Read pdf_stream_length from a FILE entry.
 * Sets out to UINT64_MAX if not set. */
int32_t blip_archive_entry_pdf_length(const uint8_t *buf, size_t buf_len,
    uint64_t index, uint64_t *out);

/* Read jxl_source_format from a FILE entry.
 * Sets out_fmt to NULL if not set. */
int32_t blip_archive_entry_jxl_source(const uint8_t *buf, size_t buf_len,
    uint64_t index, const char **out_fmt, size_t *out_fmt_len);

#ifdef __cplusplus
}
#endif

#endif /* BLIP_H */
