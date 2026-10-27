//! The routes of KickJS's `scripts/benchmark.js` plus minimal-api's hello,
//! served by either runtime: `bench-std` / `bench-httpz`.
const std = @import("std");
const kzig = @import("kzig");
const build_options = @import("build_options");
const runtime = if (build_options.httpz) @import("kzig_httpz") else kzig.runtime.std;

const Greeting = struct { message: []const u8, timestamp: i64 };

const HelloService = struct {
    process: *const kzig.Process,

    fn greet(self: *HelloService, arena: std.mem.Allocator) !Greeting {
        const now = std.Io.Clock.real.now(self.process.io).toNanoseconds();
        return .{ .message = try arena.print("Hello {s} from kzig!", .{"World"}), .timestamp = @intCast(@divTrunc(now, std.time.ns_per_ms)) };
    }
};

const HelloController = struct {
    hello: *HelloService,
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "index" }};
    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !Greeting {
        return self.hello.greet(ctx.arena);
    }
};

const Person = struct {
    name: []const u8,
    email: []const u8,
    age: ?u8 = null,

    pub fn validate(self: *const Person, issues: *kzig.Issues) !void {
        if (self.name.len == 0) try issues.add("name", "must not be empty");
        if (std.mem.findScalar(u8, self.email, '@') == null) try issues.add("email", "must be an email address");
        if (self.age) |a| if (a > 150) try issues.add("age", "must be at most 150");
    }
};

const BenchController = struct {
    pub const routes = .{
        .{ .method = .GET, .path = "/json", .handler = "json" },
        .{ .method = .GET, .path = "/echo/:id", .handler = "echo" },
        .{ .method = .POST, .path = "/validate", .handler = "validate" },
    };
    pub fn json(_: *BenchController, _: *kzig.Ctx) struct { ok: bool } {
        return .{ .ok = true };
    }
    pub fn echo(_: *BenchController, ctx: *kzig.Ctx) struct { id: []const u8 } {
        return .{ .id = ctx.param("id").? };
    }
    pub fn validate(_: *BenchController, _: *kzig.Ctx, got: struct { body: Person }) struct { validated: bool, data: Person } {
        return .{ .validated = true, .data = got.body };
    }
};

const App = kzig.App(.{
    .modules = &.{
        kzig.Module(.{ .name = "HelloModule", .path = "/hello", .controllers = &.{HelloController}, .services = &.{HelloService} }),
        kzig.Module(.{ .name = "BenchModule", .controllers = &.{BenchController} }),
    },
    .config = struct { port: u16 = 4567 },
    .middleware = .{ kzig.middleware.requestId(), kzig.middleware.helmet(.{}) },
});

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    try runtime.serve(App, &app, init.io, init.gpa, .{ .port = app.get(App.Settings).port });
}
