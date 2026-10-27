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
    /// The route's OpenAPI operation (see `kzig.swagger`).
    doc: ?*const @import("../openapi/openapi.zig").RouteDoc = null,
};

/// `adapters` with each one after the adapters it `depends_on`.
pub fn order(comptime adapters: []const type) []const type {
    comptime {
        @setEvalBranchQuota(1_000_000);
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
        self.append(std.mem.print(&tmp, fmt, args) catch unreachable);
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

const Ctx = @import("context.zig").Ctx;
const Next = @import("middleware.zig").Next;
const testing_rt = @import("testing.zig");

fn mark(ctx: *Ctx, m: []const u8) !void {
    const prev = for (ctx.res.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "x-trail")) break h.value;
    } else null;
    try ctx.setHeader("x-trail", if (prev) |p| try ctx.arena.print("{s},{s}", .{ p, m }) else m);
}

fn Marker(comptime m: []const u8) fn (*Ctx, *Next) anyerror!void {
    return struct {
        fn f(ctx: *Ctx, next: *Next) anyerror!void {
            try mark(ctx, m);
            next.run();
        }
    }.f;
}

const Observed = struct {
    errors: u32 = 0,
    last_status: u16 = 0,
};

const PhaseAdapter = struct {
    observed: *Observed,
    pub const middleware = .{
        .{ .phase = .before_global, .handler = Marker("bg") },
        .{ .handler = Marker("ag") }, // after_global by default, as in KickJS
        .{ .phase = .before_routes, .handler = Marker("br") },
        .{ .phase = .after_routes, .handler = Marker("ar") },
    };
    pub const contributors = .{Level("adapter")};
    pub fn onError(self: *PhaseAdapter, _: *Ctx, _: anyerror) void {
        self.observed.errors += 1;
    }
    pub fn onResponse(self: *PhaseAdapter, ctx: *Ctx) void {
        self.observed.last_status = @backingInt(ctx.res.status);
    }
};

fn Level(comptime v: []const u8) type {
    return struct {
        pub const key = "level";
        pub fn resolve(_: *@This(), _: *Ctx) []const u8 {
            return v;
        }
    };
}

const PhaseController = struct {
    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
        .{ .method = .GET, .path = "/boom", .handler = "boom" },
    };
    pub fn index(_: *PhaseController, ctx: *Ctx, got: struct { level: []const u8 }) !void {
        try mark(ctx, "h");
        try mark(ctx, got.level);
    }
    pub fn boom(_: *PhaseController, _: *Ctx) !void {
        return error.Conflict;
    }
};

fn PhaseApp(comptime module_contributors: anytype) type {
    return app.App(.{
        .modules = &.{app.Module(.{ .name = "P", .path = "/p", .controllers = &.{PhaseController}, .services = &.{Observed}, .contributors = module_contributors })},
        .adapters = &.{PhaseAdapter},
        .middleware = .{Marker("app")},
        .contributors = .{Level("global")},
        .health = false,
    });
}

fn phaseGet(comptime A: type, a: *A, target: []const u8) !testing_rt.TestResponse {
    return testing_rt.request(testing.allocator, a, .{ .target = target });
}

fn bootPlain(comptime A: type, a: *A) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try a.init(testing.io, testing.allocator, &env);
}

test "phases run in KickJS order" {
    const A = PhaseApp(.{});
    var a: A = undefined;
    try bootPlain(A, &a);
    defer a.deinit();
    var hit = try phaseGet(A, &a, "/api/v1/p");
    defer hit.deinit();
    try testing.expectEqualStrings("bg,app,ag,br,h,adapter", hit.header("x-trail").?);
    var miss = try phaseGet(A, &a, "/nope");
    defer miss.deinit();
    try testing.expectEqual(std.http.Status.not_found, miss.status);
    try testing.expectEqualStrings("bg,app,ag,br,ar", miss.header("x-trail").?);
}

test "adapter contributor sits between module and global" {
    const A = PhaseApp(.{Level("module")});
    var a: A = undefined;
    try bootPlain(A, &a);
    defer a.deinit();
    var hit = try phaseGet(A, &a, "/api/v1/p");
    defer hit.deinit();
    try testing.expectEqualStrings("bg,app,ag,br,h,module", hit.header("x-trail").?);
}

test "onError sees handler errors and onResponse the final status" {
    const A = PhaseApp(.{});
    var a: A = undefined;
    try bootPlain(A, &a);
    defer a.deinit();
    var boom = try phaseGet(A, &a, "/api/v1/p/boom");
    defer boom.deinit();
    try testing.expectEqual(1, a.get(Observed).errors);
    try testing.expectEqual(409, a.get(Observed).last_status);
    var ok = try phaseGet(A, &a, "/api/v1/p");
    defer ok.deinit();
    try testing.expectEqual(204, a.get(Observed).last_status);
}

const AuditController = struct {
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "index" }};
    pub fn index(_: *AuditController, _: *Ctx) []const u8 {
        return "audit";
    }
};

const AuditPlugin = app.Plugin(.{
    .name = "AuditPlugin",
    .modules = &.{app.Module(.{ .name = "Audit", .path = "/audit", .controllers = &.{AuditController}, .services = &.{ Pool, Trail } })},
    .adapters = &.{DbAdapter},
    .middleware = .{Marker("plugin")},
    .contributors = .{Level("plugin")},
});

const PluginApp = app.App(.{
    .modules = &.{app.Module(.{ .name = "P", .path = "/p", .controllers = &.{PhaseController}, .services = &.{Observed} })},
    .plugins = &.{AuditPlugin},
    .adapters = &.{DbAdapter},
    .middleware = .{Marker("app")},
    .health = false,
});

test "plugin bundles modules, adapters, middleware and contributors" {
    var a: PluginApp = undefined;
    try bootPlain(PluginApp, &a);
    defer a.deinit();
    var audit = try phaseGet(PluginApp, &a, "/api/v1/audit");
    defer audit.deinit();
    try testing.expectEqualStrings("audit", audit.body);
    var hit = try phaseGet(PluginApp, &a, "/api/v1/p");
    defer hit.deinit();
    // Plugin middleware runs before the App's; its contributor is adapter-level.
    try testing.expectEqualStrings("plugin,app,h,plugin", hit.header("x-trail").?);
}

test "an adapter listed twice is one instance" {
    var a: PluginApp = undefined;
    try bootPlain(PluginApp, &a);
    // DbAdapter comes from the plugin and the app: mounted once.
    try testing.expectEqualStrings("init:pool, mount:db, route:db:/api/v1/audit, route:db:/api/v1/p, route:db:/api/v1/p/boom, start:db", a.get(Trail).items());
    a.deinit();
}
