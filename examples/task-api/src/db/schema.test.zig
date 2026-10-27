//! The Zig schema says what task-kickdb-api's does: every table, column,
//! type, default, index and foreign key in the archive's snapshot.json.
const std = @import("std");
const kzig = @import("kzig");
const Schema = @import("schema.zig").Schema;

const testing = std.testing;
const snapshot_path = "examples/task-api/db/migrations/20261015_231323_init/snapshot.json";

test "schema: matches task-kickdb-api's init snapshot" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, snapshot_path, a, .limited(1 << 20));
    const snap = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const tables = snap.object.get("tables").?.object;
    try testing.expectEqual(16, Schema.tables_info.len);
    try testing.expectEqual(tables.count(), Schema.tables_info.len);
    for (Schema.tables_info) |t| {
        const st = (tables.get(t.name) orelse return error.TestUnexpectedResult).object;
        const cols = st.get("columns").?.object;
        try testing.expectEqual(cols.count(), t.columns.len);
        for (t.columns, cols.keys()) |c, key| {
            errdefer std.debug.print("{s}.{s}\n", .{ t.name, c.name });
            try testing.expectEqualStrings(key, c.name);
            const sc = cols.get(key).?.object;
            try testing.expectEqualStrings(sc.get("type").?.string, c.sql_type);
            try testing.expectEqual(sc.get("nullable").?.bool, c.nullable);
            try testing.expectEqual(sc.get("primaryKey").?.bool, c.primary_key);
            switch (sc.get("default").?) {
                .null => try testing.expectEqual(null, c.default),
                .string => |d| try testing.expectEqualStrings(d, c.default.?),
                else => return error.TestUnexpectedResult,
            }
        }
        const idx = st.get("indexes").?.array.items;
        try testing.expectEqual(idx.len, t.indexes.len);
        for (t.indexes, idx) |i, si| {
            try testing.expectEqualStrings(si.object.get("name").?.string, i.name);
            try testing.expectEqual(si.object.get("unique").?.bool, i.unique);
            const on = si.object.get("columns").?.array.items;
            try testing.expectEqual(on.len, i.columns.len);
            for (i.columns, on) |c, sc| try testing.expectEqualStrings(sc.string, c);
        }
        const fks = st.get("foreignKeys").?.array.items;
        try testing.expectEqual(fks.len, t.foreign_keys.len);
        for (t.foreign_keys, fks) |f, sf| {
            try testing.expectEqualStrings(sf.object.get("name").?.string, f.name);
            try testing.expectEqualStrings(sf.object.get("refTable").?.string, f.ref_table);
            try testing.expectEqualStrings(sf.object.get("onDelete").?.string, @tagName(f.on_delete));
            try testing.expectEqualStrings(sf.object.get("onUpdate").?.string, @tagName(f.on_update));
        }
    }
    const enums = snap.object.get("enums").?.object;
    try testing.expectEqual(enums.count(), Schema.enums.len);
    for (Schema.enums, enums.keys()) |e, key| {
        try testing.expectEqualStrings(key, e.name);
        const values = enums.get(key).?.object.get("values").?.array.items;
        for (e.values, values) |v, sv| try testing.expectEqualStrings(sv.string, v);
    }
}

test "schema: its snapshot is task-kickdb-api's, byte for byte, relations included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, snapshot_path, a, .limited(1 << 20));
    try testing.expectEqualStrings(text[0 .. text.len - 1], try kzig.db.snapshot.toJson(a, kzig.db.snapshot.fromSchema(Schema)));
}

test "schema: generating from nothing writes task-kickdb-api's up.sql and down.sql" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = kzig.db;
    const dir = "examples/task-api/db/migrations/20261015_231323_init/";
    const changes = try db.diff.diff(a, .{}, db.snapshot.fromSchema(Schema), .{});
    inline for (.{ "up.sql", "down.sql" }, 0..) |file, i| {
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, dir ++ file, a, .limited(1 << 20));
        // Past kick/db's banner line, without the trailing newline.
        const body = text[std.mem.findScalar(u8, text, '\n').? + 1 .. text.len - 1];
        const sql = try db.emit_pg.emit(a, if (i == 0) changes else try db.diff.invert(a, changes));
        try testing.expectEqualStrings(body, sql);
    }
}
