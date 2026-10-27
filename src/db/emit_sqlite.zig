//! kick/db's SQLite emitter: schema changes as SQLite DDL.
const std = @import("std");
const emit_pg = @import("emit_pg.zig");
const diff = @import("diff.zig");
const snap = @import("snapshot.zig");

const Allocator = std.mem.Allocator;
const Change = diff.Change;
const W = *std.Io.Writer;

/// The schema before and after the changes: a table rebuild is built from
/// them (`generate` always passes both).
pub const Context = struct { from: ?snap.Snapshot = null, to: ?snap.Snapshot = null };

/// kick/db's `emitSqlite`: direct statements where SQLite's ALTER can, and
/// a table rebuild (new table, copy, drop, rename, reindex) for column
/// changes, keys and checks on an existing table. Foreign keys live in
/// CREATE TABLE.
pub fn emit(a: Allocator, changes: []const Change, ctx: Context) ![]const u8 {
    var created: std.StringHashMapUnmanaged(void) = .empty;
    for (changes) |c| if (c == .create_table) try created.put(a, c.create_table.name, {});
    var rebuild: std.ArrayList([]const u8) = .empty;
    for (changes) |c| {
        const t = perTable(c) orelse continue;
        if (created.contains(t)) continue;
        const needs = switch (c) {
            .alter_column, .add_foreign_key, .drop_foreign_key, .alter_primary_key, .add_check, .drop_check => true,
            else => false,
        };
        const name = current(changes, t);
        if (needs and !contains(rebuild.items, name)) try rebuild.append(a, name);
    }
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var first = true;
    for (changes) |c| {
        if (perTable(c)) |t| if (contains(rebuild.items, current(changes, t))) continue;
        const start = out.written().len;
        if (!first) try w.writeByte('\n');
        try emitChange(w, c);
        if (out.written().len == start + @intFromBool(!first)) out.shrinkRetainingCapacity(start) else first = false;
    }
    for (rebuild.items) |t| {
        if (!first) try w.writeByte('\n');
        first = false;
        try emitRebuild(a, w, t, ctx, changes);
    }
    return out.written();
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// A table renamed in this change set is rebuilt under its new name.
fn current(changes: []const Change, t: []const u8) []const u8 {
    for (changes) |c| if (c == .rename_table and std.mem.eql(u8, c.rename_table.from, t)) return c.rename_table.to;
    return t;
}

fn perTable(c: Change) ?[]const u8 {
    return switch (c) {
        inline .add_column, .drop_column, .rename_column, .alter_column, .add_index, .drop_index, .add_foreign_key, .drop_foreign_key, .alter_primary_key, .add_check, .drop_check => |x| x.table,
        else => null,
    };
}

fn emitChange(w: W, c: Change) !void {
    switch (c) {
        .create_table => |t| try createTable(w, t.name, t),
        .drop_table => |t| try w.print("DROP TABLE {f};", .{id(t.name)}),
        .rename_table => |r| try w.print("ALTER TABLE {f} RENAME TO {f};", .{ id(r.from), id(r.to) }),
        .add_column => |x| {
            try w.print("ALTER TABLE {f} ADD COLUMN ", .{id(x.table)});
            try columnDecl(w, x.column, false);
            try w.writeByte(';');
        },
        .drop_column => |x| try w.print("ALTER TABLE {f} DROP COLUMN {f};", .{ id(x.table), id(x.column.name) }),
        .rename_column => |x| try w.print("ALTER TABLE {f} RENAME COLUMN {f} TO {f};", .{ id(x.table), id(x.from), id(x.to) }),
        .add_index => |x| try addIndex(w, x.table, x.index),
        .drop_index => |x| try w.print("DROP INDEX {f};", .{id(x.index.name)}),
        // A new table's keys, FKs and checks are in its CREATE TABLE.
        .add_foreign_key, .drop_foreign_key, .alter_column, .alter_primary_key, .add_check, .drop_check => {},
        .create_enum, .drop_enum, .add_enum_value, .remove_enum_value => return error.UnsupportedOnSqlite,
    }
}

const Ident = struct {
    name: []const u8,
    pub fn format(i: Ident, w: W) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (i.name) |ch| {
            if (ch == '"') try w.writeByte('"');
            try w.writeByte(ch);
        }
        try w.writeByte('"');
    }
};

fn id(name: []const u8) Ident {
    return .{ .name = name };
}

fn findTable(s: ?snap.Snapshot, name: []const u8) ?snap.Table {
    for ((s orelse return null).tables) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn emitRebuild(a: Allocator, w: W, table: []const u8, ctx: Context, changes: []const Change) !void {
    const next = findTable(ctx.to, table) orelse return error.SqliteRebuildRequired;
    // A renamed table is under its old name in `from`; a renamed column reads
    // its old name in the copy.
    var prev = findTable(ctx.from, table);
    for (changes) |c| if (c == .rename_table and std.mem.eql(u8, c.rename_table.to, table)) {
        if (prev == null) prev = findTable(ctx.from, c.rename_table.from);
    };
    var cols: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    for (next.columns) |c| {
        const src = oldName(changes, table, c.name);
        if (prev) |p| if (!hasColumn(p, src)) continue;
        try cols.append(a, c.name);
        try sources.append(a, src);
    }
    const tmp = try std.fmt.allocPrint(a, "_kick_new_{s}", .{table});
    try createTable(w, tmp, next);
    try w.writeByte('\n');
    if (cols.items.len > 0) {
        try w.print("INSERT INTO {f} (", .{id(tmp)});
        try idList(w, cols.items);
        try w.writeAll(")\n  SELECT ");
        try idList(w, sources.items);
        try w.print(" FROM {f};", .{id(table)});
    } else try w.writeAll("-- (no columns survive the rebuild; nothing to copy)");
    try w.print("\nDROP TABLE {f};\nALTER TABLE {f} RENAME TO {f};", .{ id(table), id(tmp), id(table) });
    for (next.indexes) |idx| {
        try w.writeByte('\n');
        try addIndex(w, table, idx);
    }
}

fn oldName(changes: []const Change, table: []const u8, name: []const u8) []const u8 {
    for (changes) |c| if (c == .rename_column and std.mem.eql(u8, c.rename_column.to, name)) {
        const owner = c.rename_column.table;
        if (std.mem.eql(u8, owner, table)) return c.rename_column.from;
        for (changes) |r| if (r == .rename_table and std.mem.eql(u8, r.rename_table.from, owner) and std.mem.eql(u8, r.rename_table.to, table)) return c.rename_column.from;
    };
    return name;
}

fn hasColumn(t: snap.Table, name: []const u8) bool {
    for (t.columns) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

fn idList(w: W, names: []const []const u8) !void {
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{f}", .{id(n)});
    }
}

fn pkColumns(t: snap.Table, buf: *[64][]const u8) []const []const u8 {
    if (t.primary_key) |pk| return pk.columns;
    var n: usize = 0;
    for (t.columns) |c| if (c.primary_key and n < buf.len) {
        buf[n] = c.name;
        n += 1;
    };
    return buf[0..n];
}

fn createTable(w: W, name: []const u8, t: snap.Table) !void {
    var buf: [64][]const u8 = undefined;
    const pk = pkColumns(t, &buf);
    // A single INTEGER key is declared inline: the rowid alias.
    const inline_pk: ?[]const u8 = if (pk.len == 1) for (t.columns) |c| {
        if (std.mem.eql(u8, c.name, pk[0])) break if (std.mem.eql(u8, sqliteType(c.sql_type), "INTEGER")) c.name else null;
    } else null else null;
    try w.print("CREATE TABLE {f} (", .{id(name)});
    for (t.columns, 0..) |c, i| {
        try w.writeAll(if (i == 0) "\n  " else ",\n  ");
        try columnDecl(w, c, inline_pk != null and std.mem.eql(u8, inline_pk.?, c.name));
    }
    if (inline_pk == null and pk.len > 0) {
        try w.writeAll(",\n  PRIMARY KEY (");
        try idList(w, pk);
        try w.writeByte(')');
    }
    for (t.foreign_keys) |fk| {
        try w.writeAll(",\n  FOREIGN KEY (");
        try idList(w, fk.columns);
        try w.print(") REFERENCES {f} (", .{id(fk.ref_table)});
        try idList(w, fk.ref_columns);
        try w.print(") ON DELETE {s} ON UPDATE {s}", .{ action(fk.on_delete), action(fk.on_update) });
    }
    for (t.checks) |ck| try w.print(",\n  CONSTRAINT {f} CHECK ({s})", .{ id(ck.name), ck.expression });
    try w.writeAll("\n);");
}

fn action(x: @import("schema.zig").Action) []const u8 {
    return switch (x) {
        .cascade => "CASCADE",
        .restrict => "RESTRICT",
        .set_null => "SET NULL",
        .set_default => "SET DEFAULT",
        .no_action => "NO ACTION",
    };
}

fn columnDecl(w: W, c: snap.Column, inline_pk: bool) !void {
    try w.print("{f} {s}", .{ id(c.name), sqliteType(c.sql_type) });
    if (inline_pk) {
        try w.writeAll(" PRIMARY KEY");
        if (std.ascii.findIgnoreCase(c.sql_type, "serial") != null) try w.writeAll(" AUTOINCREMENT");
    }
    if (!c.nullable and !inline_pk) try w.writeAll(" NOT NULL");
    if (c.default) |d| {
        try w.writeAll(" DEFAULT ");
        try formatDefault(w, d, c.sql_type, c.default_sql);
    }
}

fn addIndex(w: W, table: []const u8, i: snap.Index) !void {
    try w.print("CREATE{s} INDEX {f} ON {f} (", .{ if (i.unique) " UNIQUE" else "", id(i.name), id(table) });
    for (i.columns, 0..) |k, n| {
        if (n > 0) try w.writeAll(", ");
        // An expression key is stored in its parentheses, as SQL takes it.
        if (std.mem.startsWith(u8, k, "(")) try w.writeAll(k) else try w.print("{f}", .{id(k)});
    }
    try w.writeByte(')');
    if (i.where) |wh| try w.print(" WHERE {s}", .{wh});
    try w.writeByte(';');
}

/// kick/db's `sqliteType`: a Postgres type's SQLite affinity.
pub fn sqliteType(pg_type: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    var base = std.mem.trim(u8, pg_type, " ");
    if (std.mem.findScalar(u8, base, '(')) |p| base = base[0..p];
    if (std.mem.endsWith(u8, base, "[]")) base = base[0 .. base.len - 2];
    if (base.len > buf.len) return "TEXT";
    const b = std.ascii.lowerString(&buf, std.mem.trim(u8, base, " "));
    const ints = [_][]const u8{ "int", "integer", "int2", "int4", "int8", "smallint", "bigint", "serial", "bigserial", "smallserial", "boolean", "bool" };
    for (ints) |x| if (std.mem.eql(u8, b, x)) return "INTEGER";
    for ([_][]const u8{ "real", "float4", "float8", "double precision", "float" }) |x| if (std.mem.eql(u8, b, x)) return "REAL";
    for ([_][]const u8{ "numeric", "decimal", "money" }) |x| if (std.mem.eql(u8, b, x)) return "NUMERIC";
    if (std.mem.eql(u8, b, "bytea") or std.mem.eql(u8, b, "blob")) return "BLOB";
    return "TEXT";
}

/// A random version-4 UUID in canonical 8-4-4-4-12 form: SQLite has no uuid function.
const uuid_v4 = "(lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || " ++
    "substr('89ab', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))))";

/// The current time with milliseconds (CURRENT_TIMESTAMP has whole
/// seconds), as kick/db writes a `Date`.
const now = "(strftime('%Y-%m-%d %H:%M:%f', 'now'))";

/// kick/db's `sqliteDefault`: a Postgres-flavoured default as SQLite SQL.
pub fn formatDefault(w: W, value: []const u8, sql_type: []const u8, is_sql: bool) !void {
    const v = std.mem.trim(u8, value, " \t\r\n");
    // `.defaultSql()` is the caller's SQLite SQL, as written.
    if (is_sql) {
        const bare = emit_pg.isNumber(v) or (v.len > 0 and for (v) |ch| {
            if (!(std.ascii.isAlphabetic(ch) or ch == '_')) break false;
        } else true);
        return if (bare) w.writeAll(v) else w.print("({s})", .{v});
    }
    // A value on a text-like column, even `NULL` or `CURRENT_TIMESTAMP`.
    if (!emit_pg.allowsExpressionDefault(sql_type)) return emit_pg.literal(w, v);
    if (std.ascii.eqlIgnoreCase(v, "true")) return w.writeAll("1");
    if (std.ascii.eqlIgnoreCase(v, "false")) return w.writeAll("0");
    if (std.ascii.eqlIgnoreCase(v, "gen_random_uuid()") or std.ascii.eqlIgnoreCase(v, "uuid_generate_v4()")) return w.writeAll(uuid_v4);
    if (std.ascii.eqlIgnoreCase(v, "now()") or std.ascii.eqlIgnoreCase(v, "CURRENT_TIMESTAMP")) return w.writeAll(now);
    for ([_][]const u8{ "CURRENT_DATE", "CURRENT_TIME", "NULL" }) |kw| if (std.ascii.eqlIgnoreCase(v, kw)) return w.writeAll(kw);
    if (emit_pg.isNumber(v)) return w.writeAll(v);
    // A function call is an expression, which SQLite takes only in parentheses.
    if (emit_pg.isFunctionCall(v)) return w.print("({s})", .{v});
    return emit_pg.literal(w, v);
}

const testing = std.testing;
const Column = snap.Column;

fn col(name: []const u8, sql_type: []const u8, nullable: bool, default: ?[]const u8, pk: bool) Column {
    return .{ .key = name, .name = name, .sql_type = sql_type, .nullable = nullable, .default = default, .default_sql = false, .primary_key = pk };
}

fn tbl(name: []const u8, columns: []const Column, indexes: []const snap.Index) snap.Table {
    return .{ .name = name, .columns = columns, .indexes = indexes, .foreign_keys = &.{}, .checks = &.{}, .primary_key = null };
}

fn expectEmit(want: []const u8, changes: []const Change, ctx: Context) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try emit(arena.allocator(), changes, ctx));
}

test "emitSqlite — CREATE TABLE: maps PG types to SQLite affinities + normalises defaults" {
    try expectEmit(
        "CREATE TABLE \"tasks\" (\n" ++
            "  \"id\" TEXT NOT NULL DEFAULT (lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || substr('89ab', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6)))),\n" ++
            "  \"title\" TEXT NOT NULL,\n" ++
            "  \"done\" INTEGER NOT NULL DEFAULT 0,\n" ++
            "  \"createdAt\" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now')),\n" ++
            "  PRIMARY KEY (\"id\")\n" ++
            ");",
        &.{.{ .create_table = tbl("tasks", &.{
            col("id", "uuid", false, "gen_random_uuid()", true),
            col("title", "varchar(200)", false, null, false),
            col("done", "boolean", false, "false", false),
            col("createdAt", "timestamp", false, "CURRENT_TIMESTAMP", false),
        }, &.{}) }},
        .{},
    );
}

test "emitSqlite — CREATE TABLE: inlines a single integer PK as INTEGER PRIMARY KEY (rowid alias)" {
    try expectEmit("CREATE TABLE \"nums\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT\n);", &.{.{ .create_table = tbl("nums", &.{col("id", "serial", false, null, true)}, &.{}) }}, .{});
}

test "emitSqlite — CREATE TABLE: inlines foreign keys into CREATE TABLE and skips their addForeignKey change" {
    const fk: snap.ForeignKey = .{ .name = "posts_author_fk", .columns = &.{"authorId"}, .ref_table = "users", .ref_columns = &.{"id"}, .on_delete = .cascade, .on_update = .no_action };
    var t = tbl("posts", &.{ col("id", "integer", false, null, true), col("authorId", "integer", false, null, false) }, &.{});
    t.foreign_keys = &.{fk};
    try expectEmit(
        "CREATE TABLE \"posts\" (\n  \"id\" INTEGER PRIMARY KEY,\n  \"authorId\" INTEGER NOT NULL,\n  FOREIGN KEY (\"authorId\") REFERENCES \"users\" (\"id\") ON DELETE CASCADE ON UPDATE NO ACTION\n);",
        &.{ .{ .create_table = t }, .{ .add_foreign_key = .{ .table = "posts", .fk = fk } } },
        .{},
    );
}

test "emitSqlite — ALTER: add / drop / rename column + indexes" {
    try expectEmit("ALTER TABLE \"tasks\" ADD COLUMN \"priority\" INTEGER NOT NULL DEFAULT 0;", &.{.{ .add_column = .{ .table = "tasks", .column = col("priority", "integer", false, "0", false) } }}, .{});
    try expectEmit("ALTER TABLE \"tasks\" DROP COLUMN \"priority\";", &.{.{ .drop_column = .{ .table = "tasks", .column = col("priority", "text", true, null, false) } }}, .{});
    try expectEmit("ALTER TABLE \"tasks\" RENAME COLUMN \"a\" TO \"b\";", &.{.{ .rename_column = .{ .table = "tasks", .from = "a", .to = "b" } }}, .{});
    const idx: snap.Index = .{ .name = "tasks_done_idx", .columns = &.{"done"}, .unique = false };
    try expectEmit("CREATE INDEX \"tasks_done_idx\" ON \"tasks\" (\"done\");", &.{.{ .add_index = .{ .table = "tasks", .index = idx } }}, .{});
    try expectEmit("DROP INDEX \"tasks_done_idx\";", &.{.{ .drop_index = .{ .table = "tasks", .index = idx } }}, .{});
}

test "emitSqlite — ALTER: a column alteration or an FK on an existing table needs the snapshots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SqliteRebuildRequired, emit(arena.allocator(), &.{.{ .alter_column = .{ .table = "tasks", .column = "title", .before = col("title", "varchar(50)", true, null, false), .after = col("title", "text", true, null, false) } }}, .{}));
    const fk: snap.ForeignKey = .{ .name = "fk", .columns = &.{"x"}, .ref_table = "u", .ref_columns = &.{"id"}, .on_delete = .no_action, .on_update = .no_action };
    try testing.expectError(error.SqliteRebuildRequired, emit(arena.allocator(), &.{.{ .add_foreign_key = .{ .table = "posts", .fk = fk } }}, .{}));
}

test "emitSqlite — table rebuild: create _kick_new / copy common cols / drop / rename / reindex" {
    const idx = [_]snap.Index{.{ .name = "tasks_title_idx", .columns = &.{"title"}, .unique = false }};
    const from: snap.Snapshot = .{ .dialect = .sqlite, .tables = &.{tbl("tasks", &.{ col("id", "integer", false, null, true), col("title", "varchar(50)", true, null, false) }, &idx)} };
    const to: snap.Snapshot = .{ .dialect = .sqlite, .tables = &.{tbl("tasks", &.{ col("id", "integer", false, null, true), col("title", "text", false, null, false) }, &idx)} };
    try expectEmit(
        "CREATE TABLE \"_kick_new_tasks\" (\n" ++
            "  \"id\" INTEGER PRIMARY KEY,\n" ++
            "  \"title\" TEXT NOT NULL\n" ++
            ");\n" ++
            "INSERT INTO \"_kick_new_tasks\" (\"id\", \"title\")\n" ++
            "  SELECT \"id\", \"title\" FROM \"tasks\";\n" ++
            "DROP TABLE \"tasks\";\n" ++
            "ALTER TABLE \"_kick_new_tasks\" RENAME TO \"tasks\";\n" ++
            "CREATE INDEX \"tasks_title_idx\" ON \"tasks\" (\"title\");",
        &.{.{ .alter_column = .{ .table = "tasks", .column = "title", .before = from.tables[0].columns[1], .after = to.tables[0].columns[1] } }},
        .{ .from = from, .to = to },
    );
}

test "emitSqlite — table rebuild: copies only the column intersection (a dropped column is not selected)" {
    const from: snap.Snapshot = .{ .dialect = .sqlite, .tables = &.{tbl("t", &.{ col("id", "integer", false, null, true), col("gone", "text", true, null, false), col("keep", "text", true, null, false) }, &.{})} };
    const to: snap.Snapshot = .{ .dialect = .sqlite, .tables = &.{tbl("t", &.{ col("id", "integer", false, null, true), col("keep", "integer", true, null, false) }, &.{})} };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sql = try emit(arena.allocator(), &.{.{ .alter_column = .{ .table = "t", .column = "keep", .before = from.tables[0].columns[2], .after = to.tables[0].columns[1] } }}, .{ .from = from, .to = to });
    try testing.expect(std.mem.find(u8, sql, "INSERT INTO \"_kick_new_t\" (\"id\", \"keep\")\n  SELECT \"id\", \"keep\" FROM \"t\";") != null);
    try testing.expect(std.mem.find(u8, sql, "gone") == null);
}
