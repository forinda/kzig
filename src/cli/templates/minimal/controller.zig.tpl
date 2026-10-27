const kzig = @import("kzig");

pub const {{Pascal}}Controller = struct {
    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
    };

    pub fn index(_: *{{Pascal}}Controller, _: *kzig.Ctx) struct { message: []const u8 } {
        return .{ .message = "{{Pascal}} works" };
    }
};
