//! kick/db's `SchemaSnapshot`: what `snapshot.json` in a migration folder
//! holds, made from a `db.Schema`, parsed, and written as kick/db writes it
//! (`JSON.stringify(s, null, 2)`), so the two can share a migrations folder.
const std = @import("std");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;

pub const Table = schema.TableInfo;
pub const Column = schema.ColumnInfo;
pub const Index = schema.IndexInfo;
pub const ForeignKey = schema.ForeignKeyInfo;
pub const Check = schema.CheckInfo;
pub const Enum = schema.EnumInfo;

/// Tables in the database's default schema.
pub const Snapshot = struct {
    dialect: @import("db.zig").Dialect = .postgres,
    tables: []const Table = &.{},
    /// Absent (not empty) when no table uses one, as kick/db writes it.
    enums: ?[]const Enum = null,
    /// kick/db's relation sidecar, as parsed (carried through as is).
    relations: ?std.json.Value = null,
    /// The schema's relations, written as the sidecar.
    declared: ?Declared = null,

    pub const Declared = struct {
        /// Declared table names, sorted (kick/db walks its exports alphabetically).
        tables: []const []const u8,
        relations: []const []const schema.RelationInfo,
    };
};

/// The schema as kick/db's extract would record it.
pub fn fromSchema(comptime S: type) Snapshot {
    // kick/db keeps `enums` on Postgres snapshots only.
    return .{ .dialect = S.dialect, .tables = S.tables_info, .enums = if (S.enums.len > 0 and S.dialect == .postgres) S.enums else null, .declared = comptime declaredOf(S) };
}

fn declaredOf(comptime S: type) ?Snapshot.Declared {
    if (S.relation_tables.len == 0) return null;
    var names: [S.relation_tables.len][]const u8 = undefined;
    var lists: [S.relation_tables.len][]const schema.RelationInfo = undefined;
    for (S.relation_tables, 0..) |tag, i| {
        names[i] = S.Table(@field(S.Tag, tag)).name_;
        lists[i] = S.relationsOf(@field(S.Tag, tag));
    }
    // Sorted by name, lists along.
    for (1..names.len) |i| {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, names[j], names[j - 1])) : (j -= 1) {
            std.mem.swap([]const u8, &names[j], &names[j - 1]);
            std.mem.swap([]const schema.RelationInfo, &lists[j], &lists[j - 1]);
        }
    }
    const n = names;
    const l = lists;
    return .{ .tables = &n, .relations = &l };
}

/// The file's text, without the trailing newline kick/db adds.
pub fn toJson(a: Allocator, s: Snapshot) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, try toValue(a, s), .{ .whitespace = .indent_2 });
}

/// In kick/db's key order (its object literals' order).
pub fn toValue(a: Allocator, s: Snapshot) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "version", .{ .integer = 1 });
    try root.put(a, "dialect", .{ .string = @tagName(s.dialect) });
    var tables: std.json.ObjectMap = .empty;
    for (s.tables) |t| try tables.put(a, t.name, try tableValue(a, t));
    try root.put(a, "tables", .{ .object = tables });
    if (s.enums) |enums| {
        var obj: std.json.ObjectMap = .empty;
        for (enums) |e| {
            var eo: std.json.ObjectMap = .empty;
            try eo.put(a, "name", .{ .string = e.name });
            try eo.put(a, "values", try strings(a, e.values));
            try obj.put(a, e.name, .{ .object = eo });
        }
        try root.put(a, "enums", .{ .object = obj });
    }
    if (s.relations) |r| try root.put(a, "relations", r) else if (s.declared) |d| {
        var obj: std.json.ObjectMap = .empty;
        for (d.tables, d.relations) |name, list| {
            var t: std.json.ObjectMap = .empty;
            for (list) |r| {
                var o: std.json.ObjectMap = .empty;
                try o.put(a, "kind", .{ .string = @tagName(r.kind) });
                try o.put(a, "target", .{ .string = r.target });
                try o.put(a, "sourceColumns", try strings(a, r.source_columns));
                try o.put(a, "targetColumns", try strings(a, r.target_columns));
                if (r.through) |th| {
                    var to: std.json.ObjectMap = .empty;
                    try to.put(a, "table", .{ .string = th.table });
                    try to.put(a, "sourceColumns", try strings(a, th.source_columns));
                    try to.put(a, "targetColumns", try strings(a, th.target_columns));
                    try o.put(a, "through", .{ .object = to });
                } else if (r.relation_name) |n| try o.put(a, "relationName", .{ .string = n });
                try t.put(a, r.name, .{ .object = o });
            }
            try obj.put(a, name, .{ .object = t });
        }
        try root.put(a, "relations", .{ .object = obj });
    }
    return .{ .object = root };
}

fn strings(a: Allocator, list: []const []const u8) !std.json.Value {
    var arr: std.json.Array = .init(a);
    for (list) |x| try arr.append(.{ .string = x });
    return .{ .array = arr };
}

fn tableValue(a: Allocator, t: Table) !std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "name", .{ .string = t.name });
    var cols: std.json.ObjectMap = .empty;
    for (t.columns) |c| {
        var co: std.json.ObjectMap = .empty;
        try co.put(a, "name", .{ .string = c.name });
        try co.put(a, "type", .{ .string = c.sql_type });
        try co.put(a, "nullable", .{ .bool = c.nullable });
        try co.put(a, "default", if (c.default) |d| .{ .string = d } else .null);
        if (c.default_sql) try co.put(a, "defaultSql", .{ .bool = true });
        try co.put(a, "primaryKey", .{ .bool = c.primary_key });
        try cols.put(a, c.name, .{ .object = co });
    }
    try o.put(a, "columns", .{ .object = cols });
    var idx: std.json.Array = .init(a);
    for (t.indexes) |i| {
        var io: std.json.ObjectMap = .empty;
        try io.put(a, "name", .{ .string = i.name });
        try io.put(a, "columns", try strings(a, i.columns));
        try io.put(a, "unique", .{ .bool = i.unique });
        if (i.where) |w| try io.put(a, "where", .{ .string = w });
        if (i.using) |u| try io.put(a, "using", .{ .string = u });
        try idx.append(.{ .object = io });
    }
    try o.put(a, "indexes", .{ .array = idx });
    var fks: std.json.Array = .init(a);
    for (t.foreign_keys) |f| {
        var fo: std.json.ObjectMap = .empty;
        try fo.put(a, "name", .{ .string = f.name });
        try fo.put(a, "columns", try strings(a, f.columns));
        try fo.put(a, "refTable", .{ .string = f.ref_table });
        try fo.put(a, "refColumns", try strings(a, f.ref_columns));
        try fo.put(a, "onDelete", .{ .string = @tagName(f.on_delete) });
        try fo.put(a, "onUpdate", .{ .string = @tagName(f.on_update) });
        try fks.append(.{ .object = fo });
    }
    try o.put(a, "foreignKeys", .{ .array = fks });
    var checks: std.json.Array = .init(a);
    for (t.checks) |c| {
        var co: std.json.ObjectMap = .empty;
        try co.put(a, "name", .{ .string = c.name });
        try co.put(a, "expression", .{ .string = c.expression });
        try checks.append(.{ .object = co });
    }
    try o.put(a, "checks", .{ .array = checks });
    if (t.primary_key) |pk| {
        var po: std.json.ObjectMap = .empty;
        if (pk.name) |n| try po.put(a, "name", .{ .string = n });
        try po.put(a, "columns", try strings(a, pk.columns));
        try o.put(a, "primaryKey", .{ .object = po });
    }
    return .{ .object = o };
}

/// A `snapshot.json`. Parts of kick/db's snapshot kzig doesn't model yet
/// (views, roles, RLS, comments, identity columns, …) are refused rather
/// than dropped: a diff that can't see them would undo them.
pub fn parse(a: Allocator, text: []const u8) !Snapshot {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch return error.InvalidSnapshot;
    const root = try object(v);
    try only(root, &.{ "version", "dialect", "tables", "enums", "relations" });
    var out: Snapshot = .{ .dialect = std.meta.stringToEnum(@import("db.zig").Dialect, try str(root.get("dialect"))) orelse return unsupported("dialect") };
    const tables = try object(root.get("tables") orelse return error.InvalidSnapshot);
    const list = try a.alloc(Table, tables.count());
    for (tables.values(), list) |tv, *t| t.* = try parseTable(a, try object(tv));
    out.tables = list;
    if (root.get("enums")) |ev| {
        const eo = try object(ev);
        const enums = try a.alloc(Enum, eo.count());
        for (eo.values(), enums) |e, *dst| {
            const o = try object(e);
            dst.* = .{ .name = try str(o.get("name")), .values = try strList(a, o.get("values")) };
        }
        out.enums = enums;
    }
    out.relations = root.get("relations");
    return out;
}

fn parseTable(a: Allocator, o: std.json.ObjectMap) !Table {
    try only(o, &.{ "name", "columns", "indexes", "foreignKeys", "checks", "primaryKey" });
    const co = try object(o.get("columns") orelse return error.InvalidSnapshot);
    const cols = try a.alloc(Column, co.count());
    for (co.values(), cols) |cv, *c| {
        const x = try object(cv);
        try only(x, &.{ "name", "type", "nullable", "default", "defaultSql", "primaryKey" });
        const name = try str(x.get("name"));
        c.* = .{
            .key = name,
            .name = name,
            .sql_type = try str(x.get("type")),
            .nullable = try boolean(x.get("nullable")),
            .default = switch (x.get("default") orelse .null) {
                .null => null,
                .string => |d| d,
                else => return error.InvalidSnapshot,
            },
            .default_sql = if (x.get("defaultSql")) |d| try boolean(d) else false,
            .primary_key = try boolean(x.get("primaryKey")),
        };
    }
    const ia = try array(o.get("indexes"));
    const indexes = try a.alloc(Index, ia.len);
    for (ia, indexes) |iv, *i| {
        const x = try object(iv);
        try only(x, &.{ "name", "columns", "unique", "where", "using" });
        i.* = .{
            .name = try str(x.get("name")),
            .columns = try strList(a, x.get("columns")),
            .unique = try boolean(x.get("unique")),
            .where = if (x.get("where")) |w| try str(w) else null,
            .using = if (x.get("using")) |u| try str(u) else null,
        };
    }
    const fa = try array(o.get("foreignKeys"));
    const fks = try a.alloc(ForeignKey, fa.len);
    for (fa, fks) |fv, *f| {
        const x = try object(fv);
        try only(x, &.{ "name", "columns", "refTable", "refColumns", "onDelete", "onUpdate" });
        f.* = .{
            .name = try str(x.get("name")),
            .columns = try strList(a, x.get("columns")),
            .ref_table = try str(x.get("refTable")),
            .ref_columns = try strList(a, x.get("refColumns")),
            .on_delete = std.meta.stringToEnum(schema.Action, try str(x.get("onDelete"))) orelse return error.InvalidSnapshot,
            .on_update = std.meta.stringToEnum(schema.Action, try str(x.get("onUpdate"))) orelse return error.InvalidSnapshot,
        };
    }
    const ca = try array(o.get("checks"));
    const checks = try a.alloc(Check, ca.len);
    for (ca, checks) |cv, *c| {
        const x = try object(cv);
        c.* = .{ .name = try str(x.get("name")), .expression = try str(x.get("expression")) };
    }
    var pk: ?schema.PrimaryKeyInfo = null;
    if (o.get("primaryKey")) |pv| {
        const x = try object(pv);
        pk = .{ .name = if (x.get("name")) |n| try str(n) else null, .columns = try strList(a, x.get("columns")) };
    }
    return .{ .name = try str(o.get("name")), .columns = cols, .indexes = indexes, .foreign_keys = fks, .checks = checks, .primary_key = pk };
}

fn only(o: std.json.ObjectMap, allowed: []const []const u8) !void {
    for (o.keys()) |k| {
        for (allowed) |x| {
            if (std.mem.eql(u8, x, k)) break;
        } else return unsupported(k);
    }
}

fn unsupported(key: []const u8) error{UnsupportedSnapshot} {
    if (!@import("builtin").is_test) std.log.err("snapshot: \"{s}\" isn't supported by kzig yet", .{key});
    return error.UnsupportedSnapshot;
}

fn object(v: std.json.Value) !std.json.ObjectMap {
    return if (v == .object) v.object else error.InvalidSnapshot;
}

fn array(v: ?std.json.Value) ![]const std.json.Value {
    const x = v orelse return error.InvalidSnapshot;
    return if (x == .array) x.array.items else error.InvalidSnapshot;
}

fn str(v: ?std.json.Value) ![]const u8 {
    const x = v orelse return error.InvalidSnapshot;
    return if (x == .string) x.string else error.InvalidSnapshot;
}

fn boolean(v: ?std.json.Value) !bool {
    const x = v orelse return error.InvalidSnapshot;
    return if (x == .bool) x.bool else error.InvalidSnapshot;
}

fn strList(a: Allocator, v: ?std.json.Value) ![]const []const u8 {
    const items = try array(v);
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |x, *o| o.* = try str(x);
    return out;
}

const testing = std.testing;
const archive = "examples/task-api/db/migrations/20261015_231323_init/snapshot.json";

fn readArchive(a: Allocator) ![]const u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, archive, a, .limited(1 << 20));
    return text[0 .. text.len - 1]; // the file ends in a newline
}

test "a kick/db snapshot parses and writes back byte for byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try readArchive(a);
    const s = try parse(a, text);
    try testing.expectEqual(16, s.tables.len);
    try testing.expectEqualStrings("users", s.tables[0].name);
    try testing.expectEqualStrings(text, try toJson(a, s));
}

test "kick/db's features kzig doesn't have yet are refused, by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnsupportedSnapshot, parse(a, "{\"version\":1,\"dialect\":\"postgres\",\"tables\":{},\"views\":{}}"));
    try testing.expectError(error.UnsupportedSnapshot, parse(a, "{\"version\":1,\"dialect\":\"mysql\",\"tables\":{}}"));
    try testing.expectEqual(@import("db.zig").Dialect.sqlite, (try parse(a, "{\"version\":1,\"dialect\":\"sqlite\",\"tables\":{}}")).dialect);
    try testing.expectError(error.UnsupportedSnapshot, parse(a,
        \\{"version":1,"dialect":"postgres","tables":{"t":{"name":"t","columns":{"a":{"name":"a","type":"integer","nullable":true,"default":null,"primaryKey":false,"identity":"always"}},"indexes":[],"foreignKeys":[],"checks":[]}}}
    ));
}

test "strings are escaped as JSON.stringify escapes them; empty parts are written empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Snapshot = .{ .tables = &.{.{
        .name = "t",
        .columns = &.{.{ .key = "a", .name = "a", .sql_type = "text", .nullable = true, .default = "a\"b\\c\n\x01é", .default_sql = false, .primary_key = false }},
        .indexes = &.{},
        .foreign_keys = &.{},
        .checks = &.{},
        .primary_key = null,
    }} };
    try testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "dialect": "postgres",
        \\  "tables": {
        \\    "t": {
        \\      "name": "t",
        \\      "columns": {
        \\        "a": {
        \\          "name": "a",
        \\          "type": "text",
        \\          "nullable": true,
        \\          "default": "a\"b\\c\n\u0001é",
        \\          "primaryKey": false
        \\        }
        \\      },
        \\      "indexes": [],
        \\      "foreignKeys": [],
        \\      "checks": []
        \\    }
        \\  }
        \\}
    , try toJson(a, s));
    try testing.expectEqualStrings("{\n  \"version\": 1,\n  \"dialect\": \"postgres\",\n  \"tables\": {}\n}", try toJson(a, .{}));
}

test "declared relations are written as kick/db's sidecar: tables by name, relations as declared" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = schema.table("users", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
    const posts = schema.table("posts", .{
        .id = .{ .type = .serial, .primary_key = true },
        .authorId = .{ .type = .integer, .references = .{ .to = "users.id" } },
    }, .{});
    const S = schema.Schema(.{ .users = users, .posts = posts }, .{ .relations = .{
        .users = .{ .posts = .{ .many = .posts } },
        .posts = .{ .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id}, .relation_name = "a" } },
    } });
    const json = try toJson(a, fromSchema(S));
    const at = std.mem.find(u8, json, "\"relations\"").?;
    try testing.expectEqualStrings(
        \\"relations": {
        \\    "posts": {
        \\      "author": {
        \\        "kind": "one",
        \\        "target": "users",
        \\        "sourceColumns": [
        \\          "authorId"
        \\        ],
        \\        "targetColumns": [
        \\          "id"
        \\        ],
        \\        "relationName": "a"
        \\      }
        \\    },
        \\    "users": {
        \\      "posts": {
        \\        "kind": "many",
        \\        "target": "posts",
        \\        "sourceColumns": [
        \\          "id"
        \\        ],
        \\        "targetColumns": [
        \\          "authorId"
        \\        ]
        \\      }
        \\    }
        \\  }
        \\}
    , json[at..]);
}
