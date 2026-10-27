//! Adapters: lifecycle plugins with KickJS's hooks. An adapter is a service
//! struct listed in `App(.{ .adapters })`; every hook is optional:
//!
//!   beforeMount(self) !void        after services are built; error aborts boot
//!   onRouteMount(self, RouteInfo)  once per route
//!   beforeStart(self) !void        last step of boot; error aborts boot
//!   afterStart(self, StartInfo)    the server is listening
//!   onError(self, *Ctx, anyerror)  an error became a response
//!   onResponse(self, *Ctx)         a response is ready
//!   onHealthCheck(self) HealthCheck  part of /health/ready
//!   shutdown(self)                 reverse dependency order, before deinit
//!
//! `pub const depends_on = .{Other}` orders them; `pub const middleware`,
//! `contributors` and `settings` add to the app.
const std = @import("std");

pub const StartInfo = struct {
    port: u16,
};

pub const RouteInfo = struct {
    method: std.http.Method,
    path: []const u8,
    handler: []const u8,
};

/// `adapters` with each one after the adapters it `depends_on`.
pub fn order(comptime adapters: []const type) []const type {
    comptime {
        const Walk = struct {
            state: [adapters.len]enum { new, active, done } = @splat(.new),
            out: []const type = &.{},
            path: []const u8 = "",

            fn visit(w: *@This(), i: usize) void {
                const A = adapters[i];
                switch (w.state[i]) {
                    .done => return,
                    .active => @compileError("adapter cycle: " ++ w.path ++ @typeName(A)),
                    .new => {},
                }
                w.state[i] = .active;
                const saved = w.path;
                w.path = w.path ++ @typeName(A) ++ " -> ";
                if (@hasDecl(A, "depends_on")) for (A.depends_on) |D| {
                    const j = for (adapters, 0..) |B, k| {
                        if (B == D) break k;
                    } else @compileError(@typeName(A) ++ " depends on " ++ @typeName(D) ++ ", which is not an adapter of this app");
                    w.visit(j);
                };
                w.path = saved;
                w.state[i] = .done;
                w.out = w.out ++ .{A};
            }
        };
        var w: Walk = .{};
        for (0..adapters.len) |i| w.visit(i);
        const result = w.out;
        return result;
    }
}

const testing = std.testing;
const app = @import("app.zig");

const Trail = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    fail: ?[]const u8 = null,

    fn add(self: *Trail, comptime fmt: []const u8, args: anytype) void {
        if (self.len > 0) self.append(", ");
        var tmp: [128]u8 = undefined;
        self.append(std.fmt.bufPrint(&tmp, fmt, args) catch unreachable);
    }
    fn append(self: *Trail, s: []const u8) void {
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }
    fn items(self: *const Trail) []const u8 {
        return self.buf[0..self.len];
    }
    fn failing(self: *const Trail, what: []const u8) bool {
        return if (self.fail) |f| std.mem.eql(u8, f, what) else false;
    }
};

const Pool = struct {
    trail: *Trail,
    pub fn init(self: *Pool) void {
        self.trail.add("init:pool", .{});
    }
    pub fn deinit(self: *Pool) void {
        self.trail.add("deinit:pool", .{});
    }
};

fn TestAdapter(comptime name: []const u8, comptime deps: anytype) type {
    return struct {
        const Self = @This();
        pub const depends_on = deps;
        trail: *Trail,
        pool: *Pool,

        pub fn beforeMount(self: *Self) !void {
            self.trail.add("mount:" ++ name, .{});
            if (self.trail.failing("mount:" ++ name)) return error.Boom;
        }
        pub fn onRouteMount(self: *Self, r: RouteInfo) void {
            self.trail.add("route:" ++ name ++ ":{s}", .{r.path});
        }
        pub fn beforeStart(self: *Self) !void {
            self.trail.add("start:" ++ name, .{});
        }
        pub fn afterStart(self: *Self, info: StartInfo) void {
            self.trail.add("after:" ++ name ++ ":{d}", .{info.port});
        }
        pub fn shutdown(self: *Self) void {
            self.trail.add("shutdown:" ++ name, .{});
        }
    };
}

const DbAdapter = TestAdapter("db", .{});
const CacheAdapter = TestAdapter("cache", .{DbAdapter});
const QueueAdapter = TestAdapter("queue", .{CacheAdapter});

const X = struct {
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "x" }};
    pub fn x(_: *X, _: *@import("context.zig").Ctx) void {}
};

fn TestApp(comptime adapters: []const type) type {
    return app.App(.{
        .modules = &.{app.Module(.{ .name = "X", .path = "/x", .controllers = &.{X}, .services = &.{ Pool, Trail } })},
        .adapters = adapters,
        .health = false,
    });
}

fn bootWith(comptime A: type, a: *A, trail: Trail) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try a.initWith(testing.io, testing.allocator, &env, .{trail});
}

test "hooks run in KickJS order" {
    const A = TestApp(&.{ CacheAdapter, DbAdapter });
    var a: A = undefined;
    try bootWith(A, &a, .{});
    a.started(.{ .port = 8080 });
    a.deinit();
    try testing.expectEqualStrings("init:pool, mount:db, mount:cache, route:db:/api/v1/x, route:cache:/api/v1/x, " ++
        "start:db, start:cache, after:db:8080, after:cache:8080, shutdown:cache, shutdown:db, deinit:pool", a.get(Trail).items());
}

test "beforeMount failure rolls back" {
    const A = TestApp(&.{ QueueAdapter, CacheAdapter, DbAdapter });
    var a: A = undefined;
    try testing.expectError(error.Boom, bootWith(A, &a, .{ .fail = "mount:cache" }));
    try testing.expectEqualStrings("init:pool, mount:db, mount:cache, shutdown:db, deinit:pool", a.get(Trail).items());
}

test "depends_on orders adapters" {
    const sorted = comptime order(&.{ QueueAdapter, DbAdapter, CacheAdapter });
    try testing.expect(sorted[0] == DbAdapter and sorted[1] == CacheAdapter and sorted[2] == QueueAdapter);
}
