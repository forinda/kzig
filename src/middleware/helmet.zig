//! Security headers with KickJS `helmet()` defaults.
const std = @import("std");
const Ctx = @import("../context.zig").Ctx;
const mw = @import("../middleware.zig");
const harness = @import("harness.zig");

pub const Hsts = struct {
    max_age: u32 = 31536000,
    include_subdomains: bool = true,
    preload: bool = false,
};

/// Null turns a header off.
pub const Options = struct {
    no_sniff: bool = true,
    frameguard: ?[]const u8 = "DENY",
    xss_filter: bool = true,
    referrer_policy: ?[]const u8 = "no-referrer",
    dns_prefetch: bool = false,
    hsts: ?Hsts = .{},
    csp: ?[]const u8 = null,
};

pub fn helmet(comptime opts: Options) mw.Fn {
    const hsts: ?[]const u8 = if (opts.hsts) |h| std.fmt.comptimePrint("max-age={d}{s}{s}", .{
        h.max_age,
        if (h.include_subdomains) "; includeSubDomains" else "",
        if (h.preload) "; preload" else "",
    }) else null;
    return struct {
        fn handle(ctx: *Ctx, next: *mw.Next) !void {
            if (opts.no_sniff) try ctx.setHeader("x-content-type-options", "nosniff");
            if (opts.frameguard) |v| try ctx.setHeader("x-frame-options", v);
            if (opts.xss_filter) try ctx.setHeader("x-xss-protection", "0");
            if (opts.referrer_policy) |v| try ctx.setHeader("referrer-policy", v);
            if (!opts.dns_prefetch) try ctx.setHeader("x-dns-prefetch-control", "off");
            if (hsts) |v| try ctx.setHeader("strict-transport-security", v);
            if (opts.csp) |v| try ctx.setHeader("content-security-policy", v);
            next.run();
        }
    }.handle;
}

const testing = std.testing;

test "helmet sets the defaults" {
    var a = try harness.request(&.{helmet(.{})}, .{ .target = "/x" });
    defer a.deinit();
    try testing.expectEqualStrings("nosniff", a.header("x-content-type-options").?);
    try testing.expectEqualStrings("DENY", a.header("x-frame-options").?);
    try testing.expectEqualStrings("0", a.header("x-xss-protection").?);
    try testing.expectEqualStrings("no-referrer", a.header("referrer-policy").?);
    try testing.expectEqualStrings("off", a.header("x-dns-prefetch-control").?);
    try testing.expectEqualStrings("max-age=31536000; includeSubDomains", a.header("strict-transport-security").?);
    try testing.expectEqual(null, a.header("content-security-policy"));
}

test "helmet options turn headers off and on" {
    var a = try harness.request(&.{helmet(.{ .frameguard = null, .hsts = null, .csp = "default-src 'self'" })}, .{ .target = "/x" });
    defer a.deinit();
    try testing.expectEqual(null, a.header("x-frame-options"));
    try testing.expectEqual(null, a.header("strict-transport-security"));
    try testing.expectEqualStrings("default-src 'self'", a.header("content-security-policy").?);
}
