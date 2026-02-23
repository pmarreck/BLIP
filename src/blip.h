#ifndef BLIP_H
#define BLIP_H

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

#ifdef __cplusplus
}
#endif

#endif /* BLIP_H */
