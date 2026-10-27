//! What a handler sees: the request, a buffered response and the request arena.
const std = @import("std");
const problem = @import("problem.zig");
const Allocator = std.mem.Allocator;

pub const Problem = problem.Problem;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Engine-neutral request. Runtimes copy everything into the request arena,
/// so it stays valid for the whole request.
pub const Request = struct {
    method: std.http.Method,
    /// Raw path, before normalisation.
    path: []const u8,
    /// Raw query string, without the `?`.
    query: []const u8,
    headers: []const Header,
    body: []const u8,
};

/// Buffered response; the runtime writes it after the pipeline returns.
pub const Response = struct {
    status: std.http.Status = .ok,
    headers: std.ArrayList(Header) = .empty,
    body: []const u8 = "",
    /// Set once a handler or middleware produced the response.
    sent: bool = false,
};

pub const Ctx = struct {
    arena: Allocator,
    req: *const Request,
    res: *Response,
    params: Params = .{},
    problem: ?Problem = null,
    /// The app handling this request (`*App`), for route thunks.
    app: ?*anyopaque = null,
    /// The route's contributor store while its pipeline runs.
    values: ?*anyopaque = null,
    /// Set by `App.handle`; middleware uses it for clocks and randomness.
    io: ?std.Io = null,
    /// Set by the `requestId` middleware.
    request_id: ?[]const u8 = null,
    /// Told about every error that becomes a response (adapters' `onError`).
    on_error: ?*const fn (*Ctx, anyerror) void = null,

    pub const Params = struct {
        pub const max = 16;
        names: [max][]const u8 = undefined,
        values: [max][]const u8 = undefined,
        len: usize = 0,

        pub fn get(p: *const Params, name: []const u8) ?[]const u8 {
            for (p.names[0..p.len], p.values[0..p.len]) |n, v| if (std.mem.eql(u8, n, name)) return v;
            return null;
        }
    };

    pub fn header(ctx: *const Ctx, name: []const u8) ?[]const u8 {
        for (ctx.req.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn param(ctx: *const Ctx, name: []const u8) ?[]const u8 {
        return ctx.params.get(name);
    }

    /// First value of `name` in the query string, decoded.
    pub fn query(ctx: *const Ctx, name: []const u8) error{ BadRequest, OutOfMemory }!?[]const u8 {
        var it = std.mem.splitScalar(u8, ctx.req.query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.findScalar(u8, pair, '=');
            const key = try percentDecode(ctx.arena, if (eq) |i| pair[0..i] else pair, true);
            if (!std.mem.eql(u8, key, name)) continue;
            return if (eq) |i| try percentDecode(ctx.arena, pair[i + 1 ..], true) else "";
        }
        return null;
    }

    /// Every value of `name` in the query string, decoded, in order.
    pub fn queryAll(ctx: *const Ctx, name: []const u8) error{ BadRequest, OutOfMemory }![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, ctx.req.query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.findScalar(u8, pair, '=');
            const key = try percentDecode(ctx.arena, if (eq) |i| pair[0..i] else pair, true);
            if (!std.mem.eql(u8, key, name)) continue;
            try out.append(ctx.arena, if (eq) |i| try percentDecode(ctx.arena, pair[i + 1 ..], true) else "");
        }
        return out.items;
    }

    /// The id from the `requestId` middleware, else the raw `x-request-id` header.
    pub fn requestId(ctx: *const Ctx) ?[]const u8 {
        return ctx.request_id orelse ctx.header("x-request-id");
    }

    pub fn status(ctx: *Ctx, s: std.http.Status) void {
        ctx.res.status = s;
    }

    /// Sets a header, replacing one with the same name.
    pub fn setHeader(ctx: *Ctx, name: []const u8, value: []const u8) !void {
        for (ctx.res.headers.items) |*h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
            h.value = value;
            return;
        };
        try ctx.res.headers.append(ctx.arena, .{ .name = name, .value = value });
    }

    pub fn json(ctx: *Ctx, value: anytype) !void {
        // `null` fields are sent, as `res.json` does.
        try ctx.writeJson("application/json", value, true);
    }

    /// `json`, leaving out `null` fields: for framework bodies (problem
    /// details, the 500 body) whose absent members are simply missing.
    pub fn jsonOmitNulls(ctx: *Ctx, value: anytype) !void {
        try ctx.writeJson("application/json", value, false);
    }

    pub fn created(ctx: *Ctx, value: anytype) !void {
        ctx.status(.created);
        try ctx.json(value);
    }

    pub fn text(ctx: *Ctx, body: []const u8) !void {
        try ctx.setHeader("content-type", "text/plain; charset=utf-8");
        ctx.res.body = body;
        ctx.res.sent = true;
    }

    pub fn noContent(ctx: *Ctx) void {
        ctx.status(.no_content);
        ctx.res.body = "";
        ctx.res.sent = true;
    }

    /// Marks the response done. Nothing written and no status set → 204; a
    /// status set without a body (a guard's `ctx.status(.forbidden)`) stays.
    pub fn finish(ctx: *Ctx) void {
        if (ctx.res.sent) return;
        if (ctx.res.status == .ok) return ctx.noContent();
        ctx.res.sent = true;
    }

    /// Sends a handler's return value: `void` → 204 unless already sent,
    /// strings → text, `std.http.Status` → that status, a type with
    /// `sendResponse` sends itself, anything else → JSON.
    pub fn send(ctx: *Ctx, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == void) {
            ctx.finish();
        } else if (T == std.http.Status) {
            ctx.status(value);
            ctx.res.sent = true;
        } else if (comptime isString(T)) {
            try ctx.text(value);
        } else if (comptime hasSendResponse(T)) {
            try value.sendResponse(ctx);
        } else {
            try ctx.json(value);
        }
    }

    /// Stores problem details and returns the error that makes the pipeline
    /// answer with them — Zig errors carry no payload.
    pub fn fail(ctx: *Ctx, s: std.http.Status, detail: ?[]const u8) error{HttpProblem} {
        ctx.problem = .{ .status = s, .detail = detail };
        return error.HttpProblem;
    }

    /// Replaces the body with an RFC 9457 problem. Headers already set stay:
    /// CORS and security headers from middleware must reach error responses.
    pub fn writeProblem(ctx: *Ctx, p: Problem) !void {
        ctx.dropRepresentationHeaders();
        ctx.status(p.status);
        try ctx.writeJson("application/problem+json", .{
            .type = "about:blank",
            .title = p.title orelse p.status.phrase() orelse "Error",
            .status = @backingInt(p.status),
            .detail = p.detail,
            .errors = p.errors,
        }, false);
    }

    pub fn removeHeader(ctx: *Ctx, name: []const u8) void {
        var i: usize = 0;
        while (i < ctx.res.headers.items.len) {
            if (std.ascii.eqlIgnoreCase(ctx.res.headers.items[i].name, name)) {
                _ = ctx.res.headers.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Headers describing the body a handler meant to send; wrong for the
    /// error body replacing it (a gzip-encoded or cacheable problem).
    pub fn dropRepresentationHeaders(ctx: *Ctx) void {
        for ([_][]const u8{ "content-length", "content-encoding", "content-disposition", "content-range", "etag", "last-modified", "cache-control" }) |h|
            ctx.removeHeader(h);
    }

    fn writeJson(ctx: *Ctx, content_type: []const u8, value: anytype, emit_nulls: bool) !void {
        ctx.res.body = try std.json.Stringify.valueAlloc(ctx.arena, value, .{ .emit_null_optional_fields = emit_nulls });
        try ctx.setHeader("content-type", content_type);
        ctx.res.sent = true;
    }
};

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn hasSendResponse(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "sendResponse"),
        else => false,
    };
}

/// Strict percent-decoding: a malformed escape is `BadRequest`, not passed through.
/// The result must be UTF-8: JSON-encoding anything else turns a string into
/// an array of numbers, so the client would pick the JSON type of the field.
pub fn percentDecode(arena: Allocator, s: []const u8, plus_as_space: bool) error{ BadRequest, OutOfMemory }![]const u8 {
    const out = try percentDecodeBytes(arena, s, plus_as_space);
    if (!std.unicode.utf8ValidateSlice(out)) return error.BadRequest;
    return out;
}

fn percentDecodeBytes(arena: Allocator, s: []const u8, plus_as_space: bool) error{ BadRequest, OutOfMemory }![]const u8 {
    if (std.mem.findAny(u8, s, if (plus_as_space) "%+" else "%") == null) return s;
    const out = try arena.alloc(u8, s.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) {
        switch (s[i]) {
            '%' => {
                if (i + 2 >= s.len) return error.BadRequest;
                const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.BadRequest;
                const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.BadRequest;
                out[n] = hi << 4 | lo;
                i += 3;
            },
            '+' => {
                out[n] = if (plus_as_space) ' ' else '+';
                i += 1;
            },
            else => |c| {
                out[n] = c;
                i += 1;
            },
        }
    }
    return out[0..n];
}

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    req: Request,
    res: Response = .{},
    ctx: Ctx = undefined,

    fn init(self: *Fixture, req: Request) void {
        self.* = .{ .arena = .init(testing.allocator), .req = req };
        self.ctx = .{ .arena = self.arena.allocator(), .req = &self.req, .res = &self.res };
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
    fn header(self: *Fixture, name: []const u8) ?[]const u8 {
        for (self.res.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

const get_root: Request = .{ .method = .GET, .path = "/", .query = "", .headers = &.{}, .body = "" };

test "json sets content-type and body" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.json(.{ .ok = true });
    try testing.expectEqual(std.http.Status.ok, f.res.status);
    try testing.expectEqualStrings("{\"ok\":true}", f.res.body);
    try testing.expectEqualStrings("application/json", f.header("content-type").?);
    try testing.expect(f.res.sent);
}

test "send void is 204 unless already sent" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.send({});
    try testing.expectEqual(std.http.Status.no_content, f.res.status);

    var g: Fixture = undefined;
    g.init(get_root);
    defer g.deinit();
    try g.ctx.created(.{ .id = 1 });
    try g.ctx.send({});
    try testing.expectEqual(std.http.Status.created, g.res.status);
    try testing.expectEqualStrings("{\"id\":1}", g.res.body);
}

test "send string is text" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.send("hi");
    try testing.expectEqualStrings("hi", f.res.body);
    try testing.expectEqualStrings("text/plain; charset=utf-8", f.header("content-type").?);
}

test "send Status sets status" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.send(std.http.Status.accepted);
    try testing.expectEqual(std.http.Status.accepted, f.res.status);
    try testing.expectEqualStrings("", f.res.body);
}

test "send calls sendResponse" {
    const Custom = struct {
        pub fn sendResponse(_: @This(), ctx: *Ctx) !void {
            ctx.status(.teapot);
            try ctx.text("short and stout");
        }
    };
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.send(Custom{});
    try testing.expectEqual(std.http.Status.teapot, f.res.status);
    try testing.expectEqualStrings("short and stout", f.res.body);
}

test "send struct is json" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.send(.{ .message = "hello" });
    try testing.expectEqualStrings("{\"message\":\"hello\"}", f.res.body);
}

test "fail stores problem and returns HttpProblem" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try testing.expectEqual(error.HttpProblem, f.ctx.fail(.conflict, "taken"));
    try testing.expectEqual(std.http.Status.conflict, f.ctx.problem.?.status);
    try testing.expectEqualStrings("taken", f.ctx.problem.?.detail.?);
}

test "writeProblem body" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    try f.ctx.setHeader("x-stale", "1");
    try f.ctx.writeProblem(.{ .status = .not_found });
    try testing.expectEqual(std.http.Status.not_found, f.res.status);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404}", f.res.body);
    try testing.expectEqualStrings("application/problem+json", f.header("content-type").?);
    try testing.expectEqualStrings("1", f.header("x-stale").?);

    try f.ctx.writeProblem(.{ .status = .conflict, .detail = "taken" });
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Conflict\",\"status\":409,\"detail\":\"taken\"}", f.res.body);
}

test "header lookup is case-insensitive" {
    var f: Fixture = undefined;
    f.init(.{ .method = .GET, .path = "/", .query = "", .headers = &.{.{ .name = "X-Request-Id", .value = "abc" }}, .body = "" });
    defer f.deinit();
    try testing.expectEqualStrings("abc", f.ctx.header("x-request-id").?);
    try testing.expectEqualStrings("abc", f.ctx.requestId().?);
    try testing.expectEqual(null, f.ctx.header("x-other"));
}

test "query decodes + and %20, first match wins" {
    var f: Fixture = undefined;
    f.init(.{ .method = .GET, .path = "/", .query = "q=a+b%20c&q=second&flag&e=", .headers = &.{}, .body = "" });
    defer f.deinit();
    try testing.expectEqualStrings("a b c", (try f.ctx.query("q")).?);
    try testing.expectEqualStrings("", (try f.ctx.query("flag")).?);
    try testing.expectEqualStrings("", (try f.ctx.query("e")).?);
    try testing.expectEqual(null, try f.ctx.query("missing"));
}

test "query with a bad escape is BadRequest" {
    var f: Fixture = undefined;
    f.init(.{ .method = .GET, .path = "/", .query = "x=%zz", .headers = &.{}, .body = "" });
    defer f.deinit();
    try testing.expectError(error.BadRequest, f.ctx.query("x"));
}

test "query with invalid UTF-8 is BadRequest" {
    var f: Fixture = undefined;
    f.init(.{ .method = .GET, .path = "/", .query = "x=%FF", .headers = &.{}, .body = "" });
    defer f.deinit();
    try testing.expectError(error.BadRequest, f.ctx.query("x"));
}

test "send void keeps a status set earlier" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    f.ctx.status(.created);
    try f.ctx.send({});
    try testing.expectEqual(std.http.Status.created, f.res.status);
    try testing.expect(f.res.sent);
}

test "a problem drops representation headers" {
    var f: Fixture = undefined;
    f.init(get_root);
    defer f.deinit();
    for ([_][]const u8{ "content-encoding", "content-disposition", "content-length", "etag", "cache-control", "content-range", "last-modified" }) |h|
        try f.ctx.setHeader(h, "x");
    try f.ctx.setHeader("access-control-allow-origin", "*");
    try f.ctx.writeProblem(.{ .status = .conflict });
    for ([_][]const u8{ "content-encoding", "content-disposition", "content-length", "etag", "cache-control", "content-range", "last-modified" }) |h|
        try testing.expectEqual(null, f.header(h));
    try testing.expectEqualStrings("*", f.header("access-control-allow-origin").?);
}
