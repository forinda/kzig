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

/// Reads `T` from `env`, logging every issue; see `parse`.
pub fn load(comptime T: type, arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{ InvalidConfig, OutOfMemory }!T {
    var issues: std.ArrayList(Issue) = .empty;
    return parse(T, arena, env, &issues) catch |err| {
        if (!builtin.is_test) for (issues.items) |i| std.log.err("config: {s}: {s}", .{ i.key, i.reason });
        return err;
    };
}

/// Fills `T` field by field from `env` (`log_level` reads `LOG_LEVEL`).
/// Collects every problem into `issues` (allocated in `arena`) before
/// failing, so one boot shows all of them.
pub fn parse(comptime T: type, arena: std.mem.Allocator, env: *const std.process.Environ.Map, issues: *std.ArrayList(Issue)) error{ InvalidConfig, OutOfMemory }!T {
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const key = comptime envKey(name);
        const default = comptime attrs.defaultValue(F);
        if (env.get(key)) |raw| {
            if (parseValue(F, raw)) |v| {
                // `env` may be freed after boot; strings must outlive it.
                @field(out, name) = if (F == []const u8)
                    try arena.dupe(u8, v)
                else if (F == ?[]const u8)
                    try arena.dupe(u8, v.?)
                else
                    v;
            } else {
                try issues.append(arena, .{ .key = key, .reason = "expected " ++ comptime typeLabel(F) });
            }
        } else if (default) |d| {
            @field(out, name) = d;
        } else if (@typeInfo(F) == .optional) {
            @field(out, name) = null;
        } else {
            try issues.append(arena, .{ .key = key, .reason = "required" });
        }
    }
    if (issues.items.len > 0) return error.InvalidConfig;
    return out;
}

fn envKey(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        const result = buf;
        return &result;
    }
}

fn parseValue(comptime F: type, raw: []const u8) ?F {
    return decode.scalar(F, raw);
}

fn typeLabel(comptime F: type) []const u8 {
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
