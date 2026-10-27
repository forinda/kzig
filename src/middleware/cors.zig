//! CORS with KickJS's `cors()` semantics: `Vary: Origin` when reflecting an
//! origin, `*` only without credentials, and a 204 preflight answer for
//! `OPTIONS` that never reaches routing.
const std = @import("std");
const Ctx = @import("../context.zig").Ctx;
const mw = @import("../middleware.zig");
const harness = @import("harness.zig");

pub const Origin = union(enum) {
    /// No `Access-Control-Allow-Origin` (KickJS `origin: false`).
    none,
    any,
    one: []const u8,
    list: []const []const u8,
};

pub const Options = struct {
    origin: Origin = .none,
    methods: []const u8 = "GET, HEAD, PUT, PATCH, POST, DELETE",
    /// Null echoes `access-control-request-headers` on preflight.
    allowed_headers: ?[]const u8 = null,
    exposed_headers: ?[]const u8 = null,
    credentials: bool = false,
    max_age: ?u32 = 86400,
    preflight: bool = true,
};

pub fn cors(comptime opts: Options) mw.Fn {
    const max_age: ?[]const u8 = if (opts.max_age) |n| std.fmt.comptimePrint("{d}", .{n}) else null;
    return struct {
        fn handle(ctx: *Ctx, next: *mw.Next) !void {
            const origin = ctx.header("origin");
            if (opts.origin == .any and !opts.credentials) {
                try ctx.setHeader("access-control-allow-origin", "*");
            } else if (origin) |o| if (allowed(o)) {
                try ctx.setHeader("access-control-allow-origin", o);
                try ctx.setHeader("vary", "Origin");
            };
            if (opts.credentials) try ctx.setHeader("access-control-allow-credentials", "true");
            if (opts.exposed_headers) |h| try ctx.setHeader("access-control-expose-headers", h);
            if (opts.preflight and ctx.req.method == .OPTIONS) {
                try ctx.setHeader("access-control-allow-methods", opts.methods);
                if (opts.allowed_headers orelse ctx.header("access-control-request-headers")) |h|
                    try ctx.setHeader("access-control-allow-headers", h);
                if (max_age) |m| try ctx.setHeader("access-control-max-age", m);
                ctx.noContent();
                return;
            }
            next.run();
        }

        fn allowed(o: []const u8) bool {
            return switch (opts.origin) {
                .none => false,
                .any => true,
                .one => |one| std.mem.eql(u8, o, one),
                .list => |list| for (list) |l| {
                    if (std.mem.eql(u8, o, l)) break true;
                } else false,
            };
        }
    }.handle;
}

const testing = std.testing;

const listed = cors(.{ .origin = .{ .list = &.{ "https://a.example", "https://b.example" } }, .credentials = true });

test "cors allows a listed origin with Vary" {
    var a = try harness.request(&.{listed}, .{ .target = "/x", .headers = &.{.{ .name = "origin", .value = "https://b.example" }} });
    defer a.deinit();
    try testing.expectEqualStrings("https://b.example", a.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("Origin", a.header("vary").?);
    try testing.expectEqualStrings("true", a.header("access-control-allow-credentials").?);
}

test "cors ignores others" {
    var a = try harness.request(&.{listed}, .{ .target = "/x", .headers = &.{.{ .name = "origin", .value = "https://evil.example" }} });
    defer a.deinit();
    try testing.expectEqual(null, a.header("access-control-allow-origin"));
    try testing.expectEqualStrings("hi", a.body);
}

test "cors answers preflight 204 for a path without OPTIONS route" {
    var a = try harness.request(&.{listed}, .{ .method = .OPTIONS, .target = "/x", .headers = &.{
        .{ .name = "origin", .value = "https://a.example" },
        .{ .name = "access-control-request-headers", .value = "content-type" },
    } });
    defer a.deinit();
    try testing.expectEqual(std.http.Status.no_content, a.status);
    try testing.expectEqualStrings("GET, HEAD, PUT, PATCH, POST, DELETE", a.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("content-type", a.header("access-control-allow-headers").?);
    try testing.expectEqualStrings("86400", a.header("access-control-max-age").?);
}

test "cors any without credentials sends *" {
    var a = try harness.request(&.{cors(.{ .origin = .any })}, .{ .target = "/x" });
    defer a.deinit();
    try testing.expectEqualStrings("*", a.header("access-control-allow-origin").?);
}

test "cors headers survive an error response" {
    var a = try harness.request(&.{listed}, .{ .target = "/boom", .headers = &.{.{ .name = "origin", .value = "https://a.example" }} });
    defer a.deinit();
    try testing.expectEqual(std.http.Status.conflict, a.status);
    try testing.expectEqualStrings("https://a.example", a.header("access-control-allow-origin").?);
}
