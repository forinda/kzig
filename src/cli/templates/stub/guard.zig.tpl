const std = @import("std");
const kzig = @import("kzig");

/// Add it to `.middleware` on a route or a controller: a request without
/// `Authorization: Bearer <token>` ends with 401 before the handler runs.
pub fn {{camel}}Guard(ctx: *kzig.Ctx, next: *kzig.Next) !void {
    const header = ctx.header("authorization") orelse "";
    if (!std.mem.startsWith(u8, header, "Bearer ") or header.len == "Bearer ".len)
        return ctx.fail(.unauthorized, "missing or invalid authorization header");
    // Check the token here.
    next.run();
}
