# Encryption Attribute Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add per-container AES-256-GCM and ChaCha20-Poly1305 encryption with Argon2id/PBKDF2 key derivation as an LP attribute.

**Architecture:** New `ENC` attribute sigil (`0x13`) in the LP envelope. Encryption module (`src/encryption.zig`) mirrors the compression module pattern: `encryptContainer()` / `decryptContainer()` wrap any serialized bytes. C CLI gets `-e` flag for `blar create`, auto-prompts password on read.

**Tech Stack:** Zig stdlib `std.crypto` (AES-GCM, ChaCha20-Poly1305, Argon2), BLIP LP container system, C FFI.

**Design doc:** `docs/plans/2026-02-27-encryption-attribute-design.md`

---

### Task 1: Add EncryptionId, KdfId enums and ENC sigil to container_types.zig

**Files:**
- Modify: `src/container_types.zig`

**Step 1: Write the failing test**

Add to end of `src/container_types.zig`:

```zig
test "EncryptionId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(EncryptionId.aes_256_gcm));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(EncryptionId.chacha20_poly1305));
}

test "KdfId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(KdfId.argon2id));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(KdfId.pbkdf2_sha256));
}

test "ENC sigil fits in sorted order" {
    try testing.expect(@intFromEnum(AttributeSigil.csum) < @intFromEnum(AttributeSigil.enc));
    try testing.expect(@intFromEnum(AttributeSigil.enc) < @intFromEnum(AttributeSigil.sig));
}

test "authTagLength returns correct sizes" {
    try testing.expectEqual(@as(u8, 16), authTagLength(.aes_256_gcm));
    try testing.expectEqual(@as(u8, 16), authTagLength(.chacha20_poly1305));
}

test "encNonceLength returns correct sizes" {
    try testing.expectEqual(@as(u8, 12), encNonceLength(.aes_256_gcm));
    try testing.expectEqual(@as(u8, 12), encNonceLength(.chacha20_poly1305));
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -20`
Expected: Compilation error — `EncryptionId`, `KdfId`, `authTagLength`, `encNonceLength`, `AttributeSigil.enc` not found.

**Step 3: Write minimal implementation**

Add to `src/container_types.zig` (after `ChecksumId`):

```zig
/// Encryption algorithm IDs — the value after an ENC attribute sigil.
pub const EncryptionId = enum(u7) {
    aes_256_gcm = 1,
    chacha20_poly1305 = 2,
};

/// Key derivation function IDs — stored in the ENC attribute value.
pub const KdfId = enum(u7) {
    argon2id = 1,
    pbkdf2_sha256 = 2,
};
```

Add `enc = 0x13` to `AttributeSigil` enum (between `csum = 0x12` and `sig = 0x20`).

Add helper functions after `checksumLength`:

```zig
/// Return the AEAD authentication tag length for the given encryption algorithm.
pub fn authTagLength(id: EncryptionId) u8 {
    return switch (id) {
        .aes_256_gcm => 16,
        .chacha20_poly1305 => 16,
    };
}

/// Return the nonce length for the given encryption algorithm.
pub fn encNonceLength(id: EncryptionId) u8 {
    return switch (id) {
        .aes_256_gcm => 12,
        .chacha20_poly1305 => 12,
    };
}

/// Salt length for KDF (constant 16 bytes for all KDFs).
pub const ENC_SALT_LEN: u8 = 16;
```

Update the existing sigil sort order test:
```zig
test "attribute sigils are sorted (TYPE < COMP < DECOMP_LEN < CSUM < ENC < SIG < VAL)" {
    try testing.expect(@intFromEnum(AttributeSigil.type_attr) < @intFromEnum(AttributeSigil.comp));
    try testing.expect(@intFromEnum(AttributeSigil.comp) < @intFromEnum(AttributeSigil.decomp_len));
    try testing.expect(@intFromEnum(AttributeSigil.decomp_len) < @intFromEnum(AttributeSigil.csum));
    try testing.expect(@intFromEnum(AttributeSigil.csum) < @intFromEnum(AttributeSigil.enc));
    try testing.expect(@intFromEnum(AttributeSigil.enc) < @intFromEnum(AttributeSigil.sig));
    try testing.expect(@intFromEnum(AttributeSigil.sig) < @intFromEnum(AttributeSigil.val));
}
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1; echo "EXIT: $?"`
Expected: EXIT: 0

**Step 5: Commit**

```bash
git add src/container_types.zig
git commit -m "feat: add EncryptionId, KdfId enums and ENC attribute sigil"
```

---

### Task 2: Add ENC attribute to LP container header (write + parse + length)

**Files:**
- Modify: `src/container.zig:44-48` (LPOptions)
- Modify: `src/container.zig:50-62` (LPContainerView)
- Modify: `src/container.zig:85-120` (computeLPLength)
- Modify: `src/container.zig:129-186` (writeLPHeader)
- Modify: `src/container.zig:193-308` (parseLPHeader)

**Step 1: Write the failing test**

Add to end of container.zig tests:

```zig
test "LP container with ENC attribute round-trips" {
    const allocator = testing.allocator;
    const payload = "secret data";

    // Use a fixed salt and nonce for testing
    var salt: [16]u8 = undefined;
    @memset(&salt, 0xAA);
    var nonce: [12]u8 = undefined;
    @memset(&nonce, 0xBB);

    const opts = LPOptions{
        .enc_id = .aes_256_gcm,
        .kdf_id = .argon2id,
        .enc_salt = salt,
        .enc_nonce = nonce,
    };
    const total = computeLPLength(.data, payload.len, opts);
    const buf = try allocator.alloc(u8, @intCast(total));
    defer allocator.free(buf);

    const header_len = try writeLPHeader(buf, .data, total, opts);
    @memcpy(buf[header_len..][0..payload.len], payload);

    const view = try parseLPHeader(buf);
    try testing.expectEqual(@as(?ct.EncryptionId, .aes_256_gcm), view.enc_id);
    try testing.expectEqual(@as(?ct.KdfId, .argon2id), view.kdf_id);
    try testing.expectEqualSlices(u8, &salt, &view.enc_salt.?);
    try testing.expectEqualSlices(u8, &nonce, &view.enc_nonce.?);
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
}

test "ENC attribute overhead is correct" {
    // ENC overhead: 2 (sentinel) + 1 (BLIP enc_id) + 1 (BLIP kdf_id) + 16 (salt) + 12 (nonce) = 32
    var salt: [16]u8 = undefined;
    @memset(&salt, 0);
    var nonce: [12]u8 = undefined;
    @memset(&nonce, 0);

    const with_enc = computeLPLength(.data, 10, .{
        .enc_id = .aes_256_gcm,
        .kdf_id = .argon2id,
        .enc_salt = salt,
        .enc_nonce = nonce,
    });
    const without_enc = computeLPLength(.data, 10, .{});
    // Difference should be 32 bytes (2 sentinel + 1 enc_id + 1 kdf_id + 16 salt + 12 nonce)
    try testing.expectEqual(@as(u64, 32), with_enc - without_enc);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -20`
Expected: Compilation error — `LPOptions` has no fields `enc_id`, `kdf_id`, `enc_salt`, `enc_nonce`.

**Step 3: Write minimal implementation**

**LPOptions** (container.zig:44-48) — add fields:
```zig
pub const LPOptions = struct {
    comp_id: ?CompressionId = null,
    decomp_len: ?u64 = null,
    csum_id: ?ChecksumId = null,
    enc_id: ?EncryptionId = null,
    kdf_id: ?KdfId = null,
    enc_salt: ?[ct.ENC_SALT_LEN]u8 = null,
    enc_nonce: ?[12]u8 = null,
};
```

**LPContainerView** (container.zig:50-62) — add fields:
```zig
pub const LPContainerView = struct {
    total_length: u64,
    type_id: ContainerTypeId,
    comp_id: ?CompressionId,
    decomp_len: ?u64,
    csum_id: ?ChecksumId,
    enc_id: ?EncryptionId,
    kdf_id: ?KdfId,
    enc_salt: ?[ct.ENC_SALT_LEN]u8,
    enc_nonce: ?[12]u8,
    val_offset: usize,
    val_size: usize,
    buf: []const u8,
    // ...existing methods unchanged...
};
```

Initialize new fields to `null` in the return statement of `parseLPHeader`.

**computeLPLength** (container.zig:85-120) — add ENC overhead after CSUM:
```zig
// ENC sentinel + BLIP(enc_id) + BLIP(kdf_id) + salt + nonce -- optional
if (options.enc_id) |enc_id| {
    attr_overhead += 2 + blip.encodedSize(@intFromEnum(enc_id));
    attr_overhead += blip.encodedSize(@intFromEnum(options.kdf_id orelse .argon2id));
    attr_overhead += ct.ENC_SALT_LEN; // salt
    attr_overhead += ct.encNonceLength(enc_id); // nonce
}
```

**writeLPHeader** (container.zig:129-186) — add ENC write between CSUM and VAL:
```zig
// 6. ENC sentinel + BLIP(enc_id) + BLIP(kdf_id) + salt + nonce -- optional
if (options.enc_id) |enc_id| {
    const enc_sentinel = ct.attrSentinel(.enc);
    if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
    buf[pos] = enc_sentinel[0];
    buf[pos + 1] = enc_sentinel[1];
    pos += 2;
    const enc_bytes = blip.encode(@intFromEnum(enc_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += enc_bytes;
    const kdf_id = options.kdf_id orelse .argon2id;
    const kdf_bytes = blip.encode(@intFromEnum(kdf_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += kdf_bytes;
    // Write salt
    const salt = options.enc_salt orelse @as([ct.ENC_SALT_LEN]u8, @splat(0));
    @memcpy(buf[pos..][0..ct.ENC_SALT_LEN], &salt);
    pos += ct.ENC_SALT_LEN;
    // Write nonce
    const nonce_len = ct.encNonceLength(enc_id);
    const nonce = options.enc_nonce orelse @as([12]u8, @splat(0));
    @memcpy(buf[pos..][0..nonce_len], nonce[0..nonce_len]);
    pos += nonce_len;
}
```

**parseLPHeader** (container.zig:193-308) — add ENC parsing in the switch:

Add variables before the while loop:
```zig
var enc_id: ?EncryptionId = null;
var kdf_id: ?KdfId = null;
var enc_salt: ?[ct.ENC_SALT_LEN]u8 = null;
var enc_nonce: ?[12]u8 = null;
```

Add `.enc` case in the switch (after `.csum`, before `.sig`):
```zig
.enc => {
    // BLIP(enc_id)
    const enc_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
        error.Overflow => return ContainerError.Overflow,
        error.BufferTooSmall => return ContainerError.BufferTooSmall,
    };
    enc_id = std.meta.intToEnum(EncryptionId, @as(u7, @truncate(enc_result.value))) catch
        return ContainerError.InvalidContainerType;
    pos += enc_result.bytes_read;

    // BLIP(kdf_id)
    const kdf_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
        error.Overflow => return ContainerError.Overflow,
        error.BufferTooSmall => return ContainerError.BufferTooSmall,
    };
    kdf_id = std.meta.intToEnum(KdfId, @as(u7, @truncate(kdf_result.value))) catch
        return ContainerError.InvalidContainerType;
    pos += kdf_result.bytes_read;

    // 16-byte salt
    if (pos + ct.ENC_SALT_LEN > container_buf.len) return ContainerError.UnexpectedEndOfInput;
    var salt: [ct.ENC_SALT_LEN]u8 = undefined;
    @memcpy(&salt, container_buf[pos..][0..ct.ENC_SALT_LEN]);
    enc_salt = salt;
    pos += ct.ENC_SALT_LEN;

    // nonce (length depends on enc_id)
    const nonce_len = ct.encNonceLength(enc_id.?);
    if (pos + nonce_len > container_buf.len) return ContainerError.UnexpectedEndOfInput;
    var nonce: [12]u8 = .{0} ** 12;
    @memcpy(nonce[0..nonce_len], container_buf[pos..][0..nonce_len]);
    enc_nonce = nonce;
    pos += nonce_len;
},
```

Add new fields to the `LPContainerView` return in the `.val` branch:
```zig
.enc_id = enc_id,
.kdf_id = kdf_id,
.enc_salt = enc_salt,
.enc_nonce = enc_nonce,
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1; echo "EXIT: $?"`
Expected: EXIT: 0

**Step 5: Commit**

```bash
git add src/container.zig
git commit -m "feat: add ENC attribute to LP container header (write/parse/length)"
```

---

### Task 3: Create encryption.zig core module

**Files:**
- Create: `src/encryption.zig`
- Modify: `src/blip.zig` (add import)

This is the core encryption module, modeled after `src/compression.zig`.

**Step 1: Write the failing test**

Create `src/encryption.zig` with tests only:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const ct = @import("container_types.zig");
const container = @import("container.zig");
const csum_mod = @import("checksum.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;

pub const EncryptionError = error{
    EncryptionFailed,
    DecryptionFailed,
    AuthenticationFailed,
    PasswordRequired,
    UnsupportedEncryption,
    UnsupportedKdf,
};

test "AES-256-GCM encrypt/decrypt round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const plaintext = "Hello, encryption module! This is a test.";
    const password = "test-password-123";

    const result = try encrypt(allocator, .aes_256_gcm, .argon2id, plaintext, password);
    defer allocator.free(result.ciphertext);

    const decrypted = try decrypt(allocator, .aes_256_gcm, .argon2id, result.ciphertext, result.salt, result.nonce, password);
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "ChaCha20-Poly1305 encrypt/decrypt round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const plaintext = "ChaCha20 test payload";
    const password = "another-password";

    const result = try encrypt(allocator, .chacha20_poly1305, .argon2id, plaintext, password);
    defer allocator.free(result.ciphertext);

    const decrypted = try decrypt(allocator, .chacha20_poly1305, .argon2id, result.ciphertext, result.salt, result.nonce, password);
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "wrong password returns AuthenticationFailed" {
    const allocator = testing.allocator;
    const plaintext = "secret";
    const password = "correct-password";

    const result = try encrypt(allocator, .aes_256_gcm, .argon2id, plaintext, password);
    defer allocator.free(result.ciphertext);

    const bad = decrypt(allocator, .aes_256_gcm, .argon2id, result.ciphertext, result.salt, result.nonce, "wrong-password");
    try testing.expectError(error.AuthenticationFailed, bad);
}

test "encryptContainer/decryptContainer round-trip" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    // Create a simple DATA container
    const data_bytes = try leaf.serializeData(allocator, "hello encrypted world");
    defer allocator.free(data_bytes);

    const encrypted = try encryptContainer(allocator, .aes_256_gcm, .argon2id, data_bytes, "my-password");
    defer allocator.free(encrypted);

    // Verify it's an encrypted LP container
    const view = try container.parseLPHeader(encrypted);
    try testing.expectEqual(@as(?ct.EncryptionId, .aes_256_gcm), view.enc_id);
    try testing.expectEqual(@as(?ct.KdfId, .argon2id), view.kdf_id);
    try testing.expect(view.enc_salt != null);
    try testing.expect(view.enc_nonce != null);

    const decrypted = try decryptContainer(allocator, encrypted, "my-password");
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, data_bytes, decrypted);
}

test "encryptContainer with PBKDF2" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const data_bytes = try leaf.serializeData(allocator, "pbkdf2 test");
    defer allocator.free(data_bytes);

    const encrypted = try encryptContainer(allocator, .chacha20_poly1305, .pbkdf2_sha256, data_bytes, "pbkdf2-pass");
    defer allocator.free(encrypted);

    const decrypted = try decryptContainer(allocator, encrypted, "pbkdf2-pass");
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, data_bytes, decrypted);
}

test "isEncrypted detects encrypted containers" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const plain = try leaf.serializeData(allocator, "plain");
    defer allocator.free(plain);
    try testing.expect(!isEncrypted(plain));

    const encrypted = try encryptContainer(allocator, .aes_256_gcm, .argon2id, plain, "pass");
    defer allocator.free(encrypted);
    try testing.expect(isEncrypted(encrypted));
}

test "empty plaintext round-trips" {
    const allocator = testing.allocator;
    const result = try encrypt(allocator, .aes_256_gcm, .argon2id, "", "pass");
    defer allocator.free(result.ciphertext);

    const decrypted = try decrypt(allocator, .aes_256_gcm, .argon2id, result.ciphertext, result.salt, result.nonce, "pass");
    defer allocator.free(decrypted);

    try testing.expectEqual(@as(usize, 0), decrypted.len);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -20`
Expected: Compilation error — `encrypt`, `decrypt`, `encryptContainer`, `decryptContainer`, `isEncrypted` not defined.

**Step 3: Write minimal implementation**

Implement in `src/encryption.zig`:

```zig
const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Argon2 = std.crypto.pwhash.argon2;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const EncryptResult = struct {
    ciphertext: []u8, // includes auth tag appended
    salt: [ct.ENC_SALT_LEN]u8,
    nonce: [12]u8,
};

/// Derive a 256-bit key from password + salt using the specified KDF.
pub fn deriveKey(kdf_id: ct.KdfId, password: []const u8, salt: []const u8) EncryptionError![32]u8 {
    switch (kdf_id) {
        .argon2id => {
            // Argon2id: m=65536 (64MiB), t=3, p=4
            var key: [32]u8 = undefined;
            Argon2.kdf(
                &key,
                password,
                salt[0..ct.ENC_SALT_LEN].*,
                .{ .t = 3, .m = 65536, .p = 4 },
                .argon2id,
            ) catch return error.EncryptionFailed;
            return key;
        },
        .pbkdf2_sha256 => {
            var key: [32]u8 = undefined;
            std.crypto.pwhash.pbkdf2(&key, password, salt[0..ct.ENC_SALT_LEN], 600_000, HmacSha256);
            return key;
        },
    }
}

/// Encrypt plaintext with the specified cipher and KDF.
/// Returns ciphertext (with appended auth tag), salt, and nonce.
pub fn encrypt(allocator: Allocator, enc_id: ct.EncryptionId, kdf_id: ct.KdfId, plaintext: []const u8, password: []const u8) (Allocator.Error || EncryptionError)!EncryptResult {
    // Generate random salt and nonce
    var salt: [ct.ENC_SALT_LEN]u8 = undefined;
    std.crypto.random.bytes(&salt);
    var nonce: [12]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const key = try deriveKey(kdf_id, password, &salt);

    const tag_len = ct.authTagLength(enc_id);
    const out = try allocator.alloc(u8, plaintext.len + tag_len);
    errdefer allocator.free(out);

    switch (enc_id) {
        .aes_256_gcm => {
            var tag: [16]u8 = undefined;
            AesGcm.encrypt(out[0..plaintext.len], &tag, plaintext, "", nonce, key);
            @memcpy(out[plaintext.len..][0..16], &tag);
        },
        .chacha20_poly1305 => {
            var tag: [16]u8 = undefined;
            ChaCha.encrypt(out[0..plaintext.len], &tag, plaintext, "", nonce, key);
            @memcpy(out[plaintext.len..][0..16], &tag);
        },
    }

    return .{ .ciphertext = out, .salt = salt, .nonce = nonce };
}

/// Decrypt ciphertext (with appended auth tag) using the specified cipher and KDF.
pub fn decrypt(allocator: Allocator, enc_id: ct.EncryptionId, kdf_id: ct.KdfId, ciphertext_with_tag: []const u8, salt: [ct.ENC_SALT_LEN]u8, nonce: [12]u8, password: []const u8) (Allocator.Error || EncryptionError)![]u8 {
    const tag_len = ct.authTagLength(enc_id);
    if (ciphertext_with_tag.len < tag_len) return error.DecryptionFailed;

    const key = try deriveKey(kdf_id, password, &salt);
    const ct_len = ciphertext_with_tag.len - tag_len;
    const ciphertext = ciphertext_with_tag[0..ct_len];
    var tag: [16]u8 = undefined;
    @memcpy(&tag, ciphertext_with_tag[ct_len..][0..16]);

    const out = try allocator.alloc(u8, ct_len);
    errdefer allocator.free(out);

    switch (enc_id) {
        .aes_256_gcm => {
            AesGcm.decrypt(out, ciphertext, tag, "", nonce, key) catch return error.AuthenticationFailed;
        },
        .chacha20_poly1305 => {
            ChaCha.decrypt(out, ciphertext, tag, "", nonce, key) catch return error.AuthenticationFailed;
        },
    }

    return out;
}

/// Wrap serialized bytes in an encrypted LP DATA container.
/// Produces: [BLIP(total)] [TYPE=data] [CSUM=blake3_128] [ENC=...] [VAL] [ciphertext+tag] [BLAKE3-128]
pub fn encryptContainer(allocator: Allocator, enc_id: ct.EncryptionId, kdf_id: ct.KdfId, container_bytes: []const u8, password: []const u8) (Allocator.Error || ContainerError || EncryptionError)![]u8 {
    const result = try encrypt(allocator, enc_id, kdf_id, container_bytes, password);
    defer allocator.free(result.ciphertext);

    const options: container.LPOptions = .{
        .csum_id = .blake3_128,
        .enc_id = enc_id,
        .kdf_id = kdf_id,
        .enc_salt = result.salt,
        .enc_nonce = result.nonce,
    };

    const total = container.computeLPLength(.data, result.ciphertext.len, options);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    const header_len = try container.writeLPHeader(buf, .data, total, options);
    @memcpy(buf[header_len..][0..result.ciphertext.len], result.ciphertext);

    // Write BLAKE3-128 checksum over everything before checksum
    const csum_len = ct.checksumLength(.blake3_128);
    const csum_result = csum_mod.compute(.blake3_128, buf[0..@as(usize, @intCast(total)) - csum_len]);
    @memcpy(buf[@as(usize, @intCast(total)) - csum_len..@as(usize, @intCast(total))], csum_result[0..csum_len]);

    return buf;
}

/// Decrypt an LP container with ENC attribute.
/// Verifies checksum, then decrypts.
pub fn decryptContainer(allocator: Allocator, buf: []const u8, password: []const u8) (Allocator.Error || ContainerError || EncryptionError)![]u8 {
    const view = try container.parseLPHeader(buf);

    const enc_id = view.enc_id orelse return error.InvalidContainerType;
    const kdf_id = view.kdf_id orelse return error.InvalidContainerType;
    const salt = view.enc_salt orelse return error.InvalidContainerType;
    const nonce = view.enc_nonce orelse return error.InvalidContainerType;

    // Verify checksum if present
    if (view.csum_id) |csum_id| {
        const csum_bytes = view.checksumSlice();
        const data_to_check = buf[0..@as(usize, @intCast(view.total_length)) - ct.checksumLength(csum_id)];
        if (!csum_mod.verify(csum_id, data_to_check, csum_bytes)) {
            return error.HashMismatch;
        }
    }

    // Get payload (ciphertext + auth tag, minus checksum)
    const payload = view.payloadSlice();

    return decrypt(allocator, enc_id, kdf_id, payload, salt, nonce, password);
}

/// Quick check if buffer starts with an encrypted LP container.
pub fn isEncrypted(buf: []const u8) bool {
    const view = container.parseLPHeader(buf) catch return false;
    return view.enc_id != null;
}
```

**Important crypto API notes for the implementer:**
- `std.crypto.aead.aes_gcm.Aes256Gcm` — check exact Zig 0.15 import path. May be `std.crypto.aead.Aes256Gcm` or under a submodule. Verify with `zig build test` and adjust.
- `std.crypto.pwhash.argon2` — the `kdf` function signature may differ. Check Zig 0.15 stdlib docs. The `.argon2id` mode parameter selects the algorithm variant.
- `std.crypto.pwhash.pbkdf2` — verify exact function signature in Zig 0.15.

Add to `src/blip.zig`:
```zig
pub const encryption = @import("encryption.zig");
```

Add `"encryption.zig"` to `build.zig` if modules are listed explicitly (check `build.zig` first).

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1; echo "EXIT: $?"`
Expected: EXIT: 0

Note: Argon2id tests will be slow (~1-2 seconds each due to 64MiB memory cost). This is expected.

**Step 5: Commit**

```bash
git add src/encryption.zig src/blip.zig
git commit -m "feat: add encryption.zig core module (AES-256-GCM, ChaCha20-Poly1305, Argon2id, PBKDF2)"
```

---

### Task 4: Add FFI exports for encryption/decryption

**Files:**
- Modify: `src/lib.zig`
- Modify: `src/blip.h`

**Step 1: Write the failing test**

Add to `src/lib.zig` tests:

```zig
test "C FFI: blip_encrypt_container and blip_decrypt_container round-trip" {
    const leaf = @import("leaf.zig");
    const data_bytes = try leaf.serializeData(testing.allocator, "FFI encryption test");
    defer testing.allocator.free(data_bytes);

    var encrypted_buf: [*]u8 = undefined;
    var encrypted_len: usize = 0;
    const enc_rc = blip_encrypt_container(
        data_bytes.ptr, data_bytes.len,
        "test-password", 13,
        1, // aes_256_gcm
        1, // argon2id
        &encrypted_buf, &encrypted_len,
    );
    try testing.expectEqual(@as(i32, 0), enc_rc);
    defer blip_free(encrypted_buf, encrypted_len);

    var decrypted_buf: [*]u8 = undefined;
    var decrypted_len: usize = 0;
    const dec_rc = blip_decrypt_container(
        encrypted_buf, encrypted_len,
        "test-password", 13,
        &decrypted_buf, &decrypted_len,
    );
    try testing.expectEqual(@as(i32, 0), dec_rc);
    defer blip_free(decrypted_buf, decrypted_len);

    try testing.expectEqualSlices(u8, data_bytes, decrypted_buf[0..decrypted_len]);
}

test "C FFI: blip_is_encrypted detects encrypted containers" {
    const leaf = @import("leaf.zig");
    const data_bytes = try leaf.serializeData(testing.allocator, "test");
    defer testing.allocator.free(data_bytes);

    try testing.expect(!blip_is_encrypted(data_bytes.ptr, data_bytes.len));

    var encrypted_buf: [*]u8 = undefined;
    var encrypted_len: usize = 0;
    _ = blip_encrypt_container(data_bytes.ptr, data_bytes.len, "p", 1, 1, 1, &encrypted_buf, &encrypted_len);
    defer blip_free(encrypted_buf, encrypted_len);

    try testing.expect(blip_is_encrypted(encrypted_buf, encrypted_len));
}
```

**Step 2: Run test to verify it fails**

Expected: `blip_encrypt_container`, `blip_decrypt_container`, `blip_is_encrypted` not found.

**Step 3: Write minimal implementation**

Add to `src/lib.zig`:

```zig
const encryption = @import("encryption.zig");

/// Encrypt a serialized container with the specified cipher and KDF.
export fn blip_encrypt_container(
    buf: [*]const u8,
    buf_len: usize,
    password: [*]const u8,
    password_len: usize,
    enc_id: u8,
    kdf_id: u8,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const enc = std.meta.intToEnum(ct.EncryptionId, @as(u7, @truncate(enc_id))) catch return -1;
    const kdf = std.meta.intToEnum(ct.KdfId, @as(u7, @truncate(kdf_id))) catch return -1;
    const result = encryption.encryptContainer(
        page_allocator, enc, kdf,
        buf[0..buf_len], password[0..password_len],
    ) catch |e| {
        if (e == error.OutOfMemory) return -13;
        return -99;
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Decrypt an encrypted LP container.
export fn blip_decrypt_container(
    buf: [*]const u8,
    buf_len: usize,
    password: [*]const u8,
    password_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = encryption.decryptContainer(
        page_allocator, buf[0..buf_len], password[0..password_len],
    ) catch |e| {
        if (e == error.AuthenticationFailed) return BLIP_ERR_AUTH_FAILED;
        if (e == error.OutOfMemory) return -13;
        if (e == error.HashMismatch) return -7;
        return -99;
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Check if a buffer contains an encrypted LP container.
export fn blip_is_encrypted(
    buf: [*]const u8,
    buf_len: usize,
) callconv(.c) bool {
    return encryption.isEncrypted(buf[0..buf_len]);
}

const BLIP_ERR_AUTH_FAILED: i32 = -28;
```

Add to `src/blip.h`:

```c
#define BLIP_ERR_AUTH_FAILED     -28
#define BLIP_ERR_PASSWORD_REQUIRED -29

/* Encrypt a serialized container. Caller must free output with blip_free(). */
int32_t blip_encrypt_container(const uint8_t *buf, size_t buf_len,
                                const char *password, size_t password_len,
                                uint8_t enc_id, uint8_t kdf_id,
                                uint8_t **out_buf, size_t *out_len);

/* Decrypt an encrypted LP container. Caller must free output with blip_free(). */
int32_t blip_decrypt_container(const uint8_t *buf, size_t buf_len,
                                const char *password, size_t password_len,
                                uint8_t **out_buf, size_t *out_len);

/* Check if buffer contains an encrypted LP container. */
bool blip_is_encrypted(const uint8_t *buf, size_t buf_len);
```

Add error string mapping for -28 and -29 in `blip_error_string`.

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1; echo "EXIT: $?"`
Expected: EXIT: 0

**Step 5: Commit**

```bash
git add src/lib.zig src/blip.h
git commit -m "feat: add FFI exports for encryption/decryption"
```

---

### Task 5: Wire encryption into C CLI (blar create -e, auto-decrypt on read)

**Files:**
- Modify: `src/blar_common.h`
- Modify: `src/blar.c`

**Step 1: Write the failing test**

Create `tests/encryption_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BLAR="./zig-out/bin/blar"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Create test files
mkdir -p "$TMPDIR/src"
echo "hello world" > "$TMPDIR/src/hello.txt"
echo "secret data" > "$TMPDIR/src/secret.txt"

# 1. Create encrypted archive (AES-256-GCM, default)
BLIP_PASSWORD=testpass $BLAR create -e -o "$TMPDIR/enc.blar" "$TMPDIR/src" 2>/dev/null \
    && pass "1. create encrypted archive" \
    || fail "1. create encrypted archive"

# 2. Encrypted file is not a plain archive
$BLAR list "$TMPDIR/enc.blar" 2>/dev/null \
    && fail "2. list without password should fail" \
    || pass "2. list without password should fail"

# 3. List with correct password works
BLIP_PASSWORD=testpass $BLAR list "$TMPDIR/enc.blar" 2>/dev/null \
    && pass "3. list with password" \
    || fail "3. list with password"

# 4. Extract with correct password works
mkdir -p "$TMPDIR/out"
BLIP_PASSWORD=testpass $BLAR extract "$TMPDIR/enc.blar" -C "$TMPDIR/out" 2>/dev/null \
    && pass "4. extract with password" \
    || fail "4. extract with password"

# 5. Extracted content matches original
diff "$TMPDIR/src/hello.txt" "$TMPDIR/out/src/hello.txt" >/dev/null 2>&1 \
    && pass "5. content matches" \
    || fail "5. content matches"

# 6. Wrong password fails
BLIP_PASSWORD=wrongpass $BLAR list "$TMPDIR/enc.blar" 2>/dev/null \
    && fail "6. wrong password should fail" \
    || pass "6. wrong password should fail"

# 7. Verify with password works
BLIP_PASSWORD=testpass $BLAR verify "$TMPDIR/enc.blar" 2>/dev/null \
    && pass "7. verify with password" \
    || fail "7. verify with password"

# 8. Create with ChaCha20
BLIP_PASSWORD=testpass $BLAR create -e chacha -o "$TMPDIR/chacha.blar" "$TMPDIR/src" 2>/dev/null \
    && pass "8. create chacha encrypted" \
    || fail "8. create chacha encrypted"

# 9. ChaCha decrypt works
BLIP_PASSWORD=testpass $BLAR list "$TMPDIR/chacha.blar" 2>/dev/null \
    && pass "9. list chacha with password" \
    || fail "9. list chacha with password"

# 10. Create with PBKDF2
BLIP_PASSWORD=testpass $BLAR create -e aes --kdf pbkdf2 -o "$TMPDIR/pbkdf2.blar" "$TMPDIR/src" 2>/dev/null \
    && pass "10. create with PBKDF2" \
    || fail "10. create with PBKDF2"

# 11. PBKDF2 decrypt works
BLIP_PASSWORD=testpass $BLAR list "$TMPDIR/pbkdf2.blar" 2>/dev/null \
    && pass "11. list PBKDF2 with password" \
    || fail "11. list PBKDF2 with password"

# 12. Encrypted + compressed
BLIP_PASSWORD=testpass $BLAR create -z -e -o "$TMPDIR/comp_enc.blar" "$TMPDIR/src" 2>/dev/null \
    && pass "12. create compressed + encrypted" \
    || fail "12. create compressed + encrypted"

# 13. Compressed + encrypted round-trip
BLIP_PASSWORD=testpass $BLAR list "$TMPDIR/comp_enc.blar" 2>/dev/null \
    && pass "13. list compressed + encrypted" \
    || fail "13. list compressed + encrypted"

# 14. to-json with password
BLIP_PASSWORD=testpass $BLAR to-json "$TMPDIR/enc.blar" 2>/dev/null | head -1 | grep -q '{' \
    && pass "14. to-json with password" \
    || fail "14. to-json with password"

# 15. --help shows encryption options
$BLAR create --help 2>&1 | grep -q '\-e' \
    && pass "15. help shows -e flag" \
    || fail "15. help shows -e flag"

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
```

**Step 2: Run test to verify it fails**

Run: `bash tests/encryption_test.sh 2>&1 | tail -5`
Expected: Most tests fail.

**Step 3: Write minimal implementation**

**`src/blar_common.h`** changes:

Add to `read_archive()` — after decompression check, add encryption check:
```c
/* Check for encrypted LP container (ENC attribute) */
if (blip_is_encrypted(buf, *out_len)) {
    const char *password = getenv("BLIP_PASSWORD");
    if (!password) {
        /* Prompt on stderr so piping still works */
        password = prompt_password("Password: ");
        if (!password) {
            fprintf(stderr, "Password required for encrypted archive\n");
            free(buf);
            return NULL;
        }
    }
    uint8_t *decrypted = NULL;
    size_t dec_len = 0;
    int32_t rc = blip_decrypt_container(buf, *out_len, password, strlen(password),
                                         &decrypted, &dec_len);
    free(buf);
    if (rc != BLIP_OK) {
        if (rc == BLIP_ERR_AUTH_FAILED)
            fprintf(stderr, "Wrong password or corrupted archive\n");
        else
            fprintf(stderr, "Decryption failed: %s\n", blip_error_string(rc));
        return NULL;
    }
    uint8_t *result = (uint8_t *)malloc(dec_len);
    if (!result) { blip_free(decrypted, dec_len); return NULL; }
    memcpy(result, decrypted, dec_len);
    blip_free(decrypted, dec_len);
    *out_len = dec_len;

    /* Decrypted result might be compressed — check again */
    if (blip_is_compressed(result, *out_len)) {
        /* ... existing decompression logic, refactored ... */
    }

    return result;
}
```

Note: `read_archive` currently checks compression first. With encryption, the order on disk is compress-then-encrypt. So on read, we must **decrypt first, then decompress**. Restructure `read_archive` to: check encrypted → decrypt → check compressed → decompress.

Add `prompt_password()` helper:
```c
static const char *prompt_password(const char *prompt) {
    static char pw_buf[256];
    fprintf(stderr, "%s", prompt);
    /* Disable echo if possible */
    struct termios old, new;
    bool tty = (tcgetattr(fileno(stdin), &old) == 0);
    if (tty) {
        new = old;
        new.c_lflag &= ~ECHO;
        tcsetattr(fileno(stdin), TCSANOW, &new);
    }
    if (!fgets(pw_buf, sizeof(pw_buf), stdin)) {
        if (tty) tcsetattr(fileno(stdin), TCSANOW, &old);
        return NULL;
    }
    if (tty) {
        tcsetattr(fileno(stdin), TCSANOW, &old);
        fprintf(stderr, "\n");
    }
    /* Strip trailing newline */
    size_t len = strlen(pw_buf);
    if (len > 0 && pw_buf[len-1] == '\n') pw_buf[--len] = '\0';
    return pw_buf;
}
```

Include `<termios.h>` at the top of `blar_common.h`.

**`src/blar.c`** changes:

In `cmd_create`:
- Add `-e` flag parsing (accepts optional `aes` or `chacha` argument)
- Add `--kdf` flag parsing (accepts `argon2` or `pbkdf2`)
- After archive creation (and optional compression), if `-e` was set:
  - Get password from `BLIP_PASSWORD` env or prompt
  - Call `blip_encrypt_container()`
- Update help text

**Step 4: Run test to verify it passes**

Run: `zig build && bash tests/encryption_test.sh 2>&1 | tail -5`
Expected: All 15 tests pass.

**Step 5: Commit**

```bash
git add src/blar_common.h src/blar.c tests/encryption_test.sh
git commit -m "feat: wire encryption into C CLI (blar create -e, auto-decrypt on read)"
```

---

### Task 6: Run all tests, fix any regressions

**Step 1: Run all Zig tests**

Run: `zig build test 2>&1; echo "EXIT: $?"`
Expected: EXIT: 0

**Step 2: Run all shell tests**

Run: `for t in tests/*_test.sh; do echo "=== $(basename $t) ==="; bash "$t" 2>&1 | grep "Results:"; done`
Expected: All suites pass.

**Step 3: Fix any failures**

If any test fails due to the new `enc_id`/`kdf_id`/`enc_salt`/`enc_nonce` fields on `LPContainerView`, update those tests to initialize the new fields to `null`.

**Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix: address test regressions from encryption attribute"
```

---

### Task 7: Push and verify CI

**Step 1: Push**

```bash
git push
```

**Step 2: Check CI**

```bash
gh run list --limit 1
gh api repos/pmarreck/BLIP/commits/yolo/check-runs --jq '.check_runs[] | {name, conclusion}'
```

Expected: All checks pass.

---

## Key Files Summary

| File | Action | Purpose |
|---|---|---|
| `src/container_types.zig` | MODIFY | Add `EncryptionId`, `KdfId` enums, `enc` sigil, helper functions |
| `src/container.zig` | MODIFY | Add ENC to `LPOptions`, `LPContainerView`, `computeLPLength`, `writeLPHeader`, `parseLPHeader` |
| `src/encryption.zig` | CREATE | Core: `encrypt`, `decrypt`, `encryptContainer`, `decryptContainer`, `isEncrypted`, `deriveKey` |
| `src/blip.zig` | MODIFY | Add `encryption` import |
| `src/lib.zig` | MODIFY | Add `blip_encrypt_container`, `blip_decrypt_container`, `blip_is_encrypted` FFI exports |
| `src/blip.h` | MODIFY | Add FFI declarations, error codes |
| `src/blar_common.h` | MODIFY | Add decrypt-on-read to `read_archive()`, `prompt_password()` |
| `src/blar.c` | MODIFY | Add `-e` and `--kdf` flags to `cmd_create` |
| `tests/encryption_test.sh` | CREATE | Shell integration tests |

## Existing code to reuse

- `src/compression.zig` — exact pattern for `encryptContainer`/`decryptContainer` (mirror this)
- `src/container.zig:85-186` — `computeLPLength`/`writeLPHeader` (add ENC after CSUM, before VAL)
- `src/container.zig:193-308` — `parseLPHeader` (add `.enc` case in switch)
- `src/blar_common.h:105-133` — `read_archive()` (add decrypt layer before decompress)
- `src/blar.c:331-469` — `cmd_create` compression flow (encryption goes after compression)
- `std.crypto.aead.aes_gcm.Aes256Gcm` — Zig stdlib AES-GCM
- `std.crypto.aead.chacha_poly.ChaCha20Poly1305` — Zig stdlib ChaCha20
- `std.crypto.pwhash.argon2` — Zig stdlib Argon2
- `std.crypto.pwhash.pbkdf2` — Zig stdlib PBKDF2
