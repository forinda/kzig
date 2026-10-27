const kzig = @import("kzig");

/// Add it to a module's `.controllers`.
pub const {{Pascal}}Controller = struct {
    pub const routes = .{
        .{ .method = .GET, .path = "/{{kebab}}", .handler = "index" },
    };

    pub fn index(_: *{{Pascal}}Controller, _: *kzig.Ctx) struct { ok: bool } {
        return .{ .ok = true };
    }
};
