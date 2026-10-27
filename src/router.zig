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
    /// `Controller.handler`, for adapters' `onRouteMount`.
    name: []const u8 = "",
    /// Its OpenAPI part, for adapters (swagger).
    doc: ?*const @import("openapi.zig").RouteDoc = null,
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
        @setEvalBranchQuota(1_000_000);
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

/// The route table as a segment tree, built at comptime: a node per path
/// prefix, its static children, one `:param` child, routes ending there and
/// `*` routes. Matching walks only the branches that fit the path and keeps
/// the lowest-index route that matches, so precedence is still declaration
/// order (KickJS/Express); `min` prunes branches that can't beat it.
const Node = struct {
    /// Sorted by segment, for a binary search.
    statics: []const Edge = &.{},
    param: ?u32 = null,
    /// Routes ending here, ascending.
    ends: []const u32 = &.{},
    /// Routes whose final `*` starts here, ascending.
    rest: []const u32 = &.{},
    /// The lowest route index in this subtree.
    min: u32 = std.math.maxInt(u32),
};

const Edge = struct { seg: []const u8, node: u32 };

fn buildTree(comptime routes: []const Route) []const Node {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var cap: usize = 1;
        for (routes) |r| cap += patternSegments(r.path).len;
        var nodes: [cap]Node = undefined;
        nodes[0] = .{};
        var count: u32 = 1;
        for (routes, 0..) |r, ri_usize| {
            const ri: u32 = ri_usize;
            var n: u32 = 0;
            nodes[0].min = @min(nodes[0].min, ri);
            var wildcard = false;
            for (patternSegments(r.path)) |p| {
                if (std.mem.eql(u8, p, "*")) {
                    nodes[n].rest = nodes[n].rest ++ .{ri};
                    wildcard = true;
                    break;
                }
                if (p[0] == ':') {
                    if (nodes[n].param == null) {
                        nodes[count] = .{};
                        nodes[n].param = count;
                        count += 1;
                    }
                    n = nodes[n].param.?;
                } else {
                    const child = for (nodes[n].statics) |e| {
                        if (std.mem.eql(u8, e.seg, p)) break e.node;
                    } else blk: {
                        nodes[count] = .{};
                        nodes[n].statics = nodes[n].statics ++ .{Edge{ .seg = p, .node = count }};
                        count += 1;
                        break :blk count - 1;
                    };
                    n = child;
                }
                nodes[n].min = @min(nodes[n].min, ri);
            }
            if (!wildcard) nodes[n].ends = nodes[n].ends ++ .{ri};
        }
        for (nodes[0..count]) |*node| {
            var sorted = node.statics[0..node.statics.len].*;
            std.mem.sort(Edge, &sorted, {}, edgeLess);
            const frozen = sorted;
            node.statics = &frozen;
        }
        const final = nodes[0..count].*;
        return &final;
    }
}

fn edgeLess(_: void, a: Edge, b: Edge) bool {
    return std.mem.order(u8, a.seg, b.seg) == .lt;
}

fn staticChild(node: *const Node, seg: []const u8) ?u32 {
    var lo: usize = 0;
    var hi: usize = node.statics.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, node.statics[mid].seg, seg)) {
            .eq => return node.statics[mid].node,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// The lowest-index route for `method` matching `segments`, from node `n`
/// at segment `i`.
fn findIn(nodes: []const Node, methods: []const std.http.Method, n: u32, segments: []const []const u8, i: usize, method: std.http.Method, best: *?u32) void {
    const node = &nodes[n];
    if (best.*) |b| if (node.min >= b) return;
    for (node.rest) |ri| if (methods[ri] == method) {
        if (best.* == null or ri < best.*.?) best.* = ri;
        break;
    };
    if (i == segments.len) {
        for (node.ends) |ri| if (methods[ri] == method) {
            if (best.* == null or ri < best.*.?) best.* = ri;
            break;
        };
        return;
    }
    if (staticChild(node, segments[i])) |c| findIn(nodes, methods, c, segments, i + 1, method, best);
    if (node.param) |p| findIn(nodes, methods, p, segments, i + 1, method, best);
}

/// Every route matching `segments`, any method (for 405's `Allow`).
fn collectIn(nodes: []const Node, n: u32, segments: []const []const u8, i: usize, arena: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
    const node = &nodes[n];
    try out.appendSlice(arena, node.rest);
    if (i == segments.len) return out.appendSlice(arena, node.ends);
    if (staticChild(node, segments[i])) |c| try collectIn(nodes, c, segments, i + 1, arena, out);
    if (node.param) |p| try collectIn(nodes, p, segments, i + 1, arena, out);
}

pub fn Router(comptime routes: []const Route) type {
    const tree = buildTree(routes);
    const methods = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var m: [routes.len]std.http.Method = undefined;
        for (routes, &m) |r, *o| o.* = r.method;
        break :blk m;
    };
    return struct {
        /// Never fails: every outcome, errors included, becomes a response.
        pub fn handle(_: @This(), ctx: *Ctx) void {
            handleWith(&.{}, ctx);
        }

        /// `handle` inside `global` middleware, which runs for every
        /// request, matched or not (KickJS's `app.use`).
        pub fn handleWith(comptime global: []const mw.Fn, ctx: *Ctx) void {
            handlePhases(global, &.{}, ctx);
        }

        /// `handleWith`, plus `after_routes` middleware that runs only when
        /// no route matched, before the 404/405 answer.
        pub fn handlePhases(comptime global: []const mw.Fn, comptime after_routes: []const mw.Fn, ctx: *Ctx) void {
            var next: mw.Next = .{ .ctx = ctx, .chain = global, .final = Dispatch(after_routes).run };
            next.run();
            ctx.finish();
        }

        fn Dispatch(comptime after_routes: []const mw.Fn) type {
            return struct {
                fn run(ctx: *Ctx) !void {
                    const path = try normalizePath(ctx.arena, ctx.req.path);
                    const method = ctx.req.method;
                    if (try runRoute(ctx, method, path)) return;
                    // HEAD falls back to GET; the runtime drops the body.
                    if (method == .HEAD and try runRoute(ctx, .GET, path)) return;
                    if (after_routes.len == 0) return unmatched(ctx);
                    var next: mw.Next = .{ .ctx = ctx, .chain = after_routes, .final = unmatched };
                    next.run();
                }
            };
        }

        fn unmatched(ctx: *Ctx) !void {
            const path = try normalizePath(ctx.arena, ctx.req.path);
            var matched: std.ArrayList(u32) = .empty;
            if (routes.len > 0) try collectIn(tree, 0, path.segments, 0, ctx.arena, &matched);
            if (matched.items.len == 0) return error.NotFound;
            // In declaration order, as the routes were listed.
            std.mem.sort(u32, matched.items, {}, std.sort.asc(u32));
            var allow: std.ArrayList(u8) = .empty;
            var seen: std.EnumSet(std.http.Method) = .empty;
            for (matched.items) |ri| {
                const m = methods[ri];
                if (seen.contains(m)) continue;
                seen.insert(m);
                if (allow.items.len > 0) try allow.appendSlice(ctx.arena, ", ");
                try allow.appendSlice(ctx.arena, @tagName(m));
                if (m == .GET and !seen.contains(.HEAD)) {
                    seen.insert(.HEAD);
                    try allow.appendSlice(ctx.arena, ", HEAD");
                }
            }
            try ctx.writeProblem(.{ .status = .method_not_allowed });
            try ctx.setHeader("allow", allow.items);
        }

        fn runRoute(ctx: *Ctx, method: std.http.Method, path: Path) !bool {
            if (routes.len == 0) return false;
            var best: ?u32 = null;
            findIn(tree, &methods, 0, path.segments, 0, method, &best);
            const ri = best orelse return false;
            try runners[ri](ctx, path.segments);
            return true;
        }

        /// Per route: its params from the path, then its middleware and handler.
        const runners = blk: {
            @setEvalBranchQuota(1_000_000);
            var out: [routes.len]*const fn (*Ctx, []const []const u8) anyerror!void = undefined;
            for (routes, &out) |r, *o| o.* = Runner(r).run;
            break :blk out;
        };

        fn Runner(comptime r: Route) type {
            return struct {
                fn run(ctx: *Ctx, segments: []const []const u8) anyerror!void {
                    // The tree matched it; this fills its params.
                    const fits = try match(ctx, comptime patternSegments(r.path), segments);
                    std.debug.assert(fits);
                    if (r.middleware.len == 0) return r.handler(ctx);
                    var next: mw.Next = .{ .ctx = ctx, .chain = r.middleware, .final = r.handler };
                    next.run();
                }
            };
        }
    };
}

pub fn handleError(ctx: *Ctx, err: anyerror) void {
    if (ctx.on_error) |observe| observe(ctx, err);
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
    ctx.jsonOmitNulls(.{
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
    try testing.expect(std.mem.find(u8, a.res.body, "requestId") == null);
}

fn manyRoutes(comptime count: usize) []const Route {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const Route = &.{};
        for (0..count) |i| out = out ++ .{route(.GET, std.fmt.comptimePrint("/r{d}/:id/items/:item", .{i}), T.hello)};
        const result = out;
        return result;
    }
}

test "a large route table stays within the compile-time branch quota" {
    const Big = Router(manyRoutes(60));
    var a = runTest(Big, .GET, "/r59/1/items/2", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.ok, a.res.status);
}

fn nothing(_: *Ctx) void {}

/// Declaration order decides, so the traps: a param before a static, a
/// wildcard before a specific route, the same shape under several methods.
const tricky = [_]Route{
    route(.GET, "/users/:id", nothing),
    route(.GET, "/users/me", nothing),
    route(.GET, "/users/:id/posts", nothing),
    route(.POST, "/users", nothing),
    route(.GET, "/files/*", nothing),
    route(.GET, "/files/special", nothing),
    route(.DELETE, "/users/:id", nothing),
    route(.GET, "/:any/x", nothing),
    route(.PUT, "/a/b/c", nothing),
    route(.GET, "/a/:b/c", nothing),
    route(.GET, "/a/b/:c", nothing),
    route(.GET, "/", nothing),
    route(.PATCH, "/*", nothing),
    route(.GET, "/me/:a/:b", nothing),
};

/// The matcher the tree replaced: the first route, in order, that fits.
fn linearFirst(ctx: *Ctx, method: ?std.http.Method, segments: []const []const u8, start: usize) !?usize {
    inline for (tricky, 0..) |r, i| {
        if (i >= start and (method == null or r.method == method.?) and try match(ctx, comptime patternSegments(r.path), segments)) return i;
    }
    return null;
}

test "the tree picks what the linear scan picked, for every path and method" {
    const tree = comptime buildTree(&tricky);
    const methods = comptime blk: {
        var m: [tricky.len]std.http.Method = undefined;
        for (&tricky, &m) |r, *o| o.* = r.method;
        break :blk m;
    };
    const words = [_][]const u8{ "users", "me", "1", "posts", "files", "special", "a", "b", "c", "x" };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: context.Request = .{ .method = .GET, .path = "/", .query = "", .headers = &.{}, .body = "" };
    var res: context.Response = .{};
    var ctx: Ctx = .{ .arena = arena.allocator(), .req = &req, .res = &res };
    var segs: [4][]const u8 = undefined;
    var checked: usize = 0;
    for (0..5) |len| {
        var combo: [4]usize = @splat(0);
        while (true) {
            for (0..len) |k| segs[k] = words[combo[k]];
            const path = segs[0..len];
            for ([_]std.http.Method{ .GET, .POST, .PUT, .DELETE, .PATCH }) |m| {
                var best: ?u32 = null;
                findIn(tree, &methods, 0, path, 0, m, &best);
                const want = try linearFirst(&ctx, m, path, 0);
                try testing.expectEqual(want, if (best) |b| @as(usize, b) else null);
            }
            // Allow: the same set of matching routes.
            var got: std.ArrayList(u32) = .empty;
            try collectIn(tree, 0, path, 0, arena.allocator(), &got);
            var count: usize = 0;
            var from: usize = 0;
            while (try linearFirst(&ctx, null, path, from)) |i| : (from = i + 1) {
                count += 1;
                try testing.expect(std.mem.findScalar(u32, got.items, @intCast(i)) != null);
            }
            try testing.expectEqual(count, got.items.len);
            checked += 1;
            // Next combination of `len` words.
            var k: usize = 0;
            while (k < len) : (k += 1) {
                combo[k] += 1;
                if (combo[k] < words.len) break;
                combo[k] = 0;
            }
            if (k == len) break;
        }
    }
    try testing.expectEqual(1 + 10 + 100 + 1000 + 10000, checked);
}

fn bigTable(comptime n: usize) [n]Route {
    @setEvalBranchQuota(1_000_000);
    var out: [n]Route = undefined;
    for (&out, 0..) |*r, i| r.* = route(.GET, std.fmt.comptimePrint("/r{d}/:id", .{i}), nothing);
    return out;
}

test "a 600-route table compiles and matches its last route" {
    const routes = comptime bigTable(600);
    const R = Router(&routes);
    var res = runTest(R, .GET, "/r599/7", &.{});
    defer res.deinit();
    try testing.expectEqual(.no_content, res.res.status);
}
