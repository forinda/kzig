//! Certificate revocation lists (libpq's `sslcrl`): X.509 CRLs, each checked
//! against the CA in `sslrootcert` that signed it, then consulted for every
//! certificate the server presents.
const std = @import("std");
const keys = @import("keys.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

const Der = keys.Der;

pub const Entry = struct {
    /// The issuer's Name, DER, as certificates carry it.
    issuer: []const u8,
    /// Revoked serial numbers, without leading zero bytes.
    serials: []const []const u8,
};

pub const Set = struct {
    entries: []const Entry,

    /// `text`: PEM (`X509 CRL` blocks) or one DER CRL. Each CRL must be
    /// signed by one of `cas` (DER) and not past its nextUpdate.
    pub fn load(a: Allocator, text: []const u8, cas: []const []const u8, now_sec: i64) !Set {
        const crls = if (text.len > 0 and text[0] == 0x30) &[_][]const u8{text} else try pemCrls(a, text);
        if (crls.len == 0) return error.NoCrl;
        return loadDer(a, crls, cas, now_sec);
    }

    pub fn loadDer(a: Allocator, crls: []const []const u8, cas: []const []const u8, now_sec: i64) !Set {
        var entries: std.ArrayList(Entry) = .empty;
        for (crls) |crl| try entries.append(a, try parseVerified(a, crl, cas, now_sec));
        return .{ .entries = entries.items };
    }

    /// The certificate's issuer has a CRL here that lists its serial.
    pub fn revoked(set: Set, cert_der: []const u8) !bool {
        const id = try certId(cert_der);
        for (set.entries) |e| {
            if (!std.mem.eql(u8, e.issuer, id.issuer)) continue;
            for (e.serials) |s| if (std.mem.eql(u8, s, id.serial)) return true;
        }
        return false;
    }
};

pub fn pemCrls(a: Allocator, text: []const u8) ![]const []const u8 {
    return keys.pemAll(a, text, "X509 CRL");
}

const CertId = struct { serial: []const u8, issuer: []const u8, subject: []const u8 };

/// From a certificate's tbsCertificate: serial, issuer and subject Names.
fn certId(cert: []const u8) !CertId {
    var top: Der = .{ .buf = cert };
    var c: Der = .{ .buf = try top.next(0x30) };
    var tbs: Der = .{ .buf = try c.next(0x30) };
    if (tbs.peek() == 0xA0) _ = try tbs.next(0xA0); // version
    const serial = try tbs.int();
    _ = try tbs.next(0x30); // signature algorithm
    const issuer = (try tbs.element(0x30)).raw;
    _ = try tbs.next(0x30); // validity
    const subject = (try tbs.element(0x30)).raw;
    return .{ .serial = serial, .issuer = issuer, .subject = subject };
}

const oid_ecdsa_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 };
const oid_ecdsa_sha384 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03 };
const oid_rsa_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B };
const oid_rsa_sha384 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C };
const oid_rsa_sha512 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D };

fn parseVerified(a: Allocator, crl: []const u8, cas: []const []const u8, now_sec: i64) !Entry {
    var top: Der = .{ .buf = crl };
    var list: Der = .{ .buf = try top.next(0x30) };
    const tbs_el = try list.element(0x30);
    var alg: Der = .{ .buf = try list.next(0x30) };
    const sig_oid = try alg.next(0x06);
    const sig_bits = try list.next(0x03);
    if (sig_bits.len < 1 or sig_bits[0] != 0) return error.InvalidCrl;
    const signature = sig_bits[1..];

    var tbs: Der = .{ .buf = tbs_el.content };
    if (tbs.peek() == 0x02) _ = try tbs.int(); // version
    _ = try tbs.next(0x30); // signature algorithm (again)
    const issuer = (try tbs.element(0x30)).raw;
    _ = try time(&tbs); // thisUpdate
    if (tbs.peek() == 0x17 or tbs.peek() == 0x18) {
        if (try time(&tbs) < now_sec) return error.CrlExpired;
    }
    var serials: std.ArrayList([]const u8) = .empty;
    if (tbs.peek() == 0x30) {
        var revoked_list: Der = .{ .buf = try tbs.next(0x30) };
        while (revoked_list.peek() != null) {
            var entry: Der = .{ .buf = try revoked_list.next(0x30) };
            try serials.append(a, try entry.int());
        }
    }

    // The CA whose subject is this CRL's issuer, and its signature.
    const ca = for (cas) |c| {
        if (std.mem.eql(u8, (try certId(c)).subject, issuer)) break c;
    } else return error.CrlIssuerUnknown;
    try verify(tbs_el.raw, sig_oid, signature, ca);
    return .{ .issuer = issuer, .serials = serials.items };
}

fn verify(msg: []const u8, sig_oid: []const u8, signature: []const u8, ca_der: []const u8) !void {
    const Cert = std.crypto.Certificate;
    const parsed = (Cert{ .buffer = ca_der, .index = 0 }).parse() catch return error.CrlIssuerUnknown;
    const pub_key = parsed.pubKey();
    const sha2 = std.crypto.hash.sha2;
    const ecdsa = std.crypto.sign.ecdsa;
    if (std.mem.eql(u8, sig_oid, &oid_ecdsa_sha256) or std.mem.eql(u8, sig_oid, &oid_ecdsa_sha384)) {
        if (parsed.pub_key_algo != .X9_62_id_ecPublicKey) return error.CrlSignatureInvalid;
        const sha384 = std.mem.eql(u8, sig_oid, &oid_ecdsa_sha384);
        switch (parsed.pub_key_algo.X9_62_id_ecPublicKey) {
            .X9_62_prime256v1 => if (sha384) return error.CrlSignatureInvalid else {
                const E = ecdsa.EcdsaP256Sha256;
                const sig = E.Signature.fromDer(signature) catch return error.CrlSignatureInvalid;
                sig.verify(msg, E.PublicKey.fromSec1(pub_key) catch return error.CrlSignatureInvalid) catch return error.CrlSignatureInvalid;
            },
            .secp384r1 => if (!sha384) return error.CrlSignatureInvalid else {
                const E = ecdsa.EcdsaP384Sha384;
                const sig = E.Signature.fromDer(signature) catch return error.CrlSignatureInvalid;
                sig.verify(msg, E.PublicKey.fromSec1(pub_key) catch return error.CrlSignatureInvalid) catch return error.CrlSignatureInvalid;
            },
            else => return error.UnsupportedCrl,
        }
        return;
    }
    if (!std.mem.eql(u8, sig_oid, &oid_rsa_sha256) and !std.mem.eql(u8, sig_oid, &oid_rsa_sha384) and !std.mem.eql(u8, sig_oid, &oid_rsa_sha512)) return error.UnsupportedCrl;
    if (parsed.pub_key_algo != .rsaEncryption) return error.CrlSignatureInvalid;
    const parts = Cert.rsa.PublicKey.parseDer(pub_key) catch return error.CrlSignatureInvalid;
    const pk = Cert.rsa.PublicKey.fromBytes(parts.exponent, parts.modulus) catch return error.CrlSignatureInvalid;
    inline for (.{ 256, 384, 512 }) |len| if (signature.len == len) {
        const ok = if (std.mem.eql(u8, sig_oid, &oid_rsa_sha256))
            Cert.rsa.PKCS1v1_5Signature.verify(len, signature[0..len], msg, pk, sha2.Sha256)
        else if (std.mem.eql(u8, sig_oid, &oid_rsa_sha384))
            Cert.rsa.PKCS1v1_5Signature.verify(len, signature[0..len], msg, pk, sha2.Sha384)
        else
            Cert.rsa.PKCS1v1_5Signature.verify(len, signature[0..len], msg, pk, sha2.Sha512);
        ok catch return error.CrlSignatureInvalid;
        return;
    };
    return error.UnsupportedCrl;
}

/// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ), as Unix seconds.
fn time(d: *Der) !i64 {
    const tag = d.peek() orelse return error.InvalidCrl;
    const t = try d.next(tag);
    const n: usize = if (tag == 0x17) 13 else if (tag == 0x18) 15 else return error.InvalidCrl;
    if (t.len != n or t[n - 1] != 'Z') return error.InvalidCrl;
    var i: usize = 0;
    const year: i64 = if (tag == 0x17) blk: {
        const yy = try digits(t, &i, 2);
        break :blk if (yy < 50) 2000 + yy else 1900 + yy;
    } else try digits(t, &i, 4);
    const month = try digits(t, &i, 2);
    const day = try digits(t, &i, 2);
    const hour = try digits(t, &i, 2);
    const minute = try digits(t, &i, 2);
    const second = try digits(t, &i, 2);
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return error.InvalidCrl;
    // days_from_civil (Howard Hinnant).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

fn digits(t: []const u8, i: *usize, comptime n: usize) !i64 {
    var v: i64 = 0;
    for (t[i.*..][0..n]) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidCrl;
        v = v * 10 + (c - '0');
    }
    i.* += n;
    return v;
}

fn fixture(comptime name: []const u8) *const [@embedFile("../testdata/crl/" ++ name).len:0]u8 {
    return @embedFile("../testdata/crl/" ++ name);
}

fn der(a: Allocator, comptime name: []const u8) ![]const u8 {
    return (try keys.parseChain(a, fixture(name)))[0];
}

/// 2026-10-27: after the test CRLs were issued, long before they lapse.
const test_now: i64 = 1793102400;

test "CRLs load when their CA signed them, and list what they revoked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cas = [_][]const u8{ try der(a, "ec-ca.pem"), try der(a, "rsa-ca.pem") };
    const set = try Set.load(a, fixture("ec-crl.pem") ++ fixture("rsa-crl.pem"), &cas, test_now);
    try testing.expectEqual(2, set.entries.len);
    try testing.expect(try set.revoked(try der(a, "ec-revoked.pem")));
    try testing.expect(!try set.revoked(try der(a, "ec-good.pem")));
    try testing.expect(try set.revoked(try der(a, "rsa-revoked.pem")));
    // Other issuers' certificates aren't this set's business.
    try testing.expect(!try set.revoked(cas[0]));
}

test "a CRL nobody here signed, a forged one, or a lapsed one is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ec_ca = [_][]const u8{try der(a, "ec-ca.pem")};
    try testing.expectError(error.CrlIssuerUnknown, Set.load(a, fixture("rsa-crl.pem"), &ec_ca, test_now));
    try testing.expectError(error.CrlExpired, Set.load(a, fixture("ec-crl-expired.pem"), &ec_ca, test_now));
    // Flip a bit in the signed part.
    const crl_der = (try pemCrls(a, fixture("ec-crl.pem")))[0];
    const forged = try a.dupe(u8, crl_der);
    forged[forged.len / 2] ^= 1;
    try testing.expectError(error.CrlSignatureInvalid, Set.loadDer(a, &.{forged}, &ec_ca, test_now));
    try testing.expectError(error.NoCrl, Set.load(a, "nothing", &ec_ca, test_now));
}
