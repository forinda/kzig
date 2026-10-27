const std = @import("std");
const ChatSettings = @import("chat.settings.zig").ChatSettings;
const Clock = @import("../../clock.zig").Clock;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const ChatUser = struct { name: []const u8 };

/// `<base64url(json {name, exp})>.<hmac>`: ws-chat's tiny signed token, no JWT.
pub const ChatAuth = struct {
    settings: *const ChatSettings,
    clock: *Clock,

    pub const ttl_s = 60 * 60;

    /// Owned by `gpa`.
    pub fn issue(self: *ChatAuth, gpa: std.mem.Allocator, name: []const u8, ttl: i64) ![]const u8 {
        const json = try std.json.Stringify.valueAlloc(gpa, .{ .name = name, .exp = self.clock.now() + ttl }, .{});
        defer gpa.free(json);
        const payload = try gpa.alloc(u8, b64.Encoder.calcSize(json.len));
        defer gpa.free(payload);
        _ = b64.Encoder.encode(payload, json);
        const sig = self.sign(payload);
        return std.mem.concat(gpa, u8, &.{ payload, ".", &sig });
    }

    /// The user, or null for a forged, malformed or expired token.
    pub fn verify(self: *ChatAuth, arena: std.mem.Allocator, token: []const u8) !?ChatUser {
        const dot = std.mem.findScalar(u8, token, '.') orelse return null;
        const payload = token[0..dot];
        const want = self.sign(payload);
        const sig = token[dot + 1 ..];
        if (sig.len != want.len or !std.crypto.timing_safe.eql([want.len]u8, want, sig[0..want.len].*)) return null;
        const json = try arena.alloc(u8, b64.Decoder.calcSizeForSlice(payload) catch return null);
        b64.Decoder.decode(json, payload) catch return null;
        const claims = std.json.parseFromSliceLeaky(struct { name: []const u8, exp: i64 }, arena, json, .{}) catch return null;
        if (claims.exp < self.clock.now()) return null;
        return .{ .name = claims.name };
    }

    fn sign(self: *ChatAuth, payload: []const u8) [b64.Encoder.calcSize(HmacSha256.mac_length)]u8 {
        var mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&mac, payload, self.settings.chat_secret);
        var out: [b64.Encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
        _ = b64.Encoder.encode(&out, &mac);
        return out;
    }
};

/// `Authorization: Bearer <token>`'s token.
pub fn bearer(header: ?[]const u8) ?[]const u8 {
    const h = header orelse return null;
    if (!std.ascii.startsWithIgnoreCase(h, "Bearer ")) return null;
    const t = std.mem.trim(u8, h["Bearer ".len..], " ");
    return if (t.len == 0) null else t;
}
