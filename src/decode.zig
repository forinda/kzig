//! Request data into Zig types, collecting every problem with its field path
//! — zod's `safeParse` for the shapes a Zig type can express. Custom rules
//! go in `pub fn validate(self: *const T, issues: *Issues) !void`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FieldError = struct {
    field: []const u8,
    message: []const u8,
};

pub const Issues = struct {
    arena: Allocator,
    list: std.ArrayList(FieldError) = .empty,
    /// Path of the struct whose `validate` is running.
    prefix: []const u8 = "",

    pub fn init(arena: Allocator) Issues {
        return .{ .arena = arena };
    }

    /// Records a problem with `field`, relative to the current struct.
    pub fn add(self: *Issues, field: []const u8, message: []const u8) !void {
        const full = if (self.prefix.len == 0)
            field
        else if (field.len == 0)
            self.prefix
        else
            try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ self.prefix, field });
        try self.list.append(self.arena, .{ .field = full, .message = message });
    }

    fn at(self: *Issues, path: ?*const Path, message: []const u8) !void {
        try self.list.append(self.arena, .{ .field = try render(self.arena, path), .message = message });
    }
};

/// Built only when there is an issue to report, so decoding a large array
/// doesn't build a path string per element.
const Path = struct {
    parent: ?*const Path,
    seg: union(enum) { field: []const u8, index: usize },
};

fn render(arena: Allocator, path: ?*const Path) ![]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    var p = path;
    while (p) |node| : (p = node.parent) try segs.append(arena, switch (node.seg) {
        .field => |f| f,
        .index => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
    });
    std.mem.reverse([]const u8, segs.items);
    return std.mem.join(arena, ".", segs.items);
}

/// Decodes `value` into `T`; null if `issues` gained any entry.
pub fn json(comptime T: type, arena: Allocator, value: std.json.Value, issues: *Issues) !?T {
    const before = issues.list.items.len;
    const out = try fromJson(T, arena, value, null, issues);
    return if (issues.list.items.len > before) null else out;
}

fn fromJson(comptime T: type, arena: Allocator, v: std.json.Value, path: ?*const Path, issues: *Issues) !T {
    switch (@typeInfo(T)) {
        .optional => |o| return if (v == .null) null else try fromJson(o.child, arena, v, path, issues),
        .bool => if (v == .bool) return v.bool,
        .int => switch (v) {
            .integer => |i| return std.math.cast(T, i) orelse {
                try issues.at(path, "out of range");
                return undefined;
            },
            .number_string => |n| return std.fmt.parseInt(T, n, 10) catch {
                try issues.at(path, "out of range");
                return undefined;
            },
            else => {},
        },
        // Non-finite values (1e400, 1e300 into f32) can't be sent back as JSON.
        .float => switch (v) {
            .integer => |i| return @floatFromInt(i),
            .float => |f| if (std.math.isFinite(@as(T, @floatCast(f)))) return @floatCast(f),
            .number_string => |n| if (std.fmt.parseFloat(T, n)) |f| {
                if (std.math.isFinite(f)) return f;
            } else |_| {},
            else => {},
        },
        .@"enum" => if (v == .string) if (std.meta.stringToEnum(T, v.string)) |e| return e,
        .pointer => |p| {
            if (p.size != .slice) @compileError("cannot decode " ++ @typeName(T));
            if (p.child == u8) {
                if (v == .string) return v.string;
            } else if (v == .array) {
                const out = try arena.alloc(p.child, v.array.items.len);
                for (v.array.items, out, 0..) |item, *slot, i| {
                    const node: Path = .{ .parent = path, .seg = .{ .index = i } };
                    slot.* = try fromJson(p.child, arena, item, &node, issues);
                }
                return out;
            }
        },
        .@"struct" => |info| if (v == .object) {
            const before = issues.list.items.len;
            var out: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
                const node: Path = .{ .parent = path, .seg = .{ .field = name } };
                if (v.object.get(name)) |fv| {
                    @field(out, name) = try fromJson(F, arena, fv, &node, issues);
                } else if (comptime attrs.defaultValue(F)) |d| {
                    @field(out, name) = d;
                } else if (@typeInfo(F) == .optional) {
                    @field(out, name) = null;
                } else {
                    try issues.at(&node, "required");
                }
            }
            if (issues.list.items.len == before) try runValidate(T, &out, path, issues);
            return out;
        },
        else => @compileError("cannot decode " ++ @typeName(T)),
    }
    try issues.at(path, label(T));
    return undefined;
}

fn runValidate(comptime T: type, value: *const T, path: ?*const Path, issues: *Issues) !void {
    if (!@hasDecl(T, "validate")) return;
    const saved = issues.prefix;
    defer issues.prefix = saved;
    issues.prefix = try render(issues.arena, path);
    try value.validate(issues);
}

/// Decodes a struct from string values: `src.first(name) ?[]const u8`, and
/// `src.all(arena, name) ![]const []const u8` for slice fields (repeated
/// keys). Used for query strings and path params.
pub fn strings(comptime T: type, arena: Allocator, src: anytype, issues: *Issues) !?T {
    const before = issues.list.items.len;
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const node: Path = .{ .parent = null, .seg = .{ .field = name } };
        const is_list = comptime @typeInfo(F) == .pointer and F != []const u8;
        if (is_list) {
            const C = @typeInfo(F).pointer.child;
            const raw = try src.all(arena, name);
            const list = try arena.alloc(C, raw.len);
            for (raw, list, 0..) |r, *slot, i| {
                const item: Path = .{ .parent = &node, .seg = .{ .index = i } };
                if (scalar(C, r)) |x| slot.* = x else try issues.at(&item, label(C));
            }
            @field(out, name) = if (raw.len == 0) (comptime attrs.defaultValue(F)) orelse list else list;
        } else if (src.first(name)) |raw| {
            if (scalar(F, raw)) |x| @field(out, name) = x else try issues.at(&node, label(F));
        } else if (comptime attrs.defaultValue(F)) |d| {
            @field(out, name) = d;
        } else if (@typeInfo(F) == .optional) {
            @field(out, name) = null;
        } else {
            try issues.at(&node, "required");
        }
    }
    if (issues.list.items.len > before) return null;
    try runValidate(T, &out, null, issues);
    return if (issues.list.items.len > before) null else out;
}

/// One value from a string, strictly: no `1_000`, no `inf`/`nan`; booleans
/// are `true/false/1/0` in any case.
pub fn scalar(comptime F: type, raw: []const u8) ?F {
    return switch (@typeInfo(F)) {
        .int => if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, '_') != null) null else std.fmt.parseInt(F, raw, 10) catch null,
        .float => blk: {
            const f = std.fmt.parseFloat(F, raw) catch break :blk null;
            break :blk if (std.math.isFinite(f)) f else null;
        },
        .bool => if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1"))
            true
        else if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0"))
            false
        else
            null,
        .@"enum" => std.meta.stringToEnum(F, raw),
        .optional => |o| if (scalar(o.child, raw)) |v| @as(F, v) else null,
        .pointer => if (F == []const u8) raw else @compileError("cannot decode " ++ @typeName(F) ++ " from a string"),
        else => @compileError("cannot decode " ++ @typeName(F) ++ " from a string"),
    };
}

/// What a value of `F` should look like, for issue messages.
pub fn label(comptime F: type) []const u8 {
    return comptime switch (@typeInfo(F)) {
        .int => "expected integer",
        .float => "expected number",
        .bool => "expected boolean",
        .@"enum" => "expected one of " ++ enumNames(F),
        .optional => |o| label(o.child),
        .@"struct" => "expected object",
        .pointer => if (F == []const u8) "expected string" else "expected array",
        else => "expected " ++ @typeName(F),
    };
}

fn enumNames(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".field_names, 0..) |n, i| out = out ++ (if (i > 0) ", " else "") ++ n;
        const result = out;
        return result;
    }
}

const testing = std.testing;

fn parseJson(arena: std.mem.Allocator, src: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{});
}

const Tag = enum { red, green };
const Item = struct {
    name: []const u8,
    qty: u32 = 1,
    pub fn validate(self: *const Item, issues: *Issues) !void {
        if (self.name.len == 0) try issues.add("name", "must not be empty");
    }
};
const Order = struct {
    id: u64,
    note: ?[]const u8 = null,
    ratio: f64 = 1,
    rush: bool = false,
    tag: Tag = .red,
    items: []const Item,
};

test "decodes nested structs, slices and defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    const v = try parseJson(a, "{\"id\":7,\"tag\":\"green\",\"ratio\":2,\"items\":[{\"name\":\"x\"},{\"name\":\"y\",\"qty\":3}]}");
    const o = (try json(Order, a, v, &issues)).?;
    try testing.expectEqual(7, o.id);
    try testing.expectEqual(null, o.note);
    try testing.expectEqual(2.0, o.ratio);
    try testing.expectEqual(Tag.green, o.tag);
    try testing.expectEqual(2, o.items.len);
    try testing.expectEqual(1, o.items[0].qty);
    try testing.expectEqual(3, o.items[1].qty);
}

test "reports every issue with its path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    const v = try parseJson(a, "{\"tag\":\"blue\",\"rush\":\"yes\",\"items\":[{\"name\":\"ok\"},{\"name\":5,\"qty\":-1}]}");
    try testing.expectEqual(null, try json(Order, a, v, &issues));
    const want = [_][2][]const u8{
        .{ "id", "required" },
        .{ "rush", "expected boolean" },
        .{ "tag", "expected one of red, green" },
        .{ "items.1.name", "expected string" },
        .{ "items.1.qty", "out of range" },
    };
    try testing.expectEqual(want.len, issues.list.items.len);
    for (want, issues.list.items) |w, got| {
        try testing.expectEqualStrings(w[0], got.field);
        try testing.expectEqualStrings(w[1], got.message);
    }
}

test "unknown fields are ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    const v = try parseJson(a, "{\"name\":\"x\",\"extra\":{\"deep\":[1,2]}}");
    try testing.expectEqualStrings("x", (try json(Item, a, v, &issues)).?.name);
}

test "validate adds custom issues with the struct's path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    const v = try parseJson(a, "{\"id\":1,\"items\":[{\"name\":\"\"}]}");
    try testing.expectEqual(null, try json(Order, a, v, &issues));
    try testing.expectEqualStrings("items.0.name", issues.list.items[0].field);
    try testing.expectEqualStrings("must not be empty", issues.list.items[0].message);
}

test "a non-object body reports expected object" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    try testing.expectEqual(null, try json(Item, a, .{ .integer = 3 }, &issues));
    try testing.expectEqualStrings("", issues.list.items[0].field);
    try testing.expectEqualStrings("expected object", issues.list.items[0].message);
}

const Pairs = struct {
    pairs: []const [2][]const u8,
    pub fn first(self: Pairs, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
    pub fn all(self: Pairs, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) try out.append(arena, p[1]);
        return out.items;
    }
};

test "strings decodes query-like input incl. repeated keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    const Q = struct { page: u32 = 1, tag: ?Tag = null, ids: []const u32 = &.{}, name: []const u8 };
    const q = (try strings(Q, a, Pairs{ .pairs = &.{ .{ "page", "3" }, .{ "ids", "1" }, .{ "ids", "2" }, .{ "name", "x" } } }, &issues)).?;
    try testing.expectEqual(3, q.page);
    try testing.expectEqual(null, q.tag);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, q.ids);

    var issues2: Issues = .init(a);
    try testing.expectEqual(null, try strings(Q, a, Pairs{ .pairs = &.{ .{ "page", "x" }, .{ "ids", "y" } } }, &issues2));
    try testing.expectEqual(3, issues2.list.items.len);
    try testing.expectEqualStrings("ids.0", issues2.list.items[1].field);
}

test "scalar is strict" {
    try testing.expectEqual(null, scalar(u32, "1_000"));
    try testing.expectEqual(null, scalar(f64, "inf"));
    try testing.expectEqual(null, scalar(f64, "nan"));
    try testing.expectEqual(null, scalar(u16, ""));
    try testing.expectEqual(true, scalar(bool, "TRUE").?);
    try testing.expectEqual(false, scalar(bool, "0").?);
    try testing.expectEqual(-4, scalar(i8, "-4").?);
}

test "non-finite JSON numbers are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: Issues = .init(a);
    const v = try parseJson(a, "{\"x\":1e400,\"y\":1e300}");
    try testing.expectEqual(null, try json(struct { x: f64, y: f32 }, a, v, &issues));
    try testing.expectEqual(2, issues.list.items.len);
    try testing.expectEqualStrings("expected number", issues.list.items[0].message);
}
