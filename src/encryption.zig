const std = @import("std");
const Allocator = std.mem.Allocator;
const ct = @import("container_types.zig");
const container = @import("container.zig");
const csum_mod = @import("checksum.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;

// Crypto imports
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const argon2_mod = std.crypto.pwhash.argon2;
const pbkdf2_fn = std.crypto.pwhash.pbkdf2;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const EncryptionError = error{
    EncryptionFailed,
    DecryptionFailed,
    AuthenticationFailed,
    PasswordRequired,
    UnsupportedEncryption,
    UnsupportedKdf,
};

pub const EncryptResult = struct {
    ciphertext: []u8, // includes auth tag appended
    salt: [ct.ENC_SALT_LEN]u8,
    nonce: [12]u8,
};

/// Derive a 256-bit key from password + salt using the specified KDF.
pub fn deriveKey(allocator: Allocator, kdf_id: ct.KdfId, password: []const u8, salt: []const u8) (Allocator.Error || EncryptionError)![32]u8 {
    var key: [32]u8 = undefined;
    switch (kdf_id) {
        .argon2id => {
            // Argon2id: m=65536 (64MiB), t=3, p=4
            argon2_mod.kdf(
                allocator,
                &key,
                password,
                salt,
                .{ .t = 3, .m = 65536, .p = 4 },
                .argon2id,
            ) catch return error.EncryptionFailed;
        },
        .pbkdf2_sha256 => {
            // PBKDF2-SHA256: 600,000 rounds
            pbkdf2_fn(&key, password, salt, 600_000, HmacSha256) catch return error.EncryptionFailed;
        },
    }
    return key;
}

/// Encrypt plaintext with the specified cipher and KDF.
/// Returns ciphertext (with appended auth tag), random salt, and random nonce.
pub fn encrypt(allocator: Allocator, enc_id: ct.EncryptionId, kdf_id: ct.KdfId, plaintext: []const u8, password: []const u8) (Allocator.Error || EncryptionError)!EncryptResult {
    // Generate random salt and nonce via OS CSPRNG
    var salt: [ct.ENC_SALT_LEN]u8 = undefined;
    std.crypto.random.bytes(&salt);
    var nonce: [12]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const key = try deriveKey(allocator, kdf_id, password, &salt);

    const tag_len: usize = ct.authTagLength(enc_id);
    const out = try allocator.alloc(u8, plaintext.len + tag_len);
    errdefer allocator.free(out);

    var tag: [16]u8 = undefined;

    switch (enc_id) {
        .aes_256_gcm => {
            Aes256Gcm.encrypt(out[0..plaintext.len], &tag, plaintext, "", nonce, key);
        },
        .chacha20_poly1305 => {
            ChaCha20Poly1305.encrypt(out[0..plaintext.len], &tag, plaintext, "", nonce, key);
        },
    }

    // Append auth tag after ciphertext
    @memcpy(out[plaintext.len..][0..tag_len], tag[0..tag_len]);

    return .{ .ciphertext = out, .salt = salt, .nonce = nonce };
}

/// Decrypt ciphertext (with appended auth tag) using the specified cipher and KDF.
pub fn decrypt(allocator: Allocator, enc_id: ct.EncryptionId, kdf_id: ct.KdfId, ciphertext_with_tag: []const u8, salt: [ct.ENC_SALT_LEN]u8, nonce: [12]u8, password: []const u8) (Allocator.Error || EncryptionError)![]u8 {
    const tag_len: usize = ct.authTagLength(enc_id);
    if (ciphertext_with_tag.len < tag_len) return error.DecryptionFailed;

    const key = try deriveKey(allocator, kdf_id, password, &salt);
    const ct_len = ciphertext_with_tag.len - tag_len;
    const ciphertext = ciphertext_with_tag[0..ct_len];
    const tag: [16]u8 = ciphertext_with_tag[ct_len..][0..16].*;

    const out = try allocator.alloc(u8, ct_len);
    errdefer allocator.free(out);

    switch (enc_id) {
        .aes_256_gcm => {
            Aes256Gcm.decrypt(out, ciphertext, tag, "", nonce, key) catch return error.AuthenticationFailed;
        },
        .chacha20_poly1305 => {
            ChaCha20Poly1305.decrypt(out, ciphertext, tag, "", nonce, key) catch return error.AuthenticationFailed;
        },
    }

    return out;
}

/// Wrap existing serialized container bytes in an encrypted LP DATA container.
/// Produces: [BLIP(total)] [TYPE=data] [CSUM] [ENC=...] [VAL] [ciphertext+tag] [checksum]
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
    const total_usize: usize = @intCast(total);
    const csum_offset = total_usize - csum_len;
    const hash = csum_mod.compute(.blake3_128, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..total_usize], hash[0..csum_len]);

    return buf;
}

/// Decrypt an LP container with ENC attribute.
/// Verifies checksum first, then decrypts and returns the original container bytes.
pub fn decryptContainer(allocator: Allocator, buf: []const u8, password: []const u8) (Allocator.Error || ContainerError || EncryptionError)![]u8 {
    const view = try container.parseLPHeader(buf);

    const enc_id = view.enc_id orelse return error.UnsupportedEncryption;
    const kdf_id = view.kdf_id orelse return error.UnsupportedEncryption;
    const salt = view.enc_salt orelse return error.UnsupportedEncryption;
    const nonce = view.enc_nonce orelse return error.UnsupportedEncryption;

    // Verify checksum if present
    if (view.csum_id) |csum_id| {
        const csum_len: usize = ct.checksumLength(csum_id);
        const total_usize: usize = @intCast(view.total_length);
        const data_to_check = buf[0 .. total_usize - csum_len];
        if (!csum_mod.verify(csum_id, data_to_check, view.checksumSlice())) {
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

// =============================================================================
// Tests
// =============================================================================

test "AES-256-GCM encrypt/decrypt round-trip" {
    const allocator = testing.allocator;
    const plaintext = "Hello, encryption module! This is a test.";
    const password = "test-password-123";

    const result = try encrypt(allocator, .aes_256_gcm, .argon2id, plaintext, password);
    defer allocator.free(result.ciphertext);

    const decrypted = try decrypt(allocator, .aes_256_gcm, .argon2id, result.ciphertext, result.salt, result.nonce, password);
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "ChaCha20-Poly1305 encrypt/decrypt round-trip" {
    const allocator = testing.allocator;
    const plaintext = "ChaCha20 test payload";
    const password = "another-password";

    const result = try encrypt(allocator, .chacha20_poly1305, .pbkdf2_sha256, plaintext, password);
    defer allocator.free(result.ciphertext);

    const decrypted = try decrypt(allocator, .chacha20_poly1305, .pbkdf2_sha256, result.ciphertext, result.salt, result.nonce, password);
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "wrong password returns AuthenticationFailed" {
    const allocator = testing.allocator;
    const plaintext = "secret";
    const password = "correct-password";

    // Use PBKDF2 to keep the test fast (avoids 2x64MiB Argon2 alloc)
    const result = try encrypt(allocator, .aes_256_gcm, .pbkdf2_sha256, plaintext, password);
    defer allocator.free(result.ciphertext);

    const bad = decrypt(allocator, .aes_256_gcm, .pbkdf2_sha256, result.ciphertext, result.salt, result.nonce, "wrong-password");
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

test "encryptContainer with PBKDF2 and ChaCha20" {
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

    const encrypted = try encryptContainer(allocator, .aes_256_gcm, .pbkdf2_sha256, plain, "pass");
    defer allocator.free(encrypted);
    try testing.expect(isEncrypted(encrypted));
}

test "empty plaintext round-trips" {
    const allocator = testing.allocator;
    // Use PBKDF2 for speed
    const result = try encrypt(allocator, .aes_256_gcm, .pbkdf2_sha256, "", "pass");
    defer allocator.free(result.ciphertext);

    const decrypted = try decrypt(allocator, .aes_256_gcm, .pbkdf2_sha256, result.ciphertext, result.salt, result.nonce, "pass");
    defer allocator.free(decrypted);

    try testing.expectEqual(@as(usize, 0), decrypted.len);
}
