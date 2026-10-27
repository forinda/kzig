//! DES and Triple DES (EDE, FIPS 46-3 / SP 800-67), only to read private keys
//! OpenSSL encrypted with `-des3` (DES-EDE3-CBC). Not for new encryption.
const std = @import("std");

const ip = [64]u8{ 58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7 };
const fp = [64]u8{ 40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25 };
const e_table = [48]u8{ 32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1 };
const p_table = [32]u8{ 16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25 };
const pc1 = [56]u8{ 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4 };
const pc2 = [48]u8{ 14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32 };
const shifts = [16]u8{ 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 };
const sbox = [8][64]u8{
    .{ 14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13 },
    .{ 15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9 },
    .{ 10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12 },
    .{ 7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14 },
    .{ 2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3 },
    .{ 12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13 },
    .{ 4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12 },
    .{ 13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11 },
};

/// Bit `n` (1-based, from the most significant of `width` bits).
fn permute(in: u64, comptime width: u7, comptime table: []const u8) u64 {
    var out: u64 = 0;
    inline for (table) |pos| out = (out << 1) | ((in >> (width - pos)) & 1);
    return out;
}

pub const Des = struct {
    subkeys: [16]u48,

    pub fn init(key: [8]u8) Des {
        const k = permute(std.mem.readInt(u64, &key, .big), 64, &pc1);
        var c: u28 = @intCast(k >> 28);
        var d: u28 = @truncate(k);
        var out: Des = undefined;
        for (shifts, &out.subkeys) |s, *sk| {
            c = std.math.rotl(u28, c, s);
            d = std.math.rotl(u28, d, s);
            sk.* = @intCast(permute((@as(u64, c) << 28) | d, 56, &pc2));
        }
        return out;
    }

    fn feistel(r: u32, k: u48) u32 {
        const x = permute(r, 32, &e_table) ^ k;
        var out: u32 = 0;
        inline for (0..8) |i| {
            const six: u6 = @truncate(x >> (42 - 6 * i));
            const row = ((six >> 4) & 2) | (six & 1);
            const col = (six >> 1) & 0xf;
            out = (out << 4) | sbox[i][@as(usize, row) * 16 + col];
        }
        return @intCast(permute(out, 32, &p_table));
    }

    fn crypt(d: Des, block: [8]u8, comptime backwards: bool) [8]u8 {
        const x = permute(std.mem.readInt(u64, &block, .big), 64, &ip);
        var l: u32 = @intCast(x >> 32);
        var r: u32 = @truncate(x);
        for (0..16) |i| {
            const k = d.subkeys[if (backwards) 15 - i else i];
            const next = l ^ feistel(r, k);
            l = r;
            r = next;
        }
        var out: [8]u8 = undefined;
        std.mem.writeInt(u64, &out, permute((@as(u64, r) << 32) | l, 64, &fp), .big);
        return out;
    }

    pub fn encrypt(d: Des, block: [8]u8) [8]u8 {
        return d.crypt(block, false);
    }

    pub fn decrypt(d: Des, block: [8]u8) [8]u8 {
        return d.crypt(block, true);
    }
};

/// DES-EDE3: encrypt is E(k3, D(k2, E(k1, x))); decrypt the reverse.
pub const Des3 = struct {
    k1: Des,
    k2: Des,
    k3: Des,

    pub fn init(key: [24]u8) Des3 {
        return .{ .k1 = .init(key[0..8].*), .k2 = .init(key[8..16].*), .k3 = .init(key[16..24].*) };
    }

    pub fn decrypt(t: Des3, block: [8]u8) [8]u8 {
        return t.k1.decrypt(t.k2.encrypt(t.k3.decrypt(block)));
    }
};

test "DES: the classic known-answer vector, both ways" {
    var key: [8]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "133457799BBCDFF1");
    var plain: [8]u8 = undefined;
    _ = try std.fmt.hexToBytes(&plain, "0123456789ABCDEF");
    var want: [8]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "85E813540F0AB405");
    const d: Des = .init(key);
    try std.testing.expectEqualSlices(u8, &want, &d.encrypt(plain));
    try std.testing.expectEqualSlices(u8, &plain, &d.decrypt(want));
    // EDE with three equal keys is single DES.
    const t: Des3 = .init(key ++ key ++ key);
    try std.testing.expectEqualSlices(u8, &plain, &t.decrypt(want));
}
