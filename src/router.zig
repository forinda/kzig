//! Route table, matching and the request pipeline. M1 routes are a comptime
//! list; M2 builds the same list from controllers.
const std = @import("std");
const context = @import("context.zig");
const problem = @import("problem.zig");
const mw = @import("middleware.zig");

const Ctx = context.Ctx;
const builtin = @import("builtin");

pub const Handler = *const fn (*Ctx) anyerror!void;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Handler,
    /// Runs around `handler`, after global middleware.
    middleware: []const mw.Fn = &.{},
};

/// A route whose handler returns a value; the value is sent with `Ctx.send`.
/// `f` is `fn (*Ctx) T` or `fn (*Ctx) E!T`.
pub fn route(comptime method: std.http.Method, comptime path: []const u8, comptime f: anytype) Route {
    if (path.len == 0 or path[0] != '/') @compileError("route path must start with '/': \"" ++ path ++ "\"");
    const H = struct {
        fn call(ctx: *Ctx) anyerror!void {
            const result = f(ctx);
            const value = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
            try ctx.send(value);
        }
    };
    return .{ .method = method, .path = path, .handler = H.call };
}

pub const Path = struct {
    /// Decoded segments; a decoded `/` stays inside its segment.
    segments: []const []const u8,
};

/// Splits on `/`, drops empty segments (so `/a/`, `//a` and `/a` are the same
/// route), percent-decodes each segment, and rejects `.` / `..` after
/// decoding so `%2e%2e` can't slip past.
pub fn normalizePath(arena: std.mem.Allocator, raw: []const u8) error{ BadRequest, OutOfMemory }!Path {
    var segments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const seg = try context.percentDecode(arena, part, false);
        // Check every component a decoded `/` or `\\` could split off, so
        // `..%2F..` can't reach a handler that joins params into a file path.
        var parts = std.mem.splitAny(u8, seg, "/\\");
        while (parts.next()) |c| if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return error.BadRequest;
        try segments.append(arena, seg);
    }
    return .{ .segments = segments.items };
}

fn patternSegments(comptime pattern: []const u8) []const []const u8 {
    comptime {
        var list: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, pattern, '/');
        var params = 0;
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (seg[0] == ':' or std.mem.eql(u8, seg, "*")) params += 1;
            list = list ++ .{seg};
        }
        if (params > Ctx.Params.max) @compileError("too many params in route " ++ pattern);
        for (list[0..list.len -| 1]) |seg| if (std.mem.eql(u8, seg, "*")) @compileError("'*' must be the last segment: " ++ pattern);
        const result = list;
        return result;
    }
}

/// `:name` takes one segment; a final `*` takes the rest (possibly none) as param `*`.
fn match(ctx: *Ctx, comptime pattern: []const []const u8, segments: []const []const u8) !bool {
    ctx.params.len = 0;
    inline for (pattern, 0..) |p, i| {
        if (comptime std.mem.eql(u8, p, "*")) {
            ctx.params.names[ctx.params.len] = "*";
            ctx.params.values[ctx.params.len] = try std.mem.join(ctx.arena, "/", segments[@min(i, segments.len)..]);
            ctx.params.len += 1;
            return segments.len >= i;
        }
        if (i >= segments.len) return false;
        if (comptime p[0] == ':') {
            ctx.params.names[ctx.params.len] = p[1..];
            ctx.params.values[ctx.params.len] = segments[i];
            ctx.params.len += 1;
        } else if (!std.mem.eql(u8, p, segments[i])) return false;
    }
    return segments.len == pattern.len;
}

pub fn Router(comptime routes: []const Route) type {
    return struct {
        /// Never fails: every outcome, errors included, becomes a response.
        pub fn handle(_: @This(), ctx: *Ctx) void {
            handleWith(&.{}, ctx);
        }

        /// `handle` inside `global` middleware, which runs for every
        /// request, matched or not (KickJS's `app.use`).
        pub fn handleWith(comptime global: []const mw.Fn, ctx: *Ctx) void {
            var next: mw.Next = .{ .ctx = ctx, .chain = global, .final = dispatch };
            next.run();
            ctx.finish();
        }

        fn dispatch(ctx: *Ctx) !void {
            const path = try normalizePath(ctx.arena, ctx.req.path);
            const method = ctx.req.method;
            if (try run(ctx, method, path)) return;
            // HEAD falls back to GET; the runtime drops the body.
            if (method == .HEAD and try run(ctx, .GET, path)) return;

            var allow: std.ArrayList(u8) = .empty;
            var seen: std.EnumSet(std.http.Method) = .empty;
            inline for (routes) |r| {
                if (!seen.contains(r.method) and try match(ctx, comptime patternSegments(r.path), path.segments)) {
                    seen.insert(r.method);
                    if (allow.items.len > 0) try allow.appendSlice(ctx.arena, ", ");
                    try allow.appendSlice(ctx.arena, @tagName(r.method));
                    if (r.method == .GET and !seen.contains(.HEAD)) {
                        seen.insert(.HEAD);
                        try allow.appendSlice(ctx.arena, ", HEAD");
                    }
                }
            }
            if (allow.items.len == 0) return error.NotFound;
            try ctx.writeProblem(.{ .status = .method_not_allowed });
            try ctx.setHeader("allow", allow.items);
        }

        fn run(ctx: *Ctx, method: std.http.Method, path: Path) !bool {
            inline for (routes) |r| {
                if (r.method == method and try match(ctx, comptime patternSegments(r.path), path.segments)) {
                    if (r.middleware.len == 0) {
                        try r.handler(ctx);
                    } else {
                        var next: mw.Next = .{ .ctx = ctx, .chain = r.middleware, .final = r.handler };
                        next.run();
                    }
                    return true;
                }
            }
            return false;
        }
    };
}

pub fn handleError(ctx: *Ctx, err: anyerror) void {
    const p: ?problem.Problem = if (err == error.HttpProblem)
        ctx.problem
    else if (problem.statusOf(err)) |s|
        .{ .status = s }
    else
        null;
    if (p) |pr| {
        ctx.writeProblem(pr) catch return internalError(ctx, error.OutOfMemory);
        return;
    }
    internalError(ctx, err);
}

/// KickJS's catch-all: plain JSON, the request id for correlating with the
/// log line, and the error name only in Debug builds.
fn internalError(ctx: *Ctx, err: anyerror) void {
    // The test runner fails any test that logs at error level.
    if (!builtin.is_test) std.log.err("{t} {s}: {t}", .{ ctx.req.method, ctx.req.path, err });
    ctx.dropRepresentationHeaders();
    ctx.status(.internal_server_error);
    ctx.json(.{
        .message = "Internal Server Error",
        .requestId = if (ctx.requestId()) |id| (if (std.unicode.utf8ValidateSlice(id)) id else null) else null,
        .@"error" = @as(?[]const u8, if (builtin.mode == .debug) @errorName(err) else null),
    }) catch {
        ctx.res.body = "{\"message\":\"Internal Server Error\"}";
        ctx.res.sent = true;
    };
}

const testing = std.testing;

const TestResult = struct {
    arena: std.heap.ArenaAllocator,
    res: context.Response,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
    fn header(self: *const TestResult, name: []const u8) ?[]const u8 {
        for (self.res.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

fn runTest(comptime R: type, method: std.http.Method, path: []const u8, headers: []const context.Header) TestResult {
    var out: TestResult = .{ .arena = .init(testing.allocator), .res = .{} };
    const req: context.Request = .{ .method = method, .path = path, .query = "", .headers = headers, .body = "" };
    var ctx: Ctx = .{ .arena = out.arena.allocator(), .req = &req, .res = &out.res };
    (R{}).handle(&ctx);
    return out;
}

const T = struct {
    fn hello(_: *Ctx) struct { message: []const u8 } {
        return .{ .message = "hi" };
    }
    fn user(ctx: *Ctx) ![]const u8 {
        return ctx.param("id").?;
    }
    fn createUser(ctx: *Ctx) !void {
        try ctx.created(.{ .id = 1 });
    }
    fn file(ctx: *Ctx) []const u8 {
        return ctx.param("*").?;
    }
    fn conflict(_: *Ctx) !void {
        return error.Conflict;
    }
    fn crash(_: *Ctx) !void {
        return error.Oops;
    }
    fn failing(ctx: *Ctx) !void {
        return ctx.fail(.unprocessable_entity, "bad");
    }
};

const TestRouter = Router(&.{
    route(.GET, "/hello", T.hello),
    route(.GET, "/users/:id", T.user),
    route(.POST, "/users", T.createUser),
    route(.GET, "/files/*", T.file),
    route(.GET, "/conflict", T.conflict),
    route(.GET, "/crash", T.crash),
    route(.GET, "/fail", T.failing),
});

test "matches static and :param" {
    var a = runTest(TestRouter, .GET, "/hello", &.{});
    defer a.deinit();
    try testing.expectEqualStrings("{\"message\":\"hi\"}", a.res.body);

    var b = runTest(TestRouter, .GET, "/users/42", &.{});
    defer b.deinit();
    try testing.expectEqualStrings("42", b.res.body);
}

test "return value is sent as json" {
    var a = runTest(TestRouter, .GET, "/hello", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.ok, a.res.status);
    try testing.expectEqualStrings("application/json", a.header("content-type").?);
}

test "trailing and double slashes match" {
    var a = runTest(TestRouter, .GET, "/hello/", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.ok, a.res.status);
    var b = runTest(TestRouter, .GET, "//hello", &.{});
    defer b.deinit();
    try testing.expectEqual(std.http.Status.ok, b.res.status);
}

test "percent-decoded segment" {
    var a = runTest(TestRouter, .GET, "/users/a%2Fb", &.{});
    defer a.deinit();
    try testing.expectEqualStrings("a/b", a.res.body);
}

test "bad escape and dot segments are 400" {
    for ([_][]const u8{ "/users/%zz", "/users/%4", "/users/../hello", "/./hello", "/users/%2e%2e" }) |p| {
        var a = runTest(TestRouter, .GET, p, &.{});
        defer a.deinit();
        try testing.expectEqual(std.http.Status.bad_request, a.res.status);
        try testing.expectEqualStrings("application/problem+json", a.header("content-type").?);
    }
}

test "404 problem" {
    var a = runTest(TestRouter, .GET, "/nope", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.not_found, a.res.status);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404}", a.res.body);
}

test "405 with Allow" {
    var a = runTest(TestRouter, .DELETE, "/users", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.method_not_allowed, a.res.status);
    try testing.expectEqualStrings("POST", a.header("allow").?);

    var b = runTest(TestRouter, .POST, "/hello", &.{});
    defer b.deinit();
    try testing.expectEqualStrings("GET, HEAD", b.header("allow").?);
}

test "HEAD uses GET route" {
    var a = runTest(TestRouter, .HEAD, "/hello", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.ok, a.res.status);
}

test "wildcard captures rest" {
    var a = runTest(TestRouter, .GET, "/files/a/b/c.txt", &.{});
    defer a.deinit();
    try testing.expectEqualStrings("a/b/c.txt", a.res.body);
}

test "handler error maps to problem" {
    var a = runTest(TestRouter, .GET, "/conflict", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.conflict, a.res.status);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Conflict\",\"status\":409}", a.res.body);

    var b = runTest(TestRouter, .GET, "/fail", &.{});
    defer b.deinit();
    try testing.expectEqual(std.http.Status.unprocessable_entity, b.res.status);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Unprocessable Entity\",\"status\":422,\"detail\":\"bad\"}", b.res.body);
}

test "unknown error is 500 json with requestId" {
    var a = runTest(TestRouter, .GET, "/crash", &.{.{ .name = "x-request-id", .value = "r1" }});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.internal_server_error, a.res.status);
    try testing.expectEqualStrings("application/json", a.header("content-type").?);
    const expected = if (@import("builtin").mode == .debug)
        "{\"message\":\"Internal Server Error\",\"requestId\":\"r1\",\"error\":\"Oops\"}"
    else
        "{\"message\":\"Internal Server Error\",\"requestId\":\"r1\"}";
    try testing.expectEqualStrings(expected, a.res.body);
}

test "encoded slash cannot smuggle dot segments" {
    for ([_][]const u8{ "/files/..%2F..%2Fetc%2Fpasswd", "/users/..%2F", "/users/a%2F.", "/users/..%5Cx" }) |p| {
        var a = runTest(TestRouter, .GET, p, &.{});
        defer a.deinit();
        try testing.expectEqual(std.http.Status.bad_request, a.res.status);
    }
}

test "invalid UTF-8 in the path is 400" {
    var a = runTest(TestRouter, .GET, "/users/%FF%22x", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.bad_request, a.res.status);
}

test "non-UTF-8 request id is left out of the 500 body" {
    var a = runTest(TestRouter, .GET, "/crash", &.{.{ .name = "x-request-id", .value = "\xff\"}" }});
    defer a.deinit();
    try testing.expect(std.mem.indexOf(u8, a.res.body, "requestId") == null);
}
