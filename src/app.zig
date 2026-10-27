//! `Module` and `App`: KickJS's `defineModule` / `bootstrap` shape, resolved
//! at comptime into one DI container and one route table.
const std = @import("std");
const context = @import("context.zig");
const testing_rt = @import("testing.zig");
const kzig_mw = @import("middleware.zig");

const Ctx = context.Ctx;
const builtin = @import("builtin");
const config = @import("config.zig");
const di = @import("di.zig");
const health = @import("health.zig");
const router = @import("router.zig");
const mw = @import("middleware.zig");
const contributor = @import("contributor.zig");

/// Injectable as `*const kzig.Process`.
pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    started_at: std.Io.Timestamp,

    /// Seconds since the app started, like Node's `process.uptime()`.
    pub fn uptime(self: *const Process) f64 {
        const ns = self.started_at.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    }
};

/// KickJS's `version: number | false`, with the app default as a third case.
pub const Version = union(enum) {
    default,
    none,
    v: u16,
};

/// `spec`: `.name`, `.path = ""`, `.controllers = &.{}`, `.services = &.{}`,
/// `.version` (a number, or `false` for none; the app default otherwise),
/// `.prefix = true` (false drops the api prefix) — KickJS's `routes()` options.
pub fn Module(comptime spec: anytype) type {
    checkFields(spec, &.{ "name", "path", "controllers", "services", "version", "prefix", "contributors" }, "Module");
    return struct {
        pub const kzig_module = true;
        pub const name: []const u8 = spec.name;
        pub const path: []const u8 = opt(spec, "path", @as([]const u8, ""));
        pub const controllers: []const type = opt(spec, "controllers", @as([]const type, &.{}));
        pub const services: []const type = opt(spec, "services", @as([]const type, &.{}));
        pub const version: Version = if (@hasField(@TypeOf(spec), "version")) versionOf(spec.version) else .default;
        pub const prefix: bool = opt(spec, "prefix", true);
        pub const contributors: []const type = contributor.types(if (@hasField(@TypeOf(spec), "contributors")) spec.contributors else .{}, spec.name);
    };
}

/// `spec`: `.modules`, `.config = struct {}`, `.api_prefix = "/api"`,
/// `.default_version = 1`, `.health = true` (mounts `/health/live` and
/// `/health/ready`).
pub fn App(comptime spec: anytype) type {
    checkFields(spec, &.{ "modules", "config", "api_prefix", "default_version", "health", "middleware", "contributors" }, "App");
    const global_contributors: []const type = contributor.types(if (@hasField(@TypeOf(spec), "contributors")) spec.contributors else .{}, "App");
    const global_mw = if (@hasField(@TypeOf(spec), "middleware")) spec.middleware else .{};
    const Config = opt(spec, "config", struct {});
    const api_prefix: []const u8 = opt(spec, "api_prefix", @as([]const u8, "/api"));
    const default_version: u16 = opt(spec, "default_version", @as(u16, 1));
    if (api_prefix.len > 0 and api_prefix[0] != '/') @compileError("api_prefix must be empty or start with '/': \"" ++ api_prefix ++ "\"");
    const modules: []const type = @as([]const type, spec.modules) ++
        (if (opt(spec, "health", true)) &[_]type{health.Module} else &[_]type{});

    comptime var listed: []const type = &.{ Config, Process };
    listed = listed ++ mwTypes(global_mw) ++ global_contributors;
    inline for (modules) |M| {
        if (!@hasDecl(M, "kzig_module")) @compileError(@typeName(M) ++ " is not a kzig.Module");
        listed = listed ++ M.services ++ M.controllers ++ M.contributors;
        inline for (M.controllers) |C| {
            if (@hasDecl(C, "middleware")) listed = listed ++ mwTypes(C.middleware);
            if (@hasDecl(C, "contributors")) listed = listed ++ contributor.types(C.contributors, @typeName(C));
            if (@hasDecl(C, "routes")) inline for (C.routes) |r| {
                if (@hasField(@TypeOf(r), "middleware")) listed = listed ++ mwTypes(r.middleware);
                if (@hasField(@TypeOf(r), "contributors")) listed = listed ++ contributor.types(r.contributors, @typeName(C));
            };
        }
    }
    const Services = di.Container(listed);

    return struct {
        const Self = @This();
        pub const Settings = Config;

        container: Services,
        config_arena: std.heap.ArenaAllocator,

        pub const routes: []const router.Route = buildRoutes(Self, modules, api_prefix, default_version, global_contributors);
        const Routes = router.Router(routes);
        const global: []const mw.Fn = mwChain(Self, global_mw, "App");

        /// Reads config from `env` and builds every service in place.
        /// `self` must not move afterwards: services point into it.
        pub fn init(self: *Self, io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
            return self.initWith(io, gpa, env, .{});
        }

        /// `init` with `overrides`: ready-made service instances that replace
        /// the built ones (KickJS's `createTestApp({ overrides })`). Tests only.
        pub fn initWith(self: *Self, io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, overrides: anytype) !void {
            if (@typeInfo(@TypeOf(overrides)).@"struct".field_names.len > 0 and !builtin.is_test)
                @compileError("App overrides are only allowed in tests");
            self.config_arena = .init(gpa);
            errdefer self.config_arena.deinit();
            const cfg = try config.load(Config, self.config_arena.allocator(), env);
            const process: Process = .{ .io = io, .gpa = gpa, .started_at = std.Io.Clock.awake.now(io) };
            try self.container.initWith(.{ cfg, process } ++ overrides);
        }

        pub fn deinit(self: *Self) void {
            self.container.deinit();
            self.config_arena.deinit();
        }

        pub fn get(self: *Self, comptime S: type) *S {
            return self.container.get(S);
        }

        pub fn handle(self: *Self, ctx: *Ctx) void {
            ctx.app = self;
            Routes.handleWith(global, ctx);
        }
    };
}

fn buildRoutes(comptime AppT: type, comptime modules: []const type, comptime api_prefix: []const u8, comptime default_version: u16, comptime global_contributors: []const type) []const router.Route {
    comptime {
        var list: []const router.Route = &.{};
        var owners: []const []const u8 = &.{};
        for (modules) |M| {
            if (M.path.len > 0 and M.path[0] != '/') @compileError(M.name ++ ": module path must be empty or start with '/': \"" ++ M.path ++ "\"");
            const mount = (if (M.prefix) api_prefix else "") ++ switch (M.version) {
                .default => std.fmt.comptimePrint("/v{d}", .{default_version}),
                .none => "",
                .v => |n| std.fmt.comptimePrint("/v{d}", .{n}),
            } ++ M.path;
            for (M.controllers) |C| {
                if (!@hasDecl(C, "routes")) @compileError(@typeName(C) ++ " has no `pub const routes`");
                for (C.routes) |r| {
                    const handler: []const u8 = r.handler;
                    if (!@hasDecl(C, handler)) @compileError(@typeName(C) ++ " has no handler " ++ handler);
                    if (r.path.len > 0 and r.path[0] != '/') @compileError(@typeName(C) ++ "." ++ handler ++ ": path must start with '/'");
                    const full = if (mount.len + r.path.len == 0) "/" else mount ++ r.path;
                    const method: std.http.Method = r.method;
                    const owner = @typeName(C) ++ "." ++ handler;
                    for (list, owners) |other, other_owner| {
                        if (other.method == method and samePattern(other.path, full))
                            @compileError("duplicate route " ++ @tagName(method) ++ " " ++ full ++ ": " ++ other_owner ++ " and " ++ owner);
                    }
                    const where = @tagName(method) ++ " " ++ full;
                    const chain = (if (@hasDecl(C, "middleware")) mwChain(AppT, C.middleware, where) else &[_]mw.Fn{}) ++
                        (if (@hasField(@TypeOf(r), "middleware")) mwChain(AppT, r.middleware, where) else &[_]mw.Fn{});
                    const P = contributor.Plan(.{
                        global_contributors,
                        M.contributors,
                        if (@hasDecl(C, "contributors")) contributor.types(C.contributors, where) else &.{},
                        if (@hasField(@TypeOf(r), "contributors")) contributor.types(r.contributors, where) else &.{},
                    }, contributor.GotOf(@field(C, handler)), where);
                    list = list ++ .{router.Route{ .method = method, .path = full, .handler = thunk(AppT, C, handler, P, chain) }};
                    owners = owners ++ .{owner};
                }
            }
        }
        const result = list;
        return result;
    }
}

/// Struct middleware types in `entries`; they are services.
fn mwTypes(comptime entries: anytype) []const type {
    comptime {
        var out: []const type = &.{};
        for (entries) |e| {
            if (@TypeOf(e) == type) out = out ++ .{e};
        }
        const result = out;
        return result;
    }
}

/// A middleware entry is a function `fn (*Ctx, *Next) !void` or a service
/// type with `pub fn handle(self: *T, *Ctx, *Next) !void`.
fn mwChain(comptime AppT: type, comptime entries: anytype, comptime where: []const u8) []const mw.Fn {
    comptime {
        var out: []const mw.Fn = &.{};
        for (entries) |e| out = out ++ .{mwFn(AppT, e, where)};
        const result = out;
        return result;
    }
}

fn mwFn(comptime AppT: type, comptime e: anytype, comptime where: []const u8) mw.Fn {
    const bad = where ++ ": middleware must be fn (*Ctx, *Next) !void or a type with handle";
    if (@TypeOf(e) == type) {
        if (@typeInfo(e) != .@"struct" or !@hasDecl(e, "handle")) @compileError(bad);
        return struct {
            fn call(ctx: *Ctx, next: *mw.Next) anyerror!void {
                const app: *AppT = @ptrCast(@alignCast(ctx.app.?));
                return e.handle(app.get(e), ctx, next);
            }
        }.call;
    }
    if (@typeInfo(@TypeOf(e)) != .@"fn") @compileError(bad);
    return struct {
        fn call(ctx: *Ctx, next: *mw.Next) anyerror!void {
            return e(ctx, next);
        }
    }.call;
}

/// Same route ignoring param names and empty segments.
fn samePattern(comptime a: []const u8, comptime b: []const u8) bool {
    var ia = std.mem.tokenizeScalar(u8, a, '/');
    var ib = std.mem.tokenizeScalar(u8, b, '/');
    while (true) {
        const sa = ia.next();
        const sb = ib.next();
        if (sa == null or sb == null) return sa == null and sb == null;
        const pa = sa.?[0] == ':';
        const pb = sb.?[0] == ':';
        if (pa != pb or (!pa and !std.mem.eql(u8, sa.?, sb.?))) return false;
    }
}

/// A route's pipeline after matching: early contributors, then the
/// controller and route middleware around the remaining contributors and the
/// handler, whose return value is sent.
fn thunk(comptime AppT: type, comptime C: type, comptime name: []const u8, comptime P: type, comptime chain: []const mw.Fn) router.Handler {
    return struct {
        fn call(ctx: *Ctx) anyerror!void {
            const app = appOf(AppT, ctx);
            var store: P.Store = .{};
            ctx.values = &store;
            defer ctx.values = null;
            inline for (P.early_order) |K| try contributor.run(K, app.get(K), ctx, &store);
            if (chain.len == 0) return late(ctx);
            var next: mw.Next = .{ .ctx = ctx, .chain = chain, .final = late };
            next.run();
        }

        fn late(ctx: *Ctx) anyerror!void {
            const app = appOf(AppT, ctx);
            const store: *P.Store = @ptrCast(@alignCast(ctx.values.?));
            inline for (P.late_order) |K| try contributor.run(K, app.get(K), ctx, store);
            const h = @field(C, name);
            const result = if (comptime contributor.GotOf(h)) |G|
                h(app.get(C), ctx, contributor.fill(G, store.*))
            else
                h(app.get(C), ctx);
            const value = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
            try ctx.send(value);
        }
    }.call;
}

fn appOf(comptime AppT: type, ctx: *Ctx) *AppT {
    return @ptrCast(@alignCast(ctx.app.?));
}

fn versionOf(comptime v: anytype) Version {
    return switch (@typeInfo(@TypeOf(v))) {
        .comptime_int, .int => .{ .v = v },
        .bool => if (v) .default else .none,
        else => @compileError("Module .version must be a number or false"),
    };
}

fn opt(comptime spec: anytype, comptime name: []const u8, comptime default: anytype) @TypeOf(default) {
    return if (@hasField(@TypeOf(spec), name)) @field(spec, name) else default;
}

/// A misspelt spec field would otherwise be ignored silently.
fn checkFields(comptime spec: anytype, comptime allowed: []const []const u8, comptime what: []const u8) void {
    for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |f| {
        for (allowed) |a| {
            if (std.mem.eql(u8, a, f)) break;
        } else @compileError(what ++ " has no option ." ++ f);
    }
}
const testing = std.testing;

const Greeter = struct {
    word: []const u8 = "Hello",
};

const HelloController = struct {
    greeter: *Greeter,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
        .{ .method = .GET, .path = "/:name", .handler = "named" },
    };

    pub fn index(self: *HelloController, ctx: *Ctx) !struct { message: []const u8 } {
        return .{ .message = try std.fmt.allocPrint(ctx.arena, "{s} world", .{self.greeter.word}) };
    }
    pub fn named(self: *HelloController, ctx: *Ctx) !struct { message: []const u8 } {
        return .{ .message = try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ self.greeter.word, ctx.param("name").? }) };
    }
};

const TestConfig = struct { greeting: []const u8 = "Hello" };

const StatusController = struct {
    config: *const TestConfig,
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "show" }};
    pub fn show(self: *StatusController, _: *Ctx) []const u8 {
        return self.config.greeting;
    }
};

const ThingsController = struct {
    greeter: *Greeter,
    pub const routes = .{.{ .method = .GET, .path = "", .handler = "list" }};
    pub fn list(_: *ThingsController, _: *Ctx) struct { things: []const u8 } {
        return .{ .things = "none" };
    }
};

const HelloModule = Module(.{ .name = "HelloModule", .path = "/hello", .controllers = &.{HelloController}, .services = &.{Greeter} });
const StatusModule = Module(.{ .name = "StatusModule", .path = "/status", .prefix = false, .version = false, .controllers = &.{StatusController} });
const ThingsModule = Module(.{ .name = "ThingsModule", .path = "/things", .version = 2, .controllers = &.{ThingsController}, .services = &.{Greeter} });

const TestApp = App(.{ .modules = &.{ HelloModule, StatusModule, ThingsModule }, .config = TestConfig });

fn get(app: *TestApp, target: []const u8) !testing_rt.TestResponse {
    return testing_rt.request(testing.allocator, app, .{ .target = target });
}

fn boot(app: *TestApp, pairs: []const [2][]const u8) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    try app.init(testing.io, testing.allocator, &env);
}

test "mounts under /api/v1 + module path" {
    var app: TestApp = undefined;
    try boot(&app, &.{});
    defer app.deinit();
    var a = try get(&app, "/api/v1/hello");
    defer a.deinit();
    try testing.expectEqualStrings("{\"message\":\"Hello world\"}", a.body);
    var b = try get(&app, "/api/v1/hello/ada");
    defer b.deinit();
    try testing.expectEqualStrings("{\"message\":\"Hello ada\"}", b.body);
}

test "version none and prefix false" {
    var app: TestApp = undefined;
    try boot(&app, &.{});
    defer app.deinit();
    var a = try get(&app, "/status");
    defer a.deinit();
    try testing.expectEqualStrings("Hello", a.body);
}

test "custom version" {
    var app: TestApp = undefined;
    try boot(&app, &.{});
    defer app.deinit();
    var a = try get(&app, "/api/v2/things");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.ok, a.status);
}

test "config is read from env and injectable" {
    var app: TestApp = undefined;
    try boot(&app, &.{.{ "GREETING", "Hi" }});
    defer app.deinit();
    try testing.expectEqualStrings("Hi", app.get(TestConfig).greeting);
    var a = try get(&app, "/status");
    defer a.deinit();
    try testing.expectEqualStrings("Hi", a.body);
}

test "health live and ready" {
    var app: TestApp = undefined;
    try boot(&app, &.{});
    defer app.deinit();
    var live = try get(&app, "/health/live");
    defer live.deinit();
    const l = try live.json(struct { status: []const u8, uptime: f64 });
    try testing.expectEqualStrings("ok", l.status);
    try testing.expect(l.uptime >= 0);
    var ready = try get(&app, "/health/ready");
    defer ready.deinit();
    try testing.expectEqualStrings("{\"status\":\"ready\",\"checks\":[]}", ready.body);
}

test "same service in two modules is one instance" {
    var app: TestApp = undefined;
    try boot(&app, &.{});
    defer app.deinit();
    try testing.expectEqual(app.get(Greeter), app.get(HelloController).greeter);
    try testing.expectEqual(app.get(Greeter), app.get(ThingsController).greeter);
}

test "overrides replace a service in tests" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var app: TestApp = undefined;
    try app.initWith(testing.io, testing.allocator, &env, .{Greeter{ .word = "Yo" }});
    defer app.deinit();
    var a = try get(&app, "/api/v1/hello");
    defer a.deinit();
    try testing.expectEqualStrings("{\"message\":\"Yo world\"}", a.body);
}

fn mark(ctx: *Ctx, m: []const u8) !void {
    const prev = for (ctx.res.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "x-trail")) break h.value;
    } else null;
    try ctx.setHeader("x-trail", if (prev) |p| try std.fmt.allocPrint(ctx.arena, "{s},{s}", .{ p, m }) else m);
}

const Mw = struct {
    fn app(ctx: *Ctx, next: *kzig_mw.Next) !void {
        try mark(ctx, "a");
        next.run();
    }
    fn controller(ctx: *Ctx, next: *kzig_mw.Next) !void {
        try mark(ctx, "c");
        next.run();
    }
    fn route(ctx: *Ctx, next: *kzig_mw.Next) !void {
        try mark(ctx, "r");
        next.run();
    }
};

const Counter = struct { hits: u32 = 0 };

/// Struct middleware: a service with DI fields.
const CountHits = struct {
    counter: *Counter,
    pub fn handle(self: *CountHits, ctx: *Ctx, next: *kzig_mw.Next) !void {
        self.counter.hits += 1;
        try ctx.setHeader("x-hits", try std.fmt.allocPrint(ctx.arena, "{d}", .{self.counter.hits}));
        next.run();
    }
};

const MwController = struct {
    pub const middleware = .{Mw.controller};
    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index", .middleware = .{ Mw.route, CountHits } },
    };
    pub fn index(_: *MwController, ctx: *Ctx) !void {
        try mark(ctx, "h");
    }
};

const MwApp = App(.{
    .modules = &.{Module(.{ .name = "MwModule", .path = "/mw", .controllers = &.{MwController}, .services = &.{Counter} })},
    .middleware = .{Mw.app},
});

test "app, controller and route middleware run in order" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var app: MwApp = undefined;
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    var a = try testing_rt.request(testing.allocator, &app, .{ .target = "/api/v1/mw" });
    defer a.deinit();
    try testing.expectEqualStrings("a,c,r,h", a.header("x-trail").?);
    var b = try testing_rt.request(testing.allocator, &app, .{ .target = "/nope" });
    defer b.deinit();
    try testing.expectEqualStrings("a", b.header("x-trail").?);
}

test "struct middleware gets its service" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var app: MwApp = undefined;
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    for (0..2) |_| {
        var a = try testing_rt.request(testing.allocator, &app, .{ .target = "/api/v1/mw" });
        a.deinit();
    }
    try testing.expectEqual(2, app.get(Counter).hits);
}

const Tenant = struct { id: []const u8, name: []const u8 };

const TenantRepo = struct {
    pub fn find(_: *TenantRepo, id: []const u8) ?Tenant {
        if (std.mem.eql(u8, id, "acme")) return .{ .id = "acme", .name = "Acme Corp" };
        return null;
    }
};

const LoadTenant = struct {
    pub const key = "tenant";
    repo: *TenantRepo,
    pub fn resolve(self: *LoadTenant, ctx: *Ctx) !Tenant {
        const id = ctx.header("x-tenant") orelse return error.BadRequest;
        return self.repo.find(id) orelse ctx.fail(.not_found, "Unknown tenant");
    }
};

const LoadProject = struct {
    pub const key = "project";
    pub fn resolve(_: *LoadProject, ctx: *Ctx, got: struct { tenant: Tenant }) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ got.tenant.id, ctx.param("id").? });
    }
};

const LoadFlag = struct {
    pub const key = "flag";
    pub const optional = true;
    pub fn resolve(_: *LoadFlag, ctx: *Ctx) !bool {
        return if (ctx.header("x-flag") != null) true else error.NoFlag;
    }
};

fn Label(comptime v: []const u8) type {
    return struct {
        pub const key = "label";
        pub fn resolve(_: *@This(), _: *Ctx) []const u8 {
            return v;
        }
    };
}

fn Constant(comptime k: []const u8, comptime v: []const u8) type {
    return struct {
        pub const key = k;
        pub fn resolve(_: *@This(), _: *Ctx) []const u8 {
            return v;
        }
    };
}

const Trail = struct {
    pub const key = "trail";
    pub fn resolve(_: *Trail, ctx: *Ctx) !void {
        try mark(ctx, "k");
    }
};

const ContribController = struct {
    pub const contributors = .{ LoadTenant, Label("controller") };
    pub const routes = .{
        .{ .method = .GET, .path = "/projects/:id", .handler = "project", .contributors = .{LoadProject} },
        .{ .method = .GET, .path = "/label", .handler = "label", .contributors = .{Label("method")} },
        .{ .method = .GET, .path = "/levels", .handler = "levels" },
        .{ .method = .GET, .path = "/flag", .handler = "flag", .contributors = .{LoadFlag} },
        .{ .method = .GET, .path = "/order", .handler = "order", .contributors = .{Trail}, .middleware = .{Mw.route} },
    };
    pub fn project(_: *ContribController, _: *Ctx, got: struct { project: []const u8 }) []const u8 {
        return got.project;
    }
    pub fn label(_: *ContribController, _: *Ctx, got: struct { label: []const u8 }) []const u8 {
        return got.label;
    }
    pub fn levels(_: *ContribController, ctx: *Ctx, got: struct { module_v: []const u8, global_v: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena, "{s},{s}", .{ got.module_v, got.global_v });
    }
    pub fn flag(_: *ContribController, _: *Ctx, got: struct { flag: ?bool }) []const u8 {
        return if (got.flag != null) "on" else "off";
    }
    pub fn order(_: *ContribController, ctx: *Ctx) !void {
        try mark(ctx, "h");
    }
};

const ContribApp = App(.{
    .modules = &.{Module(.{
        .name = "ContribModule",
        .path = "/c",
        .controllers = &.{ContribController},
        .services = &.{TenantRepo},
        .contributors = .{Constant("module_v", "m")},
    })},
    .contributors = .{Constant("global_v", "g")},
});

fn contribGet(target: []const u8, headers: []const context.Header) !testing_rt.TestResponse {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const app = try testing.allocator.create(ContribApp);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    return testing_rt.request(testing.allocator, app, .{ .target = target, .headers = headers });
}

const acme: []const context.Header = &.{.{ .name = "x-tenant", .value = "acme" }};

test "contributor value reaches the handler" {
    var a = try contribGet("/api/v1/c/projects/7", acme);
    defer a.deinit();
    try testing.expectEqualStrings("acme/7", a.body);
}

test "a failing dependency stops its dependents" {
    var a = try contribGet("/api/v1/c/projects/7", &.{});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.bad_request, a.status);
}

test "contributor error becomes the response" {
    var a = try contribGet("/api/v1/c/projects/7", &.{.{ .name = "x-tenant", .value = "nope" }});
    defer a.deinit();
    try testing.expectEqual(std.http.Status.not_found, a.status);
    try testing.expect(std.mem.indexOf(u8, a.body, "Unknown tenant") != null);
}

test "method contributor shadows controller one" {
    var a = try contribGet("/api/v1/c/label", acme);
    defer a.deinit();
    try testing.expectEqualStrings("method", a.body);
}

test "module and global contributors apply" {
    var a = try contribGet("/api/v1/c/levels", acme);
    defer a.deinit();
    try testing.expectEqualStrings("m,g", a.body);
}

test "optional contributor error gives null" {
    var off = try contribGet("/api/v1/c/flag", acme);
    defer off.deinit();
    try testing.expectEqualStrings("off", off.body);
    var on = try contribGet("/api/v1/c/flag", &.{ .{ .name = "x-tenant", .value = "acme" }, .{ .name = "x-flag", .value = "1" } });
    defer on.deinit();
    try testing.expectEqualStrings("on", on.body);
}

test "contributors run after route middleware" {
    var a = try contribGet("/api/v1/c/order", acme);
    defer a.deinit();
    try testing.expectEqualStrings("r,k,h", a.header("x-trail").?);
}
