//! Client certificates for TLS (libpq's `sslcert`/`sslkey`): PEM chains and
//! private keys (SEC1 or PKCS#8 EC on P-256/P-384, PKCS#1 or PKCS#8 RSA), and
//! the signature a TLS 1.3 CertificateVerify carries. std reads public keys
//! only; RSA signing here uses std's constant-time `ff` arithmetic.
const std = @import("std");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const EcP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcP384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

pub const SignatureScheme = std.crypto.tls.SignatureScheme;

/// RSA up to 4096 bits.
pub const max_signature_len = 512;

pub const Rsa = struct {
    /// Big-endian, without leading zeros.
    n: []const u8,
    e: []const u8,
    d: []const u8,
};

pub const PrivateKey = union(enum) {
    ec256: EcP256.KeyPair,
    ec384: EcP384.KeyPair,
    rsa: Rsa,

    /// The first private key in `text`; `password` unlocks an encrypted one
    /// (PKCS#8 PBES2, or OpenSSL's `DEK-Info` PEM with AES).
    pub fn parsePem(a: Allocator, text: []const u8, password: ?[]const u8) !PrivateKey {
        if (try pemBlock(a, text, "ENCRYPTED PRIVATE KEY")) |block| {
            const pw = password orelse return error.PasswordRequired;
            const der = try pbes2(block.der, pw);
            // Garbage from a wrong password rarely parses; when it does, it's no key.
            return pkcs8(der) catch error.BadPassword;
        }
        if (try pemBlock(a, text, "EC PRIVATE KEY")) |block| return sec1(try legacyDecrypt(block, password), null) catch |err| wrongIfEncrypted(block, err);
        if (try pemBlock(a, text, "RSA PRIVATE KEY")) |block| return pkcs1(try legacyDecrypt(block, password)) catch |err| wrongIfEncrypted(block, err);
        if (try pemBlock(a, text, "PRIVATE KEY")) |block| return pkcs8(block.der);
        return error.UnsupportedKey;
    }

    /// TLS 1.2: the scheme to sign CertificateVerify with, among those the
    /// server's CertificateRequest lists; null when none fits this key.
    pub fn tls12Scheme(k: PrivateKey, offered: []const u16) ?SignatureScheme {
        const ours: []const SignatureScheme = switch (k) {
            .ec256 => &.{.ecdsa_secp256r1_sha256},
            .ec384 => &.{.ecdsa_secp384r1_sha384},
            .rsa => &.{ .rsa_pss_rsae_sha256, .rsa_pkcs1_sha256 },
        };
        for (ours) |s| for (offered) |o| if (o == @backingInt(s)) return s;
        return null;
    }

    /// A signature over `digest` (SHA-256, or SHA-384 for P-384) with `scheme`.
    pub fn signDigest(k: PrivateKey, io: std.Io, sig_scheme: SignatureScheme, digest: []const u8, out: *[max_signature_len]u8) ![]const u8 {
        switch (k) {
            inline .ec256, .ec384 => |kp, tag| {
                const E = if (tag == .ec256) EcP256 else EcP384;
                if (digest.len != E.Signature.encoded_length / 2) return error.UnsupportedKey;
                var noise: [E.noise_length]u8 = undefined;
                io.random(&noise);
                const sig = try kp.signPrehashed(digest[0 .. E.Signature.encoded_length / 2].*, noise);
                var der: [E.Signature.der_encoded_length_max]u8 = undefined;
                const bytes = sig.toDer(&der);
                @memcpy(out[0..bytes.len], bytes);
                return out[0..bytes.len];
            },
            .rsa => |r| {
                if (digest.len != 32) return error.UnsupportedKey;
                return switch (sig_scheme) {
                    .rsa_pss_rsae_sha256 => rsaPss(io, r, digest[0..32].*, out),
                    .rsa_pkcs1_sha256 => rsaPkcs1(r, digest[0..32].*, out),
                    else => error.UnsupportedKey,
                };
            },
        }
    }

    /// The TLS 1.3 scheme this key signs with.
    pub fn scheme(k: PrivateKey) SignatureScheme {
        return switch (k) {
            .ec256 => .ecdsa_secp256r1_sha256,
            .ec384 => .ecdsa_secp384r1_sha384,
            .rsa => .rsa_pss_rsae_sha256,
        };
    }

    /// `msg` signed for CertificateVerify, into `out`.
    pub fn sign(k: PrivateKey, io: std.Io, msg: []const u8, out: *[max_signature_len]u8) ![]const u8 {
        switch (k) {
            inline .ec256, .ec384 => |kp, tag| {
                const E = if (tag == .ec256) EcP256 else EcP384;
                var noise: [E.noise_length]u8 = undefined;
                io.random(&noise);
                const sig = try kp.sign(msg, noise);
                var der: [E.Signature.der_encoded_length_max]u8 = undefined;
                const bytes = sig.toDer(&der);
                @memcpy(out[0..bytes.len], bytes);
                return out[0..bytes.len];
            },
            .rsa => |r| {
                var m_hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(msg, &m_hash, .{});
                return rsaPss(io, r, m_hash, out);
            },
        }
    }
};

/// RFC 8017 RSASSA-PSS with SHA-256, MGF1-SHA-256 and a 32-byte salt, over
/// the message's SHA-256 `m_hash`.
fn rsaPss(io: std.Io, r: Rsa, m_hash: [32]u8, out: *[max_signature_len]u8) ![]const u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const M = std.crypto.ff.Modulus(max_signature_len * 8);
    const n = try M.fromBytes(r.n, .big);
    const mod_bits = n.bits();
    const k = (mod_bits + 7) / 8;
    const em_bits = mod_bits - 1;
    const em_len = (em_bits + 7) / 8;
    const h_len = Sha256.digest_length;
    const s_len = h_len;
    if (em_len < h_len + s_len + 2 or k > max_signature_len) return error.UnsupportedKey;

    var salt: [s_len]u8 = undefined;
    io.random(&salt);
    var h: [h_len]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&@as([8]u8, @splat(0)));
    hasher.update(&m_hash);
    hasher.update(&salt);
    hasher.final(&h);

    var em_buf: [max_signature_len]u8 = @splat(0);
    const em = em_buf[0..em_len];
    const db_len = em_len - h_len - 1;
    const db = em[0..db_len];
    db[db_len - s_len - 1] = 0x01;
    @memcpy(db[db_len - s_len ..], &salt);
    // MGF1: DB ^= SHA-256(H || counter) blocks.
    var counter: u32 = 0;
    var off: usize = 0;
    while (off < db_len) : (counter += 1) {
        var block: [h_len]u8 = undefined;
        var mg = Sha256.init(.{});
        mg.update(&h);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        mg.update(&c);
        mg.final(&block);
        const take = @min(h_len, db_len - off);
        for (db[off..][0..take], block[0..take]) |*x, y| x.* ^= y;
        off += take;
    }
    db[0] &= @as(u8, 0xff) >> @intCast(8 * em_len - em_bits);
    @memcpy(em[db_len..][0..h_len], &h);
    em[em_len - 1] = 0xbc;

    var padded: [max_signature_len]u8 = @splat(0);
    @memcpy(padded[k - em_len .. k], em);
    defer std.crypto.secureZero(u8, &padded);
    defer std.crypto.secureZero(u8, &em_buf);
    return rsaPrivate(r, padded[0..k], out);
}

/// RFC 8017 RSASSA-PKCS1-v1_5 with SHA-256 (TLS 1.2 servers without PSS).
fn rsaPkcs1(r: Rsa, m_hash: [32]u8, out: *[max_signature_len]u8) ![]const u8 {
    const M = std.crypto.ff.Modulus(max_signature_len * 8);
    const n = try M.fromBytes(r.n, .big);
    const k = (n.bits() + 7) / 8;
    const digest_info = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
    const t_len = digest_info.len + m_hash.len;
    if (k < t_len + 11 or k > max_signature_len) return error.UnsupportedKey;
    var em: [max_signature_len]u8 = undefined;
    em[0] = 0x00;
    em[1] = 0x01;
    @memset(em[2 .. k - t_len - 1], 0xff);
    em[k - t_len - 1] = 0x00;
    @memcpy(em[k - t_len ..][0..digest_info.len], &digest_info);
    @memcpy(em[k - m_hash.len .. k], &m_hash);
    return rsaPrivate(r, em[0..k], out);
}

/// `em`^d mod n, constant-time in d; `em` is as long as the modulus.
fn rsaPrivate(r: Rsa, em: []const u8, out: *[max_signature_len]u8) ![]const u8 {
    const M = std.crypto.ff.Modulus(max_signature_len * 8);
    const n = try M.fromBytes(r.n, .big);
    const x = try M.Fe.fromBytes(n, em, .big);
    const sig = try n.powWithEncodedExponent(x, r.d, .big);
    try sig.toBytes(out[0..em.len], .big);
    return out[0..em.len];
}

/// Each certificate's DER, in the file's order (leaf first).
pub fn parseChain(a: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var rest = text;
    while (true) {
        const begin = "-----BEGIN CERTIFICATE-----";
        const at = std.mem.find(u8, rest, begin) orelse break;
        const block = (try pemBlock(a, rest[at..], "CERTIFICATE")).?;
        try list.append(a, block.der);
        rest = rest[at + begin.len ..];
    }
    if (list.items.len == 0) return error.NoCertificate;
    return list.items;
}

const Block = struct {
    der: []u8,
    /// OpenSSL's traditional encryption: `DEK-Info: AES-256-CBC,<iv>`.
    dek: ?struct { key_len: usize, iv: [16]u8 } = null,
};

/// The first `-----BEGIN <label>-----` block (exactly that label); null
/// when there is none.
fn pemBlock(a: Allocator, text: []const u8, comptime label: []const u8) !?Block {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const start = std.mem.find(u8, text, begin) orelse return null;
    var body_start = start + begin.len;
    const stop = std.mem.findPos(u8, text, body_start, end) orelse return error.InvalidPem;
    var block: Block = .{ .der = &.{} };
    // RFC 1421 headers, up to a blank line.
    if (std.mem.find(u8, text[body_start..stop], "Proc-Type:")) |_| {
        const blank = std.mem.findPos(u8, text, body_start, "\n\n") orelse std.mem.findPos(u8, text, body_start, "\r\n\r\n") orelse return error.InvalidPem;
        var lines = std.mem.tokenizeAny(u8, text[body_start..blank], "\r\n");
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "DEK-Info:")) continue;
            const info = std.mem.trim(u8, line["DEK-Info:".len..], " ");
            const comma = std.mem.findScalar(u8, info, ',') orelse return error.InvalidPem;
            const cipher = info[0..comma];
            const key_len: usize = if (std.mem.eql(u8, cipher, "AES-128-CBC")) 16 else if (std.mem.eql(u8, cipher, "AES-256-CBC")) 32 else return error.UnsupportedKey;
            var iv: [16]u8 = undefined;
            _ = std.fmt.hexToBytes(&iv, info[comma + 1 ..]) catch return error.InvalidPem;
            block.dek = .{ .key_len = key_len, .iv = iv };
        }
        if (block.dek == null) return error.UnsupportedKey;
        body_start = blank;
    }
    var b64: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, b64.items);
        b64.deinit(a);
    }
    for (text[body_start..stop]) |ch| if (!std.ascii.isWhitespace(ch)) try b64.append(a, ch);
    block.der = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(b64.items) catch return error.InvalidPem);
    std.base64.standard.Decoder.decode(block.der, b64.items) catch return error.InvalidPem;
    return block;
}

fn wrongIfEncrypted(block: Block, err: anyerror) anyerror {
    return if (block.dek != null and err != error.PasswordRequired) error.BadPassword else err;
}

/// A traditional PEM block, decrypted in place: OpenSSL's EVP_BytesToKey
/// (MD5, one round, the IV's first 8 bytes as salt), then AES-CBC.
fn legacyDecrypt(block: Block, password: ?[]const u8) ![]const u8 {
    const dek = block.dek orelse return block.der;
    const pw = password orelse return error.PasswordRequired;
    const Md5 = std.crypto.hash.Md5;
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    var prev: [16]u8 = undefined;
    var have: usize = 0;
    while (have < dek.key_len) {
        var h = Md5.init(.{});
        if (have > 0) h.update(&prev);
        h.update(pw);
        h.update(dek.iv[0..8]);
        h.final(&prev);
        const take = @min(16, dek.key_len - have);
        @memcpy(key[have..][0..take], prev[0..take]);
        have += take;
    }
    return cbcDecrypt(block.der, key[0..dek.key_len], dek.iv);
}

/// AES-CBC with PKCS#7 padding, in place; a bad pad is a wrong password.
fn cbcDecrypt(data: []u8, key: []const u8, iv: [16]u8) ![]const u8 {
    if (data.len == 0 or data.len % 16 != 0) return error.BadPassword;
    var chain = iv;
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const block = data[i..][0..16];
        const next_chain = block.*;
        var plain: [16]u8 = undefined;
        switch (key.len) {
            16 => std.crypto.core.aes.Aes128.initDec(key[0..16].*).decrypt(&plain, block),
            32 => std.crypto.core.aes.Aes256.initDec(key[0..32].*).decrypt(&plain, block),
            else => return error.UnsupportedKey,
        }
        for (block, plain, chain) |*o, p, c| o.* = p ^ c;
        chain = next_chain;
    }
    const pad = data[data.len - 1];
    if (pad == 0 or pad > 16) return error.BadPassword;
    for (data[data.len - pad ..]) |b| if (b != pad) return error.BadPassword;
    return data[0 .. data.len - pad];
}

const oid_pbes2 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D };
const oid_pbkdf2 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C };
const oid_hmac_sha1 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x07 };
const oid_hmac_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09 };
const oid_hmac_sha384 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0A };
const oid_hmac_sha512 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0B };
const oid_aes128_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02 };
const oid_aes256_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A };

/// PKCS#8 `EncryptedPrivateKeyInfo` with PBES2 (RFC 8018): PBKDF2 with an
/// HMAC-SHA PRF, AES-CBC. Decrypted in place.
fn pbes2(der: []u8, password: []const u8) ![]const u8 {
    var top: Der = .{ .buf = der };
    var info: Der = .{ .buf = try top.next(0x30) };
    var alg: Der = .{ .buf = try info.next(0x30) };
    if (!std.mem.eql(u8, try alg.next(0x06), &oid_pbes2)) return error.UnsupportedKey;
    var params: Der = .{ .buf = try alg.next(0x30) };
    var kdf: Der = .{ .buf = try params.next(0x30) };
    if (!std.mem.eql(u8, try kdf.next(0x06), &oid_pbkdf2)) return error.UnsupportedKey;
    var kdf_params: Der = .{ .buf = try kdf.next(0x30) };
    const salt = try kdf_params.next(0x04);
    const iter_bytes = try kdf_params.int();
    if (iter_bytes.len > 4) return error.UnsupportedKey;
    var iterations: u32 = 0;
    for (iter_bytes) |b| iterations = (iterations << 8) | b;
    if (iterations == 0 or iterations > 10_000_000) return error.UnsupportedKey;
    if (kdf_params.peek() == 0x02) _ = try kdf_params.int(); // keyLength: the cipher's
    var prf: []const u8 = &oid_hmac_sha1;
    if (kdf_params.peek() == 0x30) {
        var p: Der = .{ .buf = try kdf_params.next(0x30) };
        prf = try p.next(0x06);
    }
    var enc: Der = .{ .buf = try params.next(0x30) };
    const enc_oid = try enc.next(0x06);
    const key_len: usize = if (std.mem.eql(u8, enc_oid, &oid_aes128_cbc)) 16 else if (std.mem.eql(u8, enc_oid, &oid_aes256_cbc)) 32 else return error.UnsupportedKey;
    const iv_bytes = try enc.next(0x04);
    if (iv_bytes.len != 16) return error.InvalidKey;
    const data_const = try info.next(0x04);
    // `der` is ours: decrypt where the ciphertext is.
    const data = der[@intFromPtr(data_const.ptr) - @intFromPtr(der.ptr) ..][0..data_const.len];

    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    const hmac = std.crypto.auth.hmac;
    if (std.mem.eql(u8, prf, &oid_hmac_sha1)) {
        try std.crypto.pwhash.pbkdf2(key[0..key_len], password, salt, iterations, hmac.HmacSha1);
    } else if (std.mem.eql(u8, prf, &oid_hmac_sha256)) {
        try std.crypto.pwhash.pbkdf2(key[0..key_len], password, salt, iterations, hmac.sha2.HmacSha256);
    } else if (std.mem.eql(u8, prf, &oid_hmac_sha384)) {
        try std.crypto.pwhash.pbkdf2(key[0..key_len], password, salt, iterations, hmac.sha2.HmacSha384);
    } else if (std.mem.eql(u8, prf, &oid_hmac_sha512)) {
        try std.crypto.pwhash.pbkdf2(key[0..key_len], password, salt, iterations, hmac.sha2.HmacSha512);
    } else return error.UnsupportedKey;
    return cbcDecrypt(data, key[0..key_len], iv_bytes[0..16].*);
}

/// A minimal DER reader: what private keys need.
const Der = struct {
    buf: []const u8,
    i: usize = 0,

    fn next(d: *Der, tag: u8) ![]const u8 {
        if (d.i + 2 > d.buf.len or d.buf[d.i] != tag) return error.InvalidKey;
        const first = d.buf[d.i + 1];
        var len: usize = first;
        var hdr: usize = 2;
        if (first & 0x80 != 0) {
            const nb = first & 0x7f;
            if (nb == 0 or nb > 4 or d.i + 2 + nb > d.buf.len) return error.InvalidKey;
            len = 0;
            for (d.buf[d.i + 2 ..][0..nb]) |b| len = (len << 8) | b;
            hdr += nb;
        }
        if (d.i + hdr + len > d.buf.len) return error.InvalidKey;
        const content = d.buf[d.i + hdr ..][0..len];
        d.i += hdr + len;
        return content;
    }

    fn peek(d: Der) ?u8 {
        return if (d.i < d.buf.len) d.buf[d.i] else null;
    }

    /// An INTEGER's magnitude without leading zero bytes.
    fn int(d: *Der) ![]const u8 {
        var v = try d.next(0x02);
        while (v.len > 1 and v[0] == 0) v = v[1..];
        return v;
    }
};

const oid_p256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
const oid_p384 = [_]u8{ 0x2B, 0x81, 0x04, 0x00, 0x22 };
const oid_ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
const oid_rsa = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };

/// SEC1 `ECPrivateKey`; the curve from its own [0] or PKCS#8's parameters.
fn sec1(der: []const u8, curve_param: ?[]const u8) !PrivateKey {
    var top: Der = .{ .buf = der };
    var d: Der = .{ .buf = try top.next(0x30) };
    _ = try d.int();
    const secret = try d.next(0x04);
    var curve = curve_param;
    if (d.peek() == 0xA0) {
        var params: Der = .{ .buf = try d.next(0xA0) };
        curve = try params.next(0x06);
    }
    const oid = curve orelse return error.UnsupportedKey;
    if (std.mem.eql(u8, oid, &oid_p256)) return .{ .ec256 = try ecKey(EcP256, secret) };
    if (std.mem.eql(u8, oid, &oid_p384)) return .{ .ec384 = try ecKey(EcP384, secret) };
    return error.UnsupportedKey;
}

fn ecKey(comptime E: type, secret: []const u8) !E.KeyPair {
    var bytes: [E.SecretKey.encoded_length]u8 = @splat(0);
    if (secret.len > bytes.len) return error.InvalidKey;
    @memcpy(bytes[bytes.len - secret.len ..], secret);
    defer std.crypto.secureZero(u8, &bytes);
    return E.KeyPair.fromSecretKey(try E.SecretKey.fromBytes(bytes));
}

/// PKCS#1 `RSAPrivateKey`.
fn pkcs1(der: []const u8) !PrivateKey {
    var top: Der = .{ .buf = der };
    var d: Der = .{ .buf = try top.next(0x30) };
    _ = try d.int();
    const n = try d.int();
    const e = try d.int();
    const priv = try d.int();
    if (n.len > max_signature_len) return error.UnsupportedKey;
    return .{ .rsa = .{ .n = n, .e = e, .d = priv } };
}

/// PKCS#8 `PrivateKeyInfo` around an EC or RSA key.
fn pkcs8(der: []const u8) !PrivateKey {
    var top: Der = .{ .buf = der };
    var d: Der = .{ .buf = try top.next(0x30) };
    _ = try d.int();
    var alg: Der = .{ .buf = try d.next(0x30) };
    const oid = try alg.next(0x06);
    const inner = try d.next(0x04);
    if (std.mem.eql(u8, oid, &oid_rsa)) return pkcs1(inner);
    if (std.mem.eql(u8, oid, &oid_ec_public_key)) return sec1(inner, try alg.next(0x06));
    return error.UnsupportedKey;
}

test "every key format reads, and its signatures verify with its public key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = "TLS 1.3, client CertificateVerify";
    var out: [max_signature_len]u8 = undefined;
    inline for (.{ "ec256-sec1.pem", "ec384-pkcs8.pem", "rsa2048-pkcs1.pem", "rsa2048-pkcs8.pem" }) |file| {
        const key = try PrivateKey.parsePem(a, @embedFile("../testdata/" ++ file), null);
        const sig = try key.sign(testing.io, msg, &out);
        switch (key) {
            .ec256 => |kp| {
                try testing.expectEqual(SignatureScheme.ecdsa_secp256r1_sha256, key.scheme());
                try (try EcP256.Signature.fromDer(sig)).verify(msg, kp.public_key);
            },
            .ec384 => |kp| {
                try testing.expectEqual(SignatureScheme.ecdsa_secp384r1_sha384, key.scheme());
                try (try EcP384.Signature.fromDer(sig)).verify(msg, kp.public_key);
            },
            .rsa => |r| {
                try testing.expectEqual(SignatureScheme.rsa_pss_rsae_sha256, key.scheme());
                const Cert = std.crypto.Certificate;
                const pk = try Cert.rsa.PublicKey.fromBytes(r.e, r.n);
                try testing.expectEqual(256, sig.len);
                try Cert.rsa.PSSSignature.verify(256, sig[0..256], msg, pk, std.crypto.hash.sha2.Sha256);
            },
        }
    }
    try testing.expectError(error.UnsupportedKey, PrivateKey.parsePem(a, @embedFile("../testdata/unrelated-ca.pem"), null));
}

test "a PEM chain gives each certificate's DER in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = @embedFile("../testdata/unrelated-ca.pem");
    const chain = try parseChain(a, one ++ one);
    try testing.expectEqual(2, chain.len);
    try testing.expectEqual(0x30, chain[0][0]);
    try testing.expectEqualSlices(u8, chain[0], chain[1]);
    try testing.expectError(error.NoCertificate, parseChain(a, "no pem here"));
}

test "encrypted keys: PBES2 and OpenSSL's DEK-Info PEM, unlocked with the password" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [max_signature_len]u8 = undefined;
    const msg = "signed";
    inline for (.{
        .{ "ec256-pbes2-sha256.pem", "ec256-sec1.pem" },
        .{ "rsa2048-pbes2-sha1.pem", "rsa2048-pkcs1.pem" },
        .{ "ec384-legacy-aes256.pem", "ec384-pkcs8.pem" },
        .{ "rsa2048-legacy-aes128.pem", "rsa2048-pkcs1.pem" },
    }) |pair| {
        const locked = @embedFile("../testdata/" ++ pair[0]);
        const key = try PrivateKey.parsePem(a, locked, "kzig-test");
        const plain = try PrivateKey.parsePem(a, @embedFile("../testdata/" ++ pair[1]), null);
        // The same key as the unencrypted file.
        switch (key) {
            .ec256 => |kp| try testing.expectEqualSlices(u8, &plain.ec256.secret_key.toBytes(), &kp.secret_key.toBytes()),
            .ec384 => |kp| try testing.expectEqualSlices(u8, &plain.ec384.secret_key.toBytes(), &kp.secret_key.toBytes()),
            .rsa => |r| try testing.expectEqualSlices(u8, plain.rsa.d, r.d),
        }
        _ = try key.sign(testing.io, msg, &out);
        try testing.expectError(error.BadPassword, PrivateKey.parsePem(a, locked, "wrong"));
        try testing.expectError(error.PasswordRequired, PrivateKey.parsePem(a, locked, null));
    }
}

test "TLS 1.2 CertificateVerify signs a digest; the scheme follows what the server takes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [32]u8 = undefined;
    Sha256.hash("handshake messages", &digest, .{});
    var out: [max_signature_len]u8 = undefined;
    const ec = try PrivateKey.parsePem(a, @embedFile("../testdata/ec256-sec1.pem"), null);
    const scheme = ec.tls12Scheme(&.{ @backingInt(SignatureScheme.rsa_pkcs1_sha256), @backingInt(SignatureScheme.ecdsa_secp256r1_sha256) }).?;
    try testing.expectEqual(SignatureScheme.ecdsa_secp256r1_sha256, scheme);
    const sig = try ec.signDigest(testing.io, scheme, &digest, &out);
    try (try EcP256.Signature.fromDer(sig)).verifyPrehashed(digest, ec.ec256.public_key);

    const rsa = try PrivateKey.parsePem(a, @embedFile("../testdata/rsa2048-pkcs1.pem"), null);
    const Cert = std.crypto.Certificate;
    const pk = try Cert.rsa.PublicKey.fromBytes(rsa.rsa.e, rsa.rsa.n);
    // PKCS#1 v1.5 when the server doesn't take PSS.
    const pkcs1_scheme = rsa.tls12Scheme(&.{@backingInt(SignatureScheme.rsa_pkcs1_sha256)}).?;
    try testing.expectEqual(SignatureScheme.rsa_pkcs1_sha256, pkcs1_scheme);
    const s1 = try rsa.signDigest(testing.io, pkcs1_scheme, &digest, &out);
    try Cert.rsa.PKCS1v1_5Signature.verify(256, s1[0..256], "handshake messages", pk, Sha256);
    try testing.expectEqual(null, rsa.tls12Scheme(&.{@backingInt(SignatureScheme.ecdsa_secp256r1_sha256)}));
}
