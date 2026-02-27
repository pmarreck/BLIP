# Encrypted Container Attribute Design

## Goal

Add per-container encryption as an optional LP attribute, following the same pattern as COMP and CSUM. Any container can opt into encryption. Two AEAD ciphers (AES-256-GCM, ChaCha20-Poly1305), two KDFs (Argon2id, PBKDF2-SHA256), password-based key derivation.

## Architecture

Encryption is a new attribute sigil `ENC = 0x13` in the LP envelope. It sits between CSUM (`0x12`) and SIG (`0x20`) in sort order. The ENC attribute value contains the cipher ID, KDF ID, salt, and nonce inline. The AEAD auth tag is appended to the encrypted payload.

**Attribute sort order**: TYPE(`0x01`) < COMP(`0x10`) < DECOMP_LEN(`0x11`) < CSUM(`0x12`) < ENC(`0x13`) < SIG(`0x20`) < VAL(`0x7F`)

## New Enums

```zig
// container_types.zig
pub const EncryptionId = enum(u7) {
    aes_256_gcm = 1,
    chacha20_poly1305 = 2,
};

pub const KdfId = enum(u7) {
    argon2id = 1,
    pbkdf2_sha256 = 2,
};
```

## ENC Attribute Layout

```
0x81 0x13  BLIP(enc_id)  BLIP(kdf_id)  <16 salt>  <12 nonce>
```

- Salt: 16 bytes (128-bit, for KDF)
- Nonce: 12 bytes (96-bit, for AEAD)
- Auth tag: 16 bytes, appended to end of encrypted VAL payload

Total overhead: ~32 bytes in attributes + 16 bytes auth tag in payload.

## On-Disk Layout Example

Encrypted DATA container:
```
BLIP(total_length)
0x81 0x01 BLIP(4)                                    -- TYPE = data
0x81 0x12 BLIP(2)                                    -- CSUM = xxhash64
0x81 0x13 BLIP(1) BLIP(1) <16 salt> <12 nonce>      -- ENC = aes_256_gcm, KDF = argon2id
0x81 0x7F                                            -- VAL
<encrypted_payload> <16 auth_tag> <8 xxhash64>
```

## Encrypt/Decrypt Flow

**Encrypt** (serialization):
1. Serialize payload normally
2. Generate random 16-byte salt + 12-byte nonce (OS CSPRNG)
3. Derive 256-bit key: `KDF(password, salt)` → key
4. AEAD encrypt: `encrypt(key, nonce, plaintext, aad="")` → ciphertext + auth tag
5. Write ENC attribute in LP header
6. Write ciphertext + auth tag as VAL payload
7. Checksum (if present) covers ciphertext + auth tag

**Decrypt** (reading):
1. `parseLPHeader` extracts enc_id, kdf_id, salt, nonce from ENC attribute
2. Caller provides password → derive key with same KDF
3. AEAD decrypt → plaintext or `AuthenticationFailed`
4. If COMP present: decompress after decryption

**Attribute interaction order**:
- Write: compress → encrypt → checksum
- Read: verify checksum → decrypt → decompress

## KDF Parameters

Hardcoded per KdfId (not stored in archive):

**Argon2id** (`kdf_id = 1`):
- Memory: 64 MiB (m = 65536)
- Iterations: 3 (t = 3)
- Parallelism: 4 (p = 4)
- Output: 32 bytes

**PBKDF2-SHA256** (`kdf_id = 2`):
- Iterations: 600,000
- Output: 32 bytes

New parameter sets → new KdfId values, not tunable fields.

## LPOptions / LPContainerView Changes

```zig
pub const LPOptions = struct {
    comp_id: ?CompressionId = null,
    decomp_len: ?u64 = null,
    csum_id: ?ChecksumId = null,
    enc_id: ?EncryptionId = null,
    kdf_id: ?KdfId = null,
};

pub const LPContainerView = struct {
    // ...existing fields...
    enc_id: ?EncryptionId,
    kdf_id: ?KdfId,
    enc_salt: ?[16]u8,
    enc_nonce: ?[12]u8,
};
```

## FFI

```c
int32_t blip_encrypt_container(const uint8_t *buf, size_t buf_len,
                                const char *password, size_t password_len,
                                uint8_t enc_id, uint8_t kdf_id,
                                uint8_t **out_buf, size_t *out_len);

int32_t blip_decrypt_container(const uint8_t *buf, size_t buf_len,
                                const char *password, size_t password_len,
                                uint8_t **out_buf, size_t *out_len);
```

## CLI

```bash
# Encrypt (whole-archive, v1 scope)
blar create -e archive.blar dir/              # AES-256-GCM + Argon2id (defaults)
blar create -e chacha archive.blar dir/       # ChaCha20-Poly1305
blar create -e aes --kdf pbkdf2 archive.blar dir/

# Decrypt (automatic when ENC detected)
blar list archive.blar                        # prompts for password
BLIP_PASSWORD=secret blar list archive.blar   # env var
```

Password from `BLIP_PASSWORD` env var or interactive prompt on stderr.

## Error Cases

- Wrong password → AEAD auth tag fails → `AuthenticationFailed`
- Truncated ciphertext → length check → `BufferTooSmall`
- Missing password → `PasswordRequired` (new error code)

## Scope

v1: whole-archive encryption (encrypt the outer ARRAY). Per-file encryption uses the same attribute system but CLI support is deferred.
