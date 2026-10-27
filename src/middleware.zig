//! `next`-style middleware. `Next.run()` turns an error from the rest of the
//! chain into a response before returning, so code after `next.run()` always
//! sees the final status — what KickJS's `res.on('finish')` gives a logger.
const std = @import("std");
const context = @import("context.zig");
const router = @import("router.zig");

const Ctx = context.Ctx;

pub const Fn = *const fn (*Ctx, *Next) anyerror!void;

/// Where an adapter's middleware runs (KickJS phases). `after_routes` runs
/// only for requests no route matched, before the 404/405.
pub const Phase = enum { before_global, after_global, before_routes, after_routes };

/// One per step: each middleware gets its own `Next`, so a second
/// `run()` is a no-op and can't skip past a step that stopped the chain.
pub const Next = struct {
    ctx: *Ctx,
    chain: []const Fn,
    final: *const fn (*Ctx) anyerror!void,
    /// The step this `Next` runs.
    i: usize = 0,
    called: bool = false,

    /// Runs the rest of the chain. Never fails: an error becomes the
    /// response here, as KickJS's error handler would write it.
    pub fn run(self: *Next) void {
        if (self.called) return;
        self.called = true;
        const ctx = self.ctx;
        if (self.i < self.chain.len) {
            var rest: Next = .{ .ctx = ctx, .chain = self.chain, .final = self.final, .i = self.i + 1 };
            self.chain[self.i](ctx, &rest) catch |err| router.handleError(ctx, err);
        } else {
            self.final(ctx) catch |err| router.handleError(ctx, err);
        }
    }
};
const testing = std.testing;
const testing_rt = @import("testing.zig");

pub const requestId = @import("middleware/request_id.zig").requestId;
pub const requestLogger = @import("middleware/request_logger.zig").requestLogger;
pub const cors = @import("middleware/cors.zig").cors;
pub const helmet = @import("middleware/helmet.zig").helmet;

test {
    _ = @import("middleware/request_id.zig");
    _ = @import("middleware/request_logger.zig");
    _ = @import("middleware/cors.zig");
    _ = @import("middleware/helmet.zig");
}

fn trail(ctx: *Ctx, mark: []const u8) !void {
    for (ctx.res.headers.items) |*h| if (std.mem.eql(u8, h.name, "x-trail")) {
        h.value = try std.fmt.allocPrint(ctx.arena, "{s},{s}", .{ h.value, mark });
        return;
    };
    try ctx.res.headers.append(ctx.arena, .{ .name = "x-trail", .value = mark });
}

const M = struct {
    fn global(ctx: *Ctx, next: *Next) !void {
        try trail(ctx, "g");
        next.run();
        try ctx.setHeader("x-seen-status", try std.fmt.allocPrint(ctx.arena, "{d}", .{@backingInt(ctx.res.status)}));
    }
    fn route(ctx: *Ctx, next: *Next) !void {
        try trail(ctx, "r");
        next.run();
    }
    fn block(ctx: *Ctx, _: *Next) !void {
        ctx.status(.forbidden);
        try ctx.text("no");
    }
    fn failAfter(_: *Ctx, next: *Next) !void {
        next.run();
        return error.Conflict;
    }
    fn silent(_: *Ctx, _: *Next) !void {}
    fn guardStatus(ctx: *Ctx, _: *Next) !void {
        ctx.status(.forbidden);
    }
    fn twice(_: *Ctx, next: *Next) !void {
        next.run();
        next.run();
    }
    fn unauthorized(ctx: *Ctx, _: *Next) !void {
        ctx.status(.unauthorized);
        try ctx.text("no");
    }
    fn tail(ctx: *Ctx, next: *Next) !void {
        try ctx.setHeader("x-tail", "ran");
        next.run();
    }

    fn hello(ctx: *Ctx) ![]const u8 {
        try trail(ctx, "h");
        return "hi";
    }
    fn conflict(_: *Ctx) !void {
        return error.Conflict;
    }
};

fn TestApp(comptime global: []const Fn) type {
    return struct {
        const R = router.Router(&.{
            route(router.route(.GET, "/hello", M.hello), &.{M.route}),
            router.route(.GET, "/conflict", M.conflict),
            route(router.route(.GET, "/blocked", M.hello), &.{M.block}),
            route(router.route(.GET, "/late", M.hello), &.{M.failAfter}),
            route(router.route(.GET, "/silent", M.hello), &.{M.silent}),
            route(router.route(.GET, "/guard", M.hello), &.{M.guardStatus}),
            route(router.route(.GET, "/twice", M.hello), &.{ M.twice, M.unauthorized, M.tail }),
        });
        pub fn handle(_: @This(), ctx: *Ctx) void {
            R.handleWith(global, ctx);
        }
    };
}

fn route(r: router.Route, comptime mw: []const Fn) router.Route {
    var out = r;
    out.middleware = mw;
    return out;
}

fn get(comptime global: []const Fn, target: []const u8) !testing_rt.TestResponse {
    return testing_rt.request(testing.allocator, TestApp(global){}, .{ .target = target });
}

test "global middleware wraps every request" {
    var a = try get(&.{M.global}, "/nope");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.not_found, a.status);
    try testing.expectEqualStrings("g", a.header("x-trail").?);
}

test "after next.run the final status is visible" {
    for ([_]struct { []const u8, []const u8 }{ .{ "/nope", "404" }, .{ "/hello", "200" }, .{ "/conflict", "409" } }) |c| {
        var a = try get(&.{M.global}, c[0]);
        defer a.deinit();
        try testing.expectEqualStrings(c[1], a.header("x-seen-status").?);
    }
}

test "route middleware runs after global" {
    var a = try get(&.{M.global}, "/hello");
    defer a.deinit();
    try testing.expectEqualStrings("g,r,h", a.header("x-trail").?);
    try testing.expectEqualStrings("hi", a.body);
}

test "short-circuit skips the handler" {
    var a = try get(&.{}, "/blocked");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.forbidden, a.status);
    try testing.expectEqualStrings("no", a.body);
    try testing.expectEqual(null, a.header("x-trail"));
}

test "error after next.run replaces the response" {
    var a = try get(&.{}, "/late");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.conflict, a.status);
    try testing.expectEqualStrings("application/problem+json", a.header("content-type").?);
    try testing.expect(std.mem.indexOf(u8, a.body, "\"status\":409") != null);
}

test "no next and no response is 204" {
    var a = try get(&.{}, "/silent");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.no_content, a.status);
    try testing.expectEqualStrings("", a.body);
}

test "a status without a body is kept, not turned into 204" {
    var a = try get(&.{}, "/guard");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.forbidden, a.status);
}

test "calling next.run twice can't get past a guard" {
    var a = try get(&.{}, "/twice");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.unauthorized, a.status);
    try testing.expectEqualStrings("no", a.body);
    try testing.expectEqual(null, a.header("x-tail"));
}
