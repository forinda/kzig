const std = @import("std");
const kzig = @import("kzig");
const FileSettings = @import("../modules/files/file.settings.zig").FileSettings;

const Sha256 = std.crypto.hash.sha2.Sha256;

/// `Authorization: Bearer <API_KEY>` or 401. Compared as digests, so the
/// check takes the same time whatever the key.
pub const ApiKeyGuard = struct {
    settings: *const FileSettings,

    pub fn handle(self: *ApiKeyGuard, ctx: *kzig.Ctx, next: *kzig.Next) !void {
        const header = ctx.header("authorization") orelse "";
        const key = if (std.ascii.startsWithIgnoreCase(header, "Bearer ")) std.mem.trim(u8, header["Bearer ".len..], " ") else "";
        if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest(key), digest(self.settings.api_key)))
            return ctx.fail(.unauthorized, "Invalid API key");
        next.run();
    }
};

fn digest(s: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(s, &out, .{});
    return out;
}
