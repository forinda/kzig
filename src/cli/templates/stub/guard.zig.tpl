const std = @import("std");
const kzig = @import("kzig");

/// Add it to `.middleware` on a route or a controller: a request without
/// `Authorization: Bearer <token>` ends with 401 before the handler runs.
pub fn {{camel}}Guard(ctx: *kzig.Ctx, next: *kzig.Next) !void {
    // The scheme is case-insensitive (RFC 7235).
    const header = ctx.header("authorization") orelse "";
    const token = if (std.ascii.startsWithIgnoreCase(header, "Bearer ")) std.mem.trim(u8, header["Bearer ".len..], " ") else "";
    if (token.len == 0) return ctx.fail(.unauthorized, "missing or invalid authorization header");
    // Check `token` here.
    next.run();
}
