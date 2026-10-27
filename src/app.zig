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
const decode = @import("decode.zig");
const adapter_mod = @import("adapter.zig");

/// Injectable as `*const kzig.Process`.
pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    started_at: std.Io.Timestamp,
    /// `NODE_ENV` is `development` or `test` — read raw, so an unset
    /// `NODE_ENV` counts as production (the archive apps' `isDevOrTest()`).
    dev_or_test: bool = false,
    /// Set once shutdown begins; health answers `draining`.
    draining: std.atomic.Value(bool) = .init(false),

    pub fn isDraining(self: *const Process) bool {
        return self.draining.load(.acquire);
    }

    /// Seconds since the app started, like Node's `process.uptime()`.
    pub fn uptime(self: *const Process) f64 {
        const ns = self.started_at.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    }
};

/// Every config variable the app read, with where its value came from
/// (KickJS `configOrigins()`); names only, never values. Injectable as
/// `*const kzig.ConfigReport`.
pub const ConfigReport = struct {
    vars: []const config.Origin,
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
    checkFields(spec, &.{ "name", "path", "controllers", "services", "version", "prefix", "contributors", "settings" }, "Module");
    return struct {
        pub const kzig_module = true;
        pub const name: []const u8 = spec.name;
        pub const path: []const u8 = opt(spec, "path", @as([]const u8, ""));
        pub const controllers: []const type = opt(spec, "controllers", @as([]const type, &.{}));
        pub const services: []const type = opt(spec, "services", @as([]const type, &.{}));
        pub const version: Version = if (@hasField(@TypeOf(spec), "version")) versionOf(spec.version) else .default;
        pub const prefix: bool = opt(spec, "prefix", true);
        /// Settings sections, read and validated only when this module is mounted.
        pub const settings: []const type = opt(spec, "settings", @as([]const type, &.{}));
        pub const contributors: []const type = contributor.types(if (@hasField(@TypeOf(spec), "contributors")) spec.contributors else .{}, spec.name);
    };
}

/// A bundle of modules, adapters, middleware, contributors and settings
/// (KickJS `definePlugin`). `spec`: `.name`, and any of `.modules`,
/// `.adapters`, `.middleware`, `.contributors`, `.settings`. Its modules and
/// adapters come before the App's; its middleware runs after adapters'
/// `before_global`; its contributors are adapter-level.
pub fn Plugin(comptime spec: anytype) type {
    checkFields(spec, &.{ "name", "modules", "adapters", "middleware", "contributors", "settings" }, "Plugin");
    return struct {
        pub const kzig_plugin = true;
        pub const name: []const u8 = spec.name;
        pub const modules: []const type = opt(spec, "modules", @as([]const type, &.{}));
        pub const adapters: []const type = opt(spec, "adapters", @as([]const type, &.{}));
        pub const settings: []const type = opt(spec, "settings", @as([]const type, &.{}));
        pub const middleware = if (@hasField(@TypeOf(spec), "middleware")) spec.middleware else .{};
        pub const contributors: []const type = contributor.types(if (@hasField(@TypeOf(spec), "contributors")) spec.contributors else .{}, spec.name);
    };
}

/// `spec`: `.modules`, `.config = struct {}`, `.api_prefix = "/api"`,
/// `.default_version = 1`, `.health = true` (mounts `/health/live` and
/// `/health/ready`).
pub fn App(comptime spec: anytype) type {
    checkFields(spec, &.{ "modules", "config", "api_prefix", "default_version", "health", "middleware", "contributors", "settings", "adapters", "plugins" }, "App");
    const plugins: []const type = opt(spec, "plugins", @as([]const type, &.{}));
    comptime var plugin_modules: []const type = &.{};
    comptime var plugin_adapters: []const type = &.{};
    comptime var plugin_settings: []const type = &.{};
    comptime var plugin_contributors: []const type = &.{};
    inline for (plugins) |Pl| {
        if (!@hasDecl(Pl, "kzig_plugin")) @compileError(@typeName(Pl) ++ " is not a kzig.Plugin");
        plugin_modules = plugin_modules ++ Pl.modules;
        plugin_adapters = plugin_adapters ++ Pl.adapters;
        plugin_settings = plugin_settings ++ Pl.settings;
        plugin_contributors = plugin_contributors ++ Pl.contributors;
    }
    const adapters = adapter_mod.order(di.unique(plugin_adapters ++ opt(spec, "adapters", @as([]const type, &.{}))));
    const global_contributors: []const type = contributor.types(if (@hasField(@TypeOf(spec), "contributors")) spec.contributors else .{}, "App");
    const app_mw = if (@hasField(@TypeOf(spec), "middleware")) spec.middleware else .{};
    const Config = opt(spec, "config", struct {});
    const api_prefix: []const u8 = opt(spec, "api_prefix", @as([]const u8, "/api"));
    const default_version: u16 = opt(spec, "default_version", @as(u16, 1));
    if (api_prefix.len > 0 and api_prefix[0] != '/') @compileError("api_prefix must be empty or start with '/': \"" ++ api_prefix ++ "\"");
    const modules: []const type = di.unique(plugin_modules ++ @as([]const type, spec.modules)) ++
        (if (opt(spec, "health", true)) &[_]type{health.Module} else &[_]type{});

    comptime var section_list: []const type = &.{Config};
    section_list = section_list ++ plugin_settings ++ opt(spec, "settings", @as([]const type, &.{}));
    inline for (modules) |M| section_list = section_list ++ M.settings;
    inline for (adapters) |A| {
        if (@hasDecl(A, "settings")) section_list = section_list ++ @as([]const type, A.settings);
    }
    const sections = di.unique(section_list);

    comptime var listed: []const type = sections ++ &[_]type{ Process, ConfigReport, health.Probe } ++ adapters;
    comptime var adapter_contributors: []const type = plugin_contributors;
    inline for (adapters) |A| {
        if (@hasDecl(A, "contributors")) adapter_contributors = adapter_contributors ++ contributor.types(A.contributors, @typeName(A));
        if (@hasDecl(A, "middleware")) inline for (A.middleware) |entry| {
            listed = listed ++ mwTypes(.{entry.handler});
        };
    }
    inline for (plugins) |Pl| listed = listed ++ mwTypes(Pl.middleware);
    listed = listed ++ mwTypes(app_mw) ++ global_contributors ++ adapter_contributors;
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
        health_cache: HealthCache = .{},
        /// Adapters whose `beforeMount` ran; they get `shutdown`.
        mounted: usize = 0,

        pub const routes: []const router.Route = buildRoutes(Self, modules, api_prefix, default_version, .{ global_contributors, adapter_contributors });
        const Routes = router.Router(routes);
        // KickJS order: adapters' before_global, the App's middleware,
        // adapters' after_global, then before_routes.
        const global: []const mw.Fn = phase(Self, adapters, .before_global) ++ pluginChain(Self, plugins) ++ mwChain(Self, app_mw, "App") ++
            phase(Self, adapters, .after_global) ++ phase(Self, adapters, .before_routes);
        const after_routes: []const mw.Fn = phase(Self, adapters, .after_routes);

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
            // `self` is usually `undefined` before init: no field default applies.
            self.health_cache = .{};
            self.mounted = 0;
            self.config_arena = .init(gpa);
            errdefer self.config_arena.deinit();
            const arena = self.config_arena.allocator();

            // Every section is read before failing, so one boot names every
            // bad variable. An overridden section isn't read at all.
            var values: @Tuple(sections) = undefined;
            var origins: std.ArrayList(config.Origin) = .empty;
            var failed = false;
            inline for (sections, 0..) |S, i| {
                if (comptime overrideOf(@TypeOf(overrides), S)) |f| {
                    values[i] = @field(overrides, f);
                    try config.providedOrigins(S, arena, &origins);
                } else {
                    var issues: std.ArrayList(config.Issue) = .empty;
                    if (config.parseSection(S, arena, io, env, &issues, &origins)) |v| {
                        values[i] = v;
                    } else |err| switch (err) {
                        error.InvalidConfig => {
                            if (!builtin.is_test) config.logIssues(S, issues.items);
                            failed = true;
                        },
                        else => return err,
                    }
                }
            }
            if (failed) return error.InvalidConfig;

            const process: Process = .{ .io = io, .gpa = gpa, .started_at = std.Io.Clock.awake.now(io), .dev_or_test = config.devOrTest(env) };
            const probe: health.Probe = .{ .app = self, .checks = healthChecks };
            try self.container.initWith(values ++ .{ process, ConfigReport{ .vars = origins.items }, probe } ++ overrides);
            errdefer self.container.deinit();

            // KickJS boot order, after services are built: beforeMount,
            // onRouteMount per route, beforeStart. A failure shuts down the
            // adapters already mounted, in reverse.
            self.mounted = 0;
            errdefer self.shutdownAdapters();
            inline for (adapters) |A| {
                if (@hasDecl(A, "beforeMount")) try self.get(A).beforeMount();
                self.mounted += 1;
            }
            inline for (routes) |r| inline for (adapters) |A| {
                if (@hasDecl(A, "onRouteMount")) self.get(A).onRouteMount(.{ .method = r.method, .path = r.path, .handler = r.name });
            };
            inline for (adapters) |A| {
                if (@hasDecl(A, "beforeStart")) try self.get(A).beforeStart();
            }
        }

        /// Adapter `shutdown` in reverse dependency order, then services'
        /// `deinit`. Not for an app whose `init` failed (that cleaned up).
        pub fn deinit(self: *Self) void {
            self.shutdownAdapters();
            self.container.deinit();
            self.config_arena.deinit();
        }

        /// Shutdown has begun: health answers `draining`.
        pub fn beginDrain(self: *Self) void {
            self.get(Process).draining.store(true, .release);
        }

        const checked = blk: {
            var out: []const type = &.{};
            for (adapters) |A| {
                if (@hasDecl(A, "onHealthCheck")) out = out ++ .{A};
            }
            break :blk out;
        };

        /// Probes within a second share one run (KickJS caches 1 s); a run
        /// checks every adapter at once, a check over 2 s counts as down.
        const HealthCache = struct {
            mutex: std.Io.Mutex = .init,
            at_ms: ?i64 = null,
            results: [checked.len]health.HealthCheck = undefined,
        };

        fn healthChecks(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]const health.HealthCheck {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const io = self.get(Process).io;
            const cache = &self.health_cache;
            cache.mutex.lockUncancelable(io);
            defer cache.mutex.unlock(io);
            if (cache.at_ms == null or nowMs(io) - cache.at_ms.? >= 1000) {
                var slots: [checked.len]health.Slot = @splat(.{});
                var group: std.Io.Group = .init;
                inline for (checked, 0..) |A, i| {
                    group.concurrent(io, health.runCheck(A), .{ self.get(A), &slots[i] }) catch
                        slots[i].store(self.get(A).onHealthCheck());
                }
                health.waitAll(io, &slots, 2000);
                group.cancel(io);
                inline for (checked, 0..) |A, i| cache.results[i] = slots[i].get() orelse .{ .name = @typeName(A), .status = .down };
                cache.at_ms = nowMs(io);
            }
            return arena.dupe(health.HealthCheck, &cache.results);
        }

        /// The server is listening: adapter `afterStart`.
        pub fn started(self: *Self, info: adapter_mod.StartInfo) void {
            inline for (adapters) |A| {
                if (@hasDecl(A, "afterStart")) self.get(A).afterStart(info);
            }
        }

        fn shutdownAdapters(self: *Self) void {
            comptime var k = adapters.len;
            inline while (k > 0) {
                k -= 1;
                if (k < self.mounted and @hasDecl(adapters[k], "shutdown")) self.get(adapters[k]).shutdown();
            }
            self.mounted = 0;
        }

        pub fn get(self: *Self, comptime S: type) *S {
            return self.container.get(S);
        }

        pub fn handle(self: *Self, ctx: *Ctx) void {
            ctx.app = self;
            ctx.io = self.get(Process).io;
            ctx.on_error = observeError;
            Routes.handlePhases(global, after_routes, ctx);
            inline for (adapters) |A| {
                if (@hasDecl(A, "onResponse")) self.get(A).onResponse(ctx);
            }
        }

        fn observeError(ctx: *Ctx, err: anyerror) void {
            const self = appOf(Self, ctx);
            inline for (adapters) |A| {
                if (@hasDecl(A, "onError")) self.get(A).onError(ctx, err);
            }
        }
    };
}

fn buildRoutes(comptime AppT: type, comptime modules: []const type, comptime api_prefix: []const u8, comptime default_version: u16, comptime outer: [2][]const type) []const router.Route {
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
                    // `/` under a mount is the mount itself, as in KickJS's joinPaths.
                    const full = if (mount.len > 0 and std.mem.eql(u8, r.path, "/"))
                        mount
                    else if (mount.len + r.path.len == 0) "/" else mount ++ r.path;
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
                        outer[0],
                        outer[1],
                        M.contributors,
                        if (@hasDecl(C, "contributors")) contributor.types(C.contributors, where) else &.{},
                        if (@hasField(@TypeOf(r), "contributors")) contributor.types(r.contributors, where) else &.{},
                    }, contributor.GotOf(@field(C, handler)), where);
                    list = list ++ .{router.Route{ .method = method, .path = full, .handler = thunk(AppT, C, handler, P, chain), .name = owner }};
                    owners = owners ++ .{owner};
                }
            }
        }
        const result = list;
        return result;
    }
}

/// Adapter middleware for one phase, in adapter order. An entry is
/// `.{ .phase = …, .handler = … }`; the phase defaults to `after_global`.
fn phase(comptime AppT: type, comptime adapters: []const type, comptime p: mw.Phase) []const mw.Fn {
    comptime {
        var out: []const mw.Fn = &.{};
        for (adapters) |A| {
            if (!@hasDecl(A, "middleware")) continue;
            for (A.middleware) |entry| {
                const entry_phase: mw.Phase = if (@hasField(@TypeOf(entry), "phase")) entry.phase else .after_global;
                if (entry_phase == p) out = out ++ .{mwFn(AppT, entry.handler, @typeName(A))};
            }
        }
        const result = out;
        return result;
    }
}

fn pluginChain(comptime AppT: type, comptime plugins: []const type) []const mw.Fn {
    comptime {
        var out: []const mw.Fn = &.{};
        for (plugins) |Pl| out = out ++ mwChain(AppT, Pl.middleware, Pl.name);
        const result = out;
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
    const is_fn = switch (@typeInfo(@TypeOf(e))) {
        .@"fn" => true,
        .pointer => |p| @typeInfo(p.child) == .@"fn",
        else => false,
    };
    if (!is_fn) @compileError(bad);
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
            // KickJS request scope + @PreDestroy: whatever was produced is
            // disposed after the response, in reverse, errors included.
            defer contributor.disposeAll(P, app, &store);
            inline for (P.early_order) |K| {
                try contributor.run(K, app.get(K), ctx, &store);
                // A contributor that answered ends the request, as in KickJS.
                if (ctx.res.sent) return;
            }
            try decodeRequest(P, ctx, &store);
            if (chain.len == 0) return late(ctx);
            var next: mw.Next = .{ .ctx = ctx, .chain = chain, .final = late };
            next.run();
        }

        fn late(ctx: *Ctx) anyerror!void {
            const app = appOf(AppT, ctx);
            const store: *P.Store = @ptrCast(@alignCast(ctx.values.?));
            inline for (P.late_order) |K| {
                try contributor.run(K, app.get(K), ctx, store);
                if (ctx.res.sent) return;
            }
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

/// KickJS's `validate()`: body, then query, then params; the first that
/// fails answers 422 with every field error.
fn decodeRequest(comptime P: type, ctx: *Ctx, store: *P.Store) !void {
    if (P.Body) |T| {
        var issues: decode.Issues = .init(ctx.arena);
        store.body = try decode.json(T, ctx.arena, try jsonBody(ctx), &issues) orelse
            return invalid(ctx, issues.list.items[0].message, issues);
    }
    if (P.Query) |T| if (@hasDecl(T, "kzig_list_query")) {
        store.query = try T.parse(ctx);
    } else {
        var issues: decode.Issues = .init(ctx.arena);
        store.query = try decode.strings(T, ctx.arena, QuerySource{ .ctx = ctx }, &issues) orelse
            return invalid(ctx, "Invalid query parameters", issues);
    };
    if (P.Params) |T| {
        var issues: decode.Issues = .init(ctx.arena);
        store.params = try decode.strings(T, ctx.arena, ParamSource{ .ctx = ctx }, &issues) orelse
            return invalid(ctx, "Invalid path parameters", issues);
    }
}

fn invalid(ctx: *Ctx, detail: []const u8, issues: decode.Issues) error{HttpProblem} {
    ctx.problem = .{ .status = .unprocessable_entity, .detail = detail, .errors = issues.list.items };
    return error.HttpProblem;
}

/// A JSON content type parses (malformed → 400); anything else, or nothing,
/// is `{}`, as `express.json()` leaves it for the schema to reject.
fn jsonBody(ctx: *Ctx) !std.json.Value {
    if (!isJsonMediaType(ctx.header("content-type") orelse "") or ctx.req.body.len == 0) return .{ .object = .empty };
    return std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, ctx.req.body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => ctx.fail(.bad_request, "Malformed JSON"),
    };
}

/// `application/json` or `application/<x>+json`, parameters ignored —
/// never `text/*`: a `text/plain` POST needs no CORS preflight, so parsing it
/// would let any site send JSON cross-origin (KickJS `isJsonMediaType`).
fn isJsonMediaType(content_type: []const u8) bool {
    const media = std.mem.trim(u8, content_type[0 .. std.mem.findScalar(u8, content_type, ';') orelse content_type.len], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return true;
    const sub = if (std.ascii.startsWithIgnoreCase(media, "application/")) media["application/".len..] else return false;
    return sub.len > "+json".len and std.ascii.endsWithIgnoreCase(sub, "+json") and
        std.mem.findAny(u8, sub, "/ \t") == null;
}

const QuerySource = struct {
    ctx: *Ctx,
    pub fn first(self: QuerySource, name: []const u8) ?[]const u8 {
        return self.ctx.query(name) catch null;
    }
    pub fn all(self: QuerySource, _: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        return self.ctx.queryAll(name);
    }
};

const ParamSource = struct {
    ctx: *Ctx,
    pub fn first(self: ParamSource, name: []const u8) ?[]const u8 {
        return self.ctx.param(name);
    }
    pub fn all(self: ParamSource, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        const v = self.ctx.param(name) orelse return &.{};
        return arena.dupe([]const u8, &.{v});
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).toNanoseconds(), std.time.ns_per_ms));
}

fn appOf(comptime AppT: type, ctx: *Ctx) *AppT {
    return @ptrCast(@alignCast(ctx.app.?));
}

/// The field of `Overrides` holding a value of type `S`, if any.
fn overrideOf(comptime Overrides: type, comptime S: type) ?[]const u8 {
    const info = @typeInfo(Overrides).@"struct";
    for (info.field_names, info.field_types) |f, T| if (T == S) return f;
    return null;
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
        return .{ .message = try ctx.arena.print("{s} world", .{self.greeter.word}) };
    }
    pub fn named(self: *HelloController, ctx: *Ctx) !struct { message: []const u8 } {
        return .{ .message = try ctx.arena.print("{s} {s}", .{ self.greeter.word, ctx.param("name").? }) };
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
    try ctx.setHeader("x-trail", if (prev) |p| try ctx.arena.print("{s},{s}", .{ p, m }) else m);
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

// Services are shared by concurrent requests: shared state needs atomics or a lock.
const Counter = struct { hits: std.atomic.Value(u32) = .init(0) };

/// Struct middleware: a service with DI fields.
const CountHits = struct {
    counter: *Counter,
    pub fn handle(self: *CountHits, ctx: *Ctx, next: *kzig_mw.Next) !void {
        const n = self.counter.hits.fetchAdd(1, .monotonic) + 1;
        try ctx.setHeader("x-hits", try ctx.arena.print("{d}", .{n}));
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
    try testing.expectEqual(2, app.get(Counter).hits.load(.monotonic));
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
        return ctx.arena.print("{s}/{s}", .{ got.tenant.id, ctx.param("id").? });
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

const Deny = struct {
    pub const key = "deny";
    pub fn resolve(_: *Deny, ctx: *Ctx) !void {
        ctx.status(.forbidden);
        try ctx.text("denied");
    }
};

const DenyEarly = struct {
    pub const key = "deny_early";
    pub const before_validation = true;
    pub fn resolve(_: *DenyEarly, ctx: *Ctx) !void {
        ctx.status(.forbidden);
        try ctx.text("denied early");
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
        .{ .method = .GET, .path = "/deny", .handler = "order", .contributors = .{Deny} },
        .{ .method = .GET, .path = "/deny-early", .handler = "order", .contributors = .{DenyEarly}, .middleware = .{Mw.route} },
    };
    pub fn project(_: *ContribController, _: *Ctx, got: struct { project: []const u8 }) []const u8 {
        return got.project;
    }
    pub fn label(_: *ContribController, _: *Ctx, got: struct { label: []const u8 }) []const u8 {
        return got.label;
    }
    pub fn levels(_: *ContribController, ctx: *Ctx, got: struct { module_v: []const u8, global_v: []const u8 }) ![]const u8 {
        return ctx.arena.print("{s},{s}", .{ got.module_v, got.global_v });
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
    try testing.expect(std.mem.find(u8, a.body, "Unknown tenant") != null);
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

test "a contributor that responds skips the handler" {
    var a = try contribGet("/api/v1/c/deny", acme);
    defer a.deinit();
    try testing.expectEqual(std.http.Status.forbidden, a.status);
    try testing.expectEqualStrings("denied", a.body);
    var b = try contribGet("/api/v1/c/deny-early", acme);
    defer b.deinit();
    try testing.expectEqualStrings("denied early", b.body);
    try testing.expectEqual(null, b.header("x-trail"));
}

const CreateThing = struct {
    title: []const u8,
    tags: []const []const u8 = &.{},
    pub fn validate(self: *const CreateThing, issues: *@import("decode.zig").Issues) !void {
        if (self.title.len == 0) try issues.add("title", "must not be empty");
    }
};

const LoadOwner = struct {
    pub const key = "owner";
    pub fn resolve(_: *LoadOwner, _: *Ctx, got: struct { body: CreateThing }) []const u8 {
        return got.body.title;
    }
};

const BodyController = struct {
    pub const routes = .{
        .{ .method = .POST, .path = "/things", .handler = "create" },
        .{ .method = .GET, .path = "/things/:id", .handler = "show" },
        .{ .method = .POST, .path = "/owned", .handler = "owned", .contributors = .{LoadOwner} },
    };
    pub fn create(_: *BodyController, ctx: *Ctx, got: struct { body: CreateThing }) !void {
        try ctx.created(.{ .title = got.body.title, .tags = got.body.tags.len });
    }
    pub fn show(_: *BodyController, ctx: *Ctx, got: struct { params: struct { id: u32 }, query: struct { verbose: bool = false } }) ![]const u8 {
        return ctx.arena.print("{d}:{}", .{ got.params.id, got.query.verbose });
    }
    pub fn owned(_: *BodyController, _: *Ctx, got: struct { owner: []const u8 }) []const u8 {
        return got.owner;
    }
};

const BodyApp = App(.{ .modules = &.{Module(.{ .name = "BodyModule", .controllers = &.{BodyController} })} });

fn bodyReq(method: std.http.Method, target: []const u8, content_type: ?[]const u8, body: []const u8) !testing_rt.TestResponse {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const app = try testing.allocator.create(BodyApp);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    const headers: []const context.Header = if (content_type) |ct| &.{.{ .name = "content-type", .value = ct }} else &.{};
    return testing_rt.request(testing.allocator, app, .{ .method = method, .target = target, .headers = headers, .body = body });
}

test "typed body reaches the handler" {
    var a = try bodyReq(.POST, "/api/v1/things", "application/json", "{\"title\":\"x\",\"tags\":[\"a\",\"b\"]}");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.created, a.status);
    try testing.expectEqualStrings("{\"title\":\"x\",\"tags\":2}", a.body);
}

test "invalid body is 422 with field errors" {
    var a = try bodyReq(.POST, "/api/v1/things", "application/json; charset=utf-8", "{\"title\":1,\"tags\":[\"a\",2]}");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.unprocessable_entity, a.status);
    try testing.expectEqualStrings(
        "{\"type\":\"about:blank\",\"title\":\"Unprocessable Entity\",\"status\":422,\"detail\":\"expected string\"," ++
            "\"errors\":[{\"field\":\"title\",\"message\":\"expected string\"},{\"field\":\"tags.1\",\"message\":\"expected string\"}]}",
        a.body,
    );
}

test "custom validation is 422" {
    var a = try bodyReq(.POST, "/api/v1/things", "application/json", "{\"title\":\"\"}");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.unprocessable_entity, a.status);
    try testing.expect(std.mem.find(u8, a.body, "must not be empty") != null);
}

test "malformed JSON is 400" {
    var a = try bodyReq(.POST, "/api/v1/things", "application/json", "{\"title\":");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.bad_request, a.status);
}

test "non-JSON body decodes as {}" {
    var a = try bodyReq(.POST, "/api/v1/things", "text/plain", "title=x");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.unprocessable_entity, a.status);
    try testing.expect(std.mem.find(u8, a.body, "{\"field\":\"title\",\"message\":\"required\"}") != null);
}

test "typed query and params" {
    var a = try bodyReq(.GET, "/api/v1/things/7?verbose=true", null, "");
    defer a.deinit();
    try testing.expectEqualStrings("7:true", a.body);
}

test "bad query or params is 422" {
    var a = try bodyReq(.GET, "/api/v1/things/7?verbose=maybe", null, "");
    defer a.deinit();
    try testing.expectEqual(std.http.Status.unprocessable_entity, a.status);
    try testing.expect(std.mem.find(u8, a.body, "\"detail\":\"Invalid query parameters\"") != null);
    var b = try bodyReq(.GET, "/api/v1/things/x", null, "");
    defer b.deinit();
    try testing.expect(std.mem.find(u8, b.body, "\"detail\":\"Invalid path parameters\"") != null);
}

test "a late contributor reads the body" {
    var a = try bodyReq(.POST, "/api/v1/owned", "application/json", "{\"title\":\"mine\"}");
    defer a.deinit();
    try testing.expectEqualStrings("mine", a.body);
}

const MailSettings = struct {
    pub const prefix = "MAIL";
    host: []const u8 = "localhost",
    password: []const u8,
};

const AppLevelSettings = struct {
    pub const prefix = "APP";
    name: []const u8 = "task-api",
};

const MailController = struct {
    mail: *const MailSettings,
    app: *const AppLevelSettings,
    report: *const ConfigReport,
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "show" }};
    pub fn show(self: *MailController, ctx: *Ctx) ![]const u8 {
        return ctx.arena.print("{s}@{s}/{s}/{d}", .{ self.mail.password, self.mail.host, self.app.name, self.report.vars.len });
    }
};

const RequiredConfig = struct { database_url: []const u8 };

const SettingsApp = App(.{
    .modules = &.{Module(.{ .name = "MailModule", .path = "/mail", .controllers = &.{MailController}, .settings = &.{MailSettings} })},
    .settings = &.{AppLevelSettings},
    .config = RequiredConfig,
});

test "module and app settings are read from env and injectable" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("MAIL_PASSWORD", "pw");
    try env.put("APP_NAME", "demo");
    try env.put("DATABASE_URL", "postgres://x");
    const app = try testing.allocator.create(SettingsApp);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    var a = try testing_rt.request(testing.allocator, app, .{ .target = "/api/v1/mail" });
    defer a.deinit();
    try testing.expectEqualStrings("pw@localhost/demo/4", a.body);
    const report = app.get(ConfigReport);
    try testing.expectEqualStrings("DATABASE_URL", report.vars[0].name);
    try testing.expectEqual(config.Origin.Kind.env, report.vars[0].origin);
}

test "every section's problems fail boot together" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const app = try testing.allocator.create(SettingsApp);
    defer testing.allocator.destroy(app);
    try testing.expectError(error.InvalidConfig, app.init(testing.io, testing.allocator, &env));
}

test "an overridden section or Config skips env" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const app = try testing.allocator.create(SettingsApp);
    defer testing.allocator.destroy(app);
    try app.initWith(testing.io, testing.allocator, &env, .{ MailSettings{ .password = "fake" }, RequiredConfig{ .database_url = "mem" } });
    defer app.deinit();
    try testing.expectEqualStrings("fake", app.get(MailSettings).password);
    try testing.expectEqual(config.Origin.Kind.provided, app.get(ConfigReport).vars[0].origin);
}

test "only JSON media types are parsed as JSON" {
    // text/plain is a CORS simple request (no preflight); parsing it would
    // let any site post JSON cross-origin.
    for ([_][]const u8{ "text/plain; x=+json", "application/jsonp", "application/json-seq", "text/plain" }) |ct| {
        var a = try bodyReq(.POST, "/api/v1/things", ct, "{\"title\":\"x\"}");
        defer a.deinit();
        try testing.expectEqual(std.http.Status.unprocessable_entity, a.status);
    }
    for ([_][]const u8{ "application/json", "Application/JSON ; charset=utf-8", "application/problem+json", "application/vnd.api+json" }) |ct| {
        var a = try bodyReq(.POST, "/api/v1/things", ct, "{\"title\":\"x\"}");
        defer a.deinit();
        try testing.expectEqual(std.http.Status.created, a.status);
    }
}

const DisposeLog = struct { buf: [64]u8 = undefined, len: usize = 0 };

fn Session(comptime k: []const u8, comptime fail: bool) type {
    return struct {
        pub const key = k;
        pub const optional = fail;
        log: *DisposeLog,
        pub fn resolve(_: *@This(), _: *Ctx) !u8 {
            if (fail) return error.Nope;
            return k[0];
        }
        pub fn dispose(self: *@This(), value: *u8) void {
            self.log.buf[self.log.len] = value.*;
            self.log.len += 1;
        }
    };
}

const SessionA = Session("a", false);
const SessionB = struct {
    pub const key = "b";
    log: *DisposeLog,
    pub fn resolve(_: *SessionB, _: *Ctx, got: struct { a: u8 }) u8 {
        return got.a + 1;
    }
    pub fn dispose(self: *SessionB, value: *u8) void {
        self.log.buf[self.log.len] = value.*;
        self.log.len += 1;
    }
};

const DisposeController = struct {
    pub const contributors = .{ SessionB, SessionA, Session("x", true) };
    pub const routes = .{
        .{ .method = .GET, .path = "/ok", .handler = "ok" },
        .{ .method = .GET, .path = "/fail", .handler = "fail" },
    };
    pub fn ok(_: *DisposeController, _: *Ctx, got: struct { b: u8 }) u8 {
        return got.b;
    }
    pub fn fail(_: *DisposeController, _: *Ctx) !void {
        return error.Conflict;
    }
};

const DisposeApp = App(.{ .modules = &.{Module(.{ .name = "D", .controllers = &.{DisposeController}, .services = &.{DisposeLog} })}, .health = false });

fn disposeRun(target: []const u8) ![]const u8 {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var app: DisposeApp = undefined;
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    var res = try testing_rt.request(testing.allocator, &app, .{ .target = target });
    res.deinit();
    const log = app.get(DisposeLog);
    return try testing.allocator.dupe(u8, log.buf[0..log.len]);
}

test "dispose runs in reverse after the handler" {
    const got = try disposeRun("/api/v1/ok");
    defer testing.allocator.free(got);
    // a ran before b; b ('a' + 1 = 'b') is disposed first. The failed optional x is skipped.
    try testing.expectEqualStrings("ba", got);
}

test "dispose runs when the handler fails" {
    const got = try disposeRun("/api/v1/fail");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ba", got);
}
