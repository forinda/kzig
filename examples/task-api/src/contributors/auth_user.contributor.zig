const std = @import("std");
const kzig = @import("kzig");
const auth = @import("../auth.zig");

/// `user`: the caller, from `Authorization: Bearer <token>`; 401 otherwise.
pub const LoadAuthUser = struct {
    pub const key = "user";
    tokens: *auth.TokenStore,

    pub fn resolve(self: *LoadAuthUser, ctx: *kzig.Ctx) !auth.AuthUser {
        const header = ctx.header("authorization") orelse return error.Unauthorized;
        if (!std.mem.startsWith(u8, header, "Bearer ")) return error.Unauthorized;
        return self.tokens.validate(header["Bearer ".len..]) orelse error.Unauthorized;
    }
};
