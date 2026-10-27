//! App config from environment variables, the way KickJS's `loadEnv` reads a
//! schema: every field of a struct from its upper-cased name, defaults from
//! the field defaults, and every bad key reported at once.
const std = @import("std");

const builtin = @import("builtin");
const decode = @import("decode.zig");

pub const Issue = struct {
    key: []const u8,
    reason: []const u8,
};

/// Where a variable's value came from (KickJS `configOrigins()`).
pub const Origin = struct {
    pub const Kind = enum { env, file, default, dev_default, provided, unset };
    name: []const u8,
    section: []const u8,
    origin: Kind,
    required: bool,
};

/// Reads `T` from `env`, logging every issue; see `parse`.
pub fn load(comptime T: type, arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{ InvalidConfig, OutOfMemory }!T {
    var issues: std.ArrayList(Issue) = .empty;
    return parse(T, arena, env, &issues) catch |err| {
        if (!builtin.is_test) logIssues(T, issues.items);
        return err;
    };
}

/// `parseSection` without `_FILE` support or origins.
pub fn parse(comptime T: type, arena: std.mem.Allocator, env: *const std.process.Environ.Map, issues: *std.ArrayList(Issue)) error{ InvalidConfig, OutOfMemory }!T {
    return parseSection(T, arena, null, env, issues, null);
}

/// Logs a section's issues the way KickJS reports invalid settings.
pub fn logIssues(comptime T: type, issues: []const Issue) void {
    if (sectionName(T).len > 0)
        std.log.err("Settings '{s}' are invalid:", .{sectionName(T)})
    else
        std.log.err("Config is invalid:", .{});
    for (issues) |i| std.log.err("  {s}: {s}", .{ i.key, i.reason });
}

pub fn sectionName(comptime T: type) []const u8 {
    return if (@hasDecl(T, "prefix")) T.prefix else "";
}

/// Fills section `T` (KickJS `defineSettings`) field by field: `PREFIX_FIELD`
/// (`beta_testers` reads `FEATURES_BETA_TESTERS`), else `PREFIX_FIELD_FILE`
/// (a mounted secret, trailing newline dropped; needs `io`), else the field
/// default, else `T.dev_defaults` when `NODE_ENV` is development or test —
/// so secrets fail closed in production. Lists are comma-separated.
/// Collects every problem into `issues` (allocated in `arena`) before failing.
pub fn parseSection(
    comptime T: type,
    arena: std.mem.Allocator,
    io: ?std.Io,
    env: *const std.process.Environ.Map,
    issues: *std.ArrayList(Issue),
    origins: ?*std.ArrayList(Origin),
) error{ InvalidConfig, OutOfMemory }!T {
    const info = @typeInfo(T).@"struct";
    const dev = devOrTest(env);
    const before = issues.items.len;
    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const key = comptime envKey(sectionName(T), name);
        const default = comptime attrs.defaultValue(F);
        const dev_default = comptime devDefault(T, name, F);
        var origin: Origin.Kind = .unset;
        var raw: ?[]const u8 = null;
        if (env.get(key)) |v| {
            raw = v;
            origin = .env;
        } else if (env.get(key ++ "_FILE")) |path| {
            if (readSecret(arena, io, path)) |v| {
                raw = v;
                origin = .file;
            } else try issues.append(arena, .{ .key = key, .reason = try std.fmt.allocPrint(arena, "cannot read {s}", .{path}) });
        }
        if (raw) |r| {
            if (parseField(F, arena, r)) |v| {
                // `env` may be freed after boot; strings must outlive it.
                @field(out, name) = try own(F, arena, v);
            } else |_| {
                try issues.append(arena, .{ .key = key, .reason = "expected " ++ comptime typeLabel(F) });
            }
        } else if (origin == .unset) {
            if (default) |d| {
                @field(out, name) = d;
                origin = .default;
            } else if (dev_default != null and dev) {
                @field(out, name) = dev_default.?;
                origin = .dev_default;
            } else if (@typeInfo(F) == .optional) {
                @field(out, name) = null;
            } else {
                try issues.append(arena, .{ .key = key, .reason = "required" });
            }
        }
        if (origins) |o| try o.append(arena, .{
            .name = key,
            .section = sectionName(T),
            .origin = origin,
            .required = default == null and @typeInfo(F) != .optional and !(dev_default != null and dev),
        });
    }
    if (issues.items.len > before) return error.InvalidConfig;
    return out;
}

/// Origins of a section supplied as an override instead of read from env.
pub fn providedOrigins(comptime T: type, arena: std.mem.Allocator, origins: *std.ArrayList(Origin)) !void {
    inline for (@typeInfo(T).@"struct".field_names) |name|
        try origins.append(arena, .{ .name = comptime envKey(sectionName(T), name), .section = sectionName(T), .origin = .provided, .required = false });
}

pub fn devOrTest(env: *const std.process.Environ.Map) bool {
    const e = env.get("NODE_ENV") orelse return false;
    return std.mem.eql(u8, e, "development") or std.mem.eql(u8, e, "test");
}

fn devDefault(comptime T: type, comptime name: []const u8, comptime F: type) ?F {
    if (!@hasDecl(T, "dev_defaults") or !@hasField(@TypeOf(T.dev_defaults), name)) return null;
    return @field(T.dev_defaults, name);
}

fn readSecret(arena: std.mem.Allocator, io: ?std.Io, path: []const u8) ?[]const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io orelse return null, path, arena, .limited(64 * 1024)) catch return null;
    return std.mem.trimEnd(u8, data, "\r\n");
}

fn isList(comptime F: type) bool {
    return @typeInfo(F) == .pointer and F != []const u8;
}

fn parseField(comptime F: type, arena: std.mem.Allocator, raw: []const u8) !F {
    if (comptime isList(F)) {
        const C = @typeInfo(F).pointer.child;
        var out: std.ArrayList(C) = .empty;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const item = std.mem.trim(u8, part, " \t");
            if (item.len == 0) continue;
            try out.append(arena, decode.scalar(C, item) orelse return error.Invalid);
        }
        return out.items;
    }
    return decode.scalar(F, raw) orelse error.Invalid;
}

fn own(comptime F: type, arena: std.mem.Allocator, v: F) !F {
    if (F == []const u8) return arena.dupe(u8, v);
    if (F == ?[]const u8) return try arena.dupe(u8, v.?);
    if (F == []const []const u8) {
        const out = try arena.alloc([]const u8, v.len);
        for (v, out) |s, *o| o.* = try arena.dupe(u8, s);
        return out;
    }
    return v;
}

fn envKey(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        const upper = buf;
        return if (prefix.len > 0) prefix ++ "_" ++ upper else &upper;
    }
}

fn typeLabel(comptime F: type) []const u8 {
    if (comptime isList(F)) return "a comma-separated list of " ++ comptime typeLabel(@typeInfo(F).pointer.child);
    return comptime decode.label(F)["expected ".len..];
}

const testing = std.testing;

fn envOf(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

const Mode = enum { development, production, @"test" };

test "defaults apply when env is empty" {
    var env = try envOf(&.{});
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    const C = struct { port: u16 = 3000, log_level: []const u8 = "info", node_env: Mode = .development };
    const c = try parse(C, arena.allocator(), &env, &issues);
    try testing.expectEqual(3000, c.port);
    try testing.expectEqualStrings("info", c.log_level);
    try testing.expectEqual(Mode.development, c.node_env);
}

test "values parse by type" {
    var env = try envOf(&.{
        .{ "PORT", "8080" }, .{ "RATIO", "0.5" },           .{ "DEBUG", "true" },
        .{ "NAME", "kzig" }, .{ "NODE_ENV", "production" }, .{ "LIMIT", "7" },
        .{ "VERBOSE", "0" },
    });
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    const C = struct {
        port: u16 = 3000,
        ratio: f64 = 1,
        debug: bool = false,
        verbose: bool = true,
        name: []const u8,
        node_env: Mode = .development,
        limit: ?u32 = null,
        missing: ?u32 = null,
    };
    const c = try parse(C, arena.allocator(), &env, &issues);
    try testing.expectEqual(8080, c.port);
    try testing.expectEqual(0.5, c.ratio);
    try testing.expect(c.debug);
    try testing.expect(!c.verbose);
    try testing.expectEqualStrings("kzig", c.name);
    try testing.expectEqual(Mode.production, c.node_env);
    try testing.expectEqual(7, c.limit.?);
    try testing.expectEqual(null, c.missing);
}

test "all bad keys are reported at once" {
    var env = try envOf(&.{.{ "PORT", "abc" }});
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    const C = struct { port: u16 = 3000, database_url: []const u8 };
    try testing.expectError(error.InvalidConfig, parse(C, arena.allocator(), &env, &issues));
    try testing.expectEqual(2, issues.items.len);
    try testing.expectEqualStrings("PORT", issues.items[0].key);
    try testing.expectEqualStrings("DATABASE_URL", issues.items[1].key);
    try testing.expectEqualStrings("required", issues.items[1].reason);
}

test "string values outlive env" {
    var env = try envOf(&.{.{ "NAME", "kzig" }});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    const c = try parse(struct { name: []const u8, alias: ?[]const u8 = null }, arena.allocator(), &env, &issues);
    const name_ptr = env.get("NAME").?.ptr;
    env.deinit();
    try testing.expect(c.name.ptr != name_ptr);
    try testing.expectEqualStrings("kzig", c.name);
}

test "empty value is invalid for numbers" {
    var env = try envOf(&.{.{ "PORT", "" }});
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    try testing.expectError(error.InvalidConfig, parse(struct { port: u16 = 3000 }, arena.allocator(), &env, &issues));
    try testing.expectEqualStrings("PORT", issues.items[0].key);
}

const FeatureSettings = struct {
    pub const prefix = "FEATURES";
    signups: bool = true,
    max_upload_mb: u32 = 10,
    beta_testers: []const []const u8 = &.{},
    password: []const u8,
};

test "section reads prefixed keys and comma lists" {
    var env = try envOf(&.{
        .{ "FEATURES_SIGNUPS", "false" },
        .{ "FEATURES_BETA_TESTERS", "ann@example.com, bob@example.com" },
        .{ "FEATURES_PASSWORD", "x" },
        .{ "SIGNUPS", "true" },
    });
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    var origins: std.ArrayList(Origin) = .empty;
    const f = try parseSection(FeatureSettings, arena.allocator(), null, &env, &issues, &origins);
    try testing.expect(!f.signups);
    try testing.expectEqual(10, f.max_upload_mb);
    try testing.expectEqual(2, f.beta_testers.len);
    try testing.expectEqualStrings("bob@example.com", f.beta_testers[1]);
    try testing.expectEqualStrings("FEATURES_SIGNUPS", origins.items[0].name);
    try testing.expectEqual(Origin.Kind.env, origins.items[0].origin);
    try testing.expectEqual(Origin.Kind.default, origins.items[1].origin);
    try testing.expect(origins.items[3].required);
}

test "_FILE secret" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret", .data = "s3cret\n" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, "secret", arena.allocator());
    var env = try envOf(&.{.{ "FEATURES_PASSWORD_FILE", path }});
    defer env.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    var origins: std.ArrayList(Origin) = .empty;
    const f = try parseSection(FeatureSettings, arena.allocator(), testing.io, &env, &issues, &origins);
    try testing.expectEqualStrings("s3cret", f.password);
    try testing.expectEqual(Origin.Kind.file, origins.items[3].origin);
}

test "missing _FILE is an issue" {
    var env = try envOf(&.{.{ "FEATURES_PASSWORD_FILE", "/nonexistent/kzig-secret" }});
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    var origins: std.ArrayList(Origin) = .empty;
    try testing.expectError(error.InvalidConfig, parseSection(FeatureSettings, arena.allocator(), testing.io, &env, &issues, &origins));
    try testing.expectEqualStrings("FEATURES_PASSWORD", issues.items[0].key);
    try testing.expectEqualStrings("cannot read /nonexistent/kzig-secret", issues.items[0].reason);
}

const AppSettings = struct {
    pub const prefix = "APP";
    pub const dev_defaults = .{ .public_url = "http://localhost:3000" };
    name: []const u8 = "task-api",
    public_url: []const u8,
};

test "dev default applies only in development" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var dev = try envOf(&.{.{ "NODE_ENV", "test" }});
    defer dev.deinit();
    var issues: std.ArrayList(Issue) = .empty;
    var origins: std.ArrayList(Origin) = .empty;
    const a = try parseSection(AppSettings, arena.allocator(), null, &dev, &issues, &origins);
    try testing.expectEqualStrings("http://localhost:3000", a.public_url);
    try testing.expectEqual(Origin.Kind.dev_default, origins.items[1].origin);

    for ([_][]const [2][]const u8{ &.{.{ "NODE_ENV", "production" }}, &.{} }) |pairs| {
        var prod = try envOf(pairs);
        defer prod.deinit();
        var issues2: std.ArrayList(Issue) = .empty;
        try testing.expectError(error.InvalidConfig, parseSection(AppSettings, arena.allocator(), null, &prod, &issues2, null));
        try testing.expectEqualStrings("APP_PUBLIC_URL", issues2.items[0].key);
    }
}
