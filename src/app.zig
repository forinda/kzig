//! `Module` and `App`: KickJS's `defineModule` / `bootstrap` shape, resolved
//! at comptime into one DI container and one route table.
const std = @import("std");
const context = @import("context.zig");
const testing_rt = @import("testing.zig");

const Ctx = context.Ctx;
const builtin = @import("builtin");
const config = @import("config.zig");
const di = @import("di.zig");
const health = @import("health.zig");
const router = @import("router.zig");

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
    checkFields(spec, &.{ "name", "path", "controllers", "services", "version", "prefix" }, "Module");
    return struct {
        pub const kzig_module = true;
        pub const name: []const u8 = spec.name;
        pub const path: []const u8 = opt(spec, "path", @as([]const u8, ""));
        pub const controllers: []const type = opt(spec, "controllers", @as([]const type, &.{}));
        pub const services: []const type = opt(spec, "services", @as([]const type, &.{}));
        pub const version: Version = if (@hasField(@TypeOf(spec), "version")) versionOf(spec.version) else .default;
        pub const prefix: bool = opt(spec, "prefix", true);
    };
}

/// `spec`: `.modules`, `.config = struct {}`, `.api_prefix = "/api"`,
/// `.default_version = 1`, `.health = true` (mounts `/health/live` and
/// `/health/ready`).
pub fn App(comptime spec: anytype) type {
    checkFields(spec, &.{ "modules", "config", "api_prefix", "default_version", "health" }, "App");
    const Config = opt(spec, "config", struct {});
    const api_prefix: []const u8 = opt(spec, "api_prefix", @as([]const u8, "/api"));
    const default_version: u16 = opt(spec, "default_version", @as(u16, 1));
    if (api_prefix.len > 0 and api_prefix[0] != '/') @compileError("api_prefix must be empty or start with '/': \"" ++ api_prefix ++ "\"");
    const modules: []const type = @as([]const type, spec.modules) ++
        (if (opt(spec, "health", true)) &[_]type{health.Module} else &[_]type{});

    comptime var listed: []const type = &.{ Config, Process };
    inline for (modules) |M| {
        if (!@hasDecl(M, "kzig_module")) @compileError(@typeName(M) ++ " is not a kzig.Module");
        listed = listed ++ M.services ++ M.controllers;
    }
    const Services = di.Container(listed);

    return struct {
        const Self = @This();
        pub const Settings = Config;

        container: Services,
        config_arena: std.heap.ArenaAllocator,

        pub const routes: []const router.Route = buildRoutes(Self, modules, api_prefix, default_version);
        const Routes = router.Router(routes);

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
            (Routes{}).handle(ctx);
        }
    };
}

fn buildRoutes(comptime AppT: type, comptime modules: []const type, comptime api_prefix: []const u8, comptime default_version: u16) []const router.Route {
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
                    list = list ++ .{router.Route{ .method = method, .path = full, .handler = thunk(AppT, C, handler) }};
                    owners = owners ++ .{owner};
                }
            }
        }
        const result = list;
        return result;
    }
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

/// Finds the controller through `ctx.app` and sends what the handler returns.
fn thunk(comptime AppT: type, comptime C: type, comptime name: []const u8) router.Handler {
    return struct {
        fn call(ctx: *Ctx) anyerror!void {
            const app: *AppT = @ptrCast(@alignCast(ctx.app.?));
            const result = @field(C, name)(app.get(C), ctx);
            const value = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
            try ctx.send(value);
        }
    }.call;
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
