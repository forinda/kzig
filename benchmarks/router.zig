//! Route matching alone, no socket: a REST-shaped table of `n` resources
//! (five routes each, KickJS's generated module), matched for the first,
//! middle and last resource and for a miss. `zig build bench-router
//! -Doptimize=ReleaseFast && ./zig-out/bin/bench-router`.
const std = @import("std");
const kzig = @import("kzig");

const resources = 100;

fn ok(_: *kzig.Ctx) void {}

fn table() [resources * 5]kzig.Route {
    @setEvalBranchQuota(1_000_000);
    var out: [resources * 5]kzig.Route = undefined;
    for (0..resources) |i| {
        const base = std.fmt.comptimePrint("/api/v1/res{d}", .{i});
        out[i * 5 + 0] = kzig.route(.GET, base, ok);
        out[i * 5 + 1] = kzig.route(.GET, base ++ "/:id", ok);
        out[i * 5 + 2] = kzig.route(.POST, base, ok);
        out[i * 5 + 3] = kzig.route(.PATCH, base ++ "/:id", ok);
        out[i * 5 + 4] = kzig.route(.DELETE, base ++ "/:id", ok);
    }
    return out;
}

const routes = table();
const R = kzig.Router(&routes);

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout.interface;
    try out.print("{d} routes\n", .{routes.len});
    const cases = [_]struct { name: []const u8, method: std.http.Method, path: []const u8 }{
        .{ .name = "first", .method = .GET, .path = "/api/v1/res0/42" },
        .{ .name = "middle", .method = .PATCH, .path = "/api/v1/res50/42" },
        .{ .name = "last", .method = .DELETE, .path = "/api/v1/res99/42" },
        .{ .name = "miss (404)", .method = .GET, .path = "/api/v1/nope/42" },
    };
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    for (cases) |c| {
        const n = 200_000;
        const t0 = std.Io.Clock.awake.now(init.io);
        for (0..n) |_| {
            _ = arena.reset(.retain_capacity);
            const req: kzig.Request = .{ .method = c.method, .path = c.path, .query = "", .headers = &.{}, .body = "" };
            var res: kzig.Response = .{};
            var ctx: kzig.Ctx = .{ .arena = arena.allocator(), .req = &req, .res = &res };
            (R{}).handle(&ctx);
            std.mem.doNotOptimizeAway(&res);
        }
        const ns = t0.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
        try out.print("{s:<12} {d:>7} ns/request\n", .{ c.name, @as(u64, @intCast(@divTrunc(ns, n))) });
    }
    try out.flush();
}
