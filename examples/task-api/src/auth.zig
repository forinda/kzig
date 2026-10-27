//! Bring-your-own auth, in memory: a fixed token table stands in for the
//! archive app's JWT strategy, so the request flow is the same without keys.
const std = @import("std");

pub const AuthUser = struct {
    id: []const u8,
    email: []const u8,
    tenants: []const []const u8,
};

pub const TokenStore = struct {
    const tokens = [_]struct { []const u8, AuthUser }{
        .{ "token-acme", .{ .id = "u-1", .email = "wile@acme.test", .tenants = &.{"acme"} } },
        .{ "token-all", .{ .id = "u-2", .email = "admin@example.test", .tenants = &.{ "acme", "globex" } } },
    };

    pub fn validate(_: *TokenStore, token: []const u8) ?AuthUser {
        for (tokens) |t| if (std.mem.eql(u8, t[0], token)) return t[1];
        return null;
    }
};
