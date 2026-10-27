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

    /// The first private key in `text`.
    pub fn parsePem(a: Allocator, text: []const u8) !PrivateKey {
        if (std.mem.find(u8, text, "-----BEGIN ENCRYPTED PRIVATE KEY-----") != null) return error.EncryptedKey;
        if (try pemBlock(a, text, "EC PRIVATE KEY")) |der| return sec1(der, null);
        if (try pemBlock(a, text, "RSA PRIVATE KEY")) |der| return pkcs1(der);
        if (try pemBlock(a, text, "PRIVATE KEY")) |der| return pkcs8(der);
        return error.UnsupportedKey;
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
            .rsa => |r| return rsaPss(io, r, msg, out),
        }
    }
};

/// RFC 8017 RSASSA-PSS with SHA-256, MGF1-SHA-256 and a 32-byte salt.
fn rsaPss(io: std.Io, r: Rsa, msg: []const u8, out: *[max_signature_len]u8) ![]const u8 {
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

    var m_hash: [h_len]u8 = undefined;
    Sha256.hash(msg, &m_hash, .{});
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

    // s = EM^d mod n, constant-time in d.
    var padded: [max_signature_len]u8 = @splat(0);
    @memcpy(padded[k - em_len .. k], em);
    const x = try M.Fe.fromBytes(n, padded[0..k], .big);
    const sig = try n.powWithEncodedExponent(x, r.d, .big);
    try sig.toBytes(out[0..k], .big);
    std.crypto.secureZero(u8, &padded);
    std.crypto.secureZero(u8, &em_buf);
    return out[0..k];
}

/// Each certificate's DER, in the file's order (leaf first).
pub fn parseChain(a: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var rest = text;
    while (true) {
        const begin = "-----BEGIN CERTIFICATE-----";
        const at = std.mem.find(u8, rest, begin) orelse break;
        const der = (try pemBlock(a, rest[at..], "CERTIFICATE")).?;
        try list.append(a, der);
        rest = rest[at + begin.len ..];
    }
    if (list.items.len == 0) return error.NoCertificate;
    return list.items;
}

/// The first `-----BEGIN <label>-----` block's bytes; null when there is none.
fn pemBlock(a: Allocator, text: []const u8, comptime label: []const u8) !?[]const u8 {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const start = std.mem.find(u8, text, begin) orelse return null;
    const body_start = start + begin.len;
    const stop = std.mem.findPos(u8, text, body_start, end) orelse return error.InvalidPem;
    var b64: std.ArrayList(u8) = .empty;
    for (text[body_start..stop]) |ch| if (!std.ascii.isWhitespace(ch)) try b64.append(a, ch);
    const out = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(b64.items) catch return error.InvalidPem);
    std.base64.standard.Decoder.decode(out, b64.items) catch return error.InvalidPem;
    return out;
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
        const key = try PrivateKey.parsePem(a, @embedFile("../testdata/" ++ file));
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
    try testing.expectError(error.UnsupportedKey, PrivateKey.parsePem(a, @embedFile("../testdata/unrelated-ca.pem")));
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
