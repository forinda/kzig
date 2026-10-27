//! Test harness: one GET/OPTIONS-less route behind the given global middleware.
const std = @import("std");
const Ctx = @import("../context.zig").Ctx;
const router = @import("../router.zig");
const mw = @import("../middleware.zig");
const testing_rt = @import("../testing.zig");

fn hello(_: *Ctx) []const u8 {
    return "hi";
}
fn boom(_: *Ctx) !void {
    return error.Conflict;
}

const R = router.Router(&.{ router.route(.GET, "/x", hello), router.route(.GET, "/boom", boom) });

pub fn App(comptime global: []const mw.Fn) type {
    return struct {
        pub fn handle(_: @This(), ctx: *Ctx) void {
            ctx.io = std.testing.io;
            R.handleWith(global, ctx);
        }
    };
}

pub fn request(comptime global: []const mw.Fn, opts: testing_rt.RequestOptions) !testing_rt.TestResponse {
    return testing_rt.request(std.testing.allocator, App(global){}, opts);
}
