//! In-process runtime: drives the full pipeline without a socket, the way
//! KickJS's `createTestApp` drives `app.handle`.
const std = @import("std");
const context = @import("context.zig");
const router = @import("router.zig");

const Ctx = context.Ctx;
const Header = context.Header;

pub const RequestOptions = struct {
    method: std.http.Method = .GET,
    /// Path plus optional `?query`.
    target: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const TestResponse = struct {
    arena: std.heap.ArenaAllocator,
    status: std.http.Status,
    headers: []const Header,
    body: []const u8,

    pub fn deinit(self: *TestResponse) void {
        self.arena.deinit();
    }

    pub fn header(self: *const TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// Parses the body into `T`; unknown fields are ignored.
    pub fn json(self: *TestResponse, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena.allocator(), self.body, .{ .ignore_unknown_fields = true });
    }
};

/// Runs one request through `app.handle` — an `*App`, or a `Router(...)` value.
pub fn request(gpa: std.mem.Allocator, app: anytype, opts: RequestOptions) !TestResponse {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const q = std.mem.indexOfScalar(u8, opts.target, '?');
    const req: context.Request = .{
        .method = opts.method,
        .path = if (q) |i| opts.target[0..i] else opts.target,
        .query = if (q) |i| opts.target[i + 1 ..] else "",
        .headers = opts.headers,
        .body = opts.body,
    };
    var res: context.Response = .{};
    var ctx: Ctx = .{ .arena = arena.allocator(), .req = &req, .res = &res };
    app.handle(&ctx);
    return .{ .arena = arena, .status = res.status, .headers = res.headers.items, .body = res.body };
}

// The shape of kickjs-examples-archive/minimal-api, minus modules (M2).
const Hello = struct {
    fn index(_: *Ctx) struct { message: []const u8 } {
        return .{ .message = "Hello World from kzig!" };
    }
    fn health(_: *Ctx) struct { status: []const u8 } {
        return .{ .status = "ok" };
    }
};

const App = router.Router(&.{
    router.route(.GET, "/api/v1/hello", Hello.index),
    router.route(.GET, "/api/v1/hello/health", Hello.health),
});

test "GET /api/v1/hello returns a greeting" {
    var res = try request(std.testing.allocator, App{}, .{ .target = "/api/v1/hello" });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try std.testing.expectEqualStrings("Hello World from kzig!", body.message);
}

test "GET /api/v1/hello/health reports ok" {
    var res = try request(std.testing.allocator, App{}, .{ .target = "/api/v1/hello/health" });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", (try res.json(struct { status: []const u8 })).status);
}

test "unknown route answers 404 problem details" {
    var res = try request(std.testing.allocator, App{}, .{ .target = "/api/v1/nope" });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expectEqual(404, (try res.json(struct { status: u16 })).status);
    try std.testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
}

test "query string reaches the handler" {
    const Echo = struct {
        fn q(ctx: *Ctx) !?[]const u8 {
            return ctx.query("name");
        }
    };
    const R = router.Router(&.{router.route(.GET, "/echo", Echo.q)});
    var res = try request(std.testing.allocator, R{}, .{ .target = "/echo?name=ada" });
    defer res.deinit();
    try std.testing.expectEqualStrings("\"ada\"", res.body);
}
