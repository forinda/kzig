//! One line per request after it finished: `GET /x 200 3ms <requestId>`
//! (KickJS `requestLogger()`), on the `.http` log scope.
const std = @import("std");
const Ctx = @import("../context.zig").Ctx;
const mw = @import("../middleware.zig");
const harness = @import("harness.zig");

const log = std.log.scoped(.http);

pub const Options = struct {
    /// Path prefixes not logged, e.g. `"/health"`.
    skip: []const []const u8 = &.{},
};

pub fn requestLogger(comptime opts: Options) mw.Fn {
    return struct {
        fn handle(ctx: *Ctx, next: *mw.Next) !void {
            for (opts.skip) |prefix| if (std.mem.startsWith(u8, ctx.req.path, prefix)) return next.run();
            const start = if (ctx.io) |io| std.Io.Clock.awake.now(io) else null;
            next.run();
            const ms: i64 = if (start) |s| @intCast(@divTrunc(s.durationTo(std.Io.Clock.awake.now(ctx.io.?)).toNanoseconds(), std.time.ns_per_ms)) else 0;
            const q = if (ctx.req.query.len > 0) "?" else "";
            log.info("{t} {s}{s}{s} {d} {d}ms {s}", .{
                ctx.req.method, ctx.req.path, q, ctx.req.query, @backingInt(ctx.res.status), ms, ctx.requestId() orelse "-",
            });
        }
    }.handle;
}

const testing = std.testing;

test "logger passes the response through" {
    var a = try harness.request(&.{requestLogger(.{ .skip = &.{"/health"} })}, .{ .target = "/x" });
    defer a.deinit();
    try testing.expectEqualStrings("hi", a.body);
    var b = try harness.request(&.{requestLogger(.{})}, .{ .target = "/nope" });
    defer b.deinit();
    try testing.expectEqual(std.http.Status.not_found, b.status);
}
