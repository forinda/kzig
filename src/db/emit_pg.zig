//! kick/db's Postgres emitter: schema changes as DDL, statement for
//! statement, so generated migrations read as kick/db's do.
const std = @import("std");
const diff = @import("diff.zig");
const snap = @import("snapshot.zig");

const Allocator = std.mem.Allocator;
const Change = diff.Change;
const Column = snap.Column;

/// Every change as SQL, one statement (or kick/db's block) per change,
/// joined by newlines.
pub fn emit(a: Allocator, changes: []const Change) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (changes, 0..) |c, i| {
        if (i > 0) try w.writeByte('\n');
        try emitChange(w, c);
    }
    return out.written();
}

const W = *std.Io.Writer;

fn ident(w: W, name: []const u8) !void {
    try w.writeByte('"');
    for (name) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

fn literal(w: W, v: []const u8) !void {
    try w.writeByte('\'');
    for (v) |ch| {
        if (ch == '\'') try w.writeByte('\'');
        try w.writeByte(ch);
    }
    try w.writeByte('\'');
}

fn idents(w: W, names: []const []const u8) !void {
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try ident(w, n);
    }
}

fn action(a: @import("schema.zig").Action) []const u8 {
    return switch (a) {
        .cascade => "CASCADE",
        .restrict => "RESTRICT",
        .set_null => "SET NULL",
        .set_default => "SET DEFAULT",
        .no_action => "NO ACTION",
    };
}

fn alterTable(w: W, table: []const u8) !void {
    try w.writeAll("ALTER TABLE ");
    try ident(w, table);
}

fn emitChange(w: W, change: Change) !void {
    switch (change) {
        .create_table => |t| try createTable(w, t),
        .drop_table => |t| {
            try w.writeAll("DROP TABLE ");
            try ident(w, t.name);
            try w.writeByte(';');
        },
        .rename_table => |r| {
            try alterTable(w, r.from);
            try w.writeAll(" RENAME TO ");
            try ident(w, r.to);
            try w.writeByte(';');
        },
        .add_column => |c| {
            try alterTable(w, c.table);
            try w.writeAll(" ADD COLUMN ");
            try columnDecl(w, c.column);
            try w.writeByte(';');
        },
        .drop_column => |c| {
            try alterTable(w, c.table);
            try w.writeAll(" DROP COLUMN ");
            try ident(w, c.column.name);
            try w.writeByte(';');
        },
        .rename_column => |r| {
            try alterTable(w, r.table);
            try w.writeAll(" RENAME COLUMN ");
            try ident(w, r.from);
            try w.writeAll(" TO ");
            try ident(w, r.to);
            try w.writeByte(';');
        },
        .alter_column => |c| try alterColumn(w, c.table, c.before, c.after),
        .add_index => |x| {
            const i = x.index;
            try w.writeAll(if (i.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
            try ident(w, i.name);
            try w.writeAll(" ON ");
            try ident(w, x.table);
            if (i.using) |u| try w.print(" USING {s}", .{u});
            try w.writeAll(" (");
            for (i.columns, 0..) |k, n| {
                if (n > 0) try w.writeAll(", ");
                // An expression key is stored in its parentheses.
                if (std.mem.startsWith(u8, k, "(")) try w.writeAll(k) else try ident(w, k);
            }
            try w.writeByte(')');
            if (i.where) |p| try w.print(" WHERE {s}", .{p});
            try w.writeByte(';');
        },
        .drop_index => |x| {
            try w.writeAll("DROP INDEX ");
            try ident(w, x.index.name);
            try w.writeByte(';');
        },
        .add_foreign_key => |x| {
            try alterTable(w, x.table);
            try w.writeAll(" ADD CONSTRAINT ");
            try ident(w, x.fk.name);
            try w.writeAll(" FOREIGN KEY (");
            try idents(w, x.fk.columns);
            try w.writeAll(") REFERENCES ");
            try ident(w, x.fk.ref_table);
            try w.writeAll(" (");
            try idents(w, x.fk.ref_columns);
            try w.print(") ON DELETE {s} ON UPDATE {s};", .{ action(x.fk.on_delete), action(x.fk.on_update) });
        },
        .drop_foreign_key => |x| {
            try alterTable(w, x.table);
            try w.writeAll(" DROP CONSTRAINT ");
            try ident(w, x.fk.name);
            try w.writeByte(';');
        },
        .create_enum => |e| try createEnum(w, e.name, e.values),
        .drop_enum => |e| {
            try w.writeAll("DROP TYPE ");
            try ident(w, e.name);
            try w.writeByte(';');
        },
        .add_enum_value => |x| {
            try w.writeAll("ALTER TYPE ");
            try ident(w, x.@"enum");
            try w.writeAll(" ADD VALUE ");
            try literal(w, x.value);
            if (x.before) |b| {
                try w.writeAll(" BEFORE ");
                try literal(w, b);
            }
            try w.writeByte(';');
        },
        .remove_enum_value => |x| try removeEnumValue(w, x),
        .alter_primary_key => |k| {
            if (k.before.columns.len > 0) {
                try alterTable(w, k.table);
                try w.writeAll(" DROP CONSTRAINT ");
                try keyName(w, k.table, k.before);
                try w.writeByte(';');
            }
            if (k.after.columns.len > 0) {
                if (k.before.columns.len > 0) try w.writeByte('\n');
                try alterTable(w, k.table);
                try w.writeAll(" ADD CONSTRAINT ");
                try keyName(w, k.table, k.after);
                try w.writeAll(" PRIMARY KEY (");
                try idents(w, k.after.columns);
                try w.writeAll(");");
            }
        },
        .add_check => |x| {
            try alterTable(w, x.table);
            try w.writeAll(" ADD CONSTRAINT ");
            try ident(w, x.check.name);
            try w.print(" CHECK ({s});", .{x.check.expression});
        },
        .drop_check => |x| {
            try alterTable(w, x.table);
            try w.writeAll(" DROP CONSTRAINT ");
            try ident(w, x.check.name);
            try w.writeByte(';');
        },
    }
}

fn keyName(w: W, table: []const u8, k: diff.KeyShape) !void {
    if (k.name) |n| return ident(w, n);
    var buf: [128]u8 = undefined;
    try ident(w, std.fmt.bufPrint(&buf, "{s}_pkey", .{table}) catch table);
}

fn createEnum(w: W, name: []const u8, values: []const []const u8) !void {
    try w.writeAll("CREATE TYPE ");
    try ident(w, name);
    try w.writeAll(" AS ENUM (");
    for (values, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try literal(w, v);
    }
    try w.writeAll(");");
}

fn createTable(w: W, t: snap.Table) !void {
    try w.writeAll("CREATE TABLE ");
    try ident(w, t.name);
    try w.writeAll(" (\n  ");
    var first = true;
    for (t.columns) |c| {
        if (!first) try w.writeAll(",\n  ");
        first = false;
        try columnDecl(w, c);
    }
    var pk_cols = false;
    for (t.columns) |c| if (c.primary_key) {
        pk_cols = true;
    };
    if (t.primary_key != null or pk_cols) {
        try w.writeAll(",\n  ");
        if (t.primary_key) |pk| if (pk.name) |n| {
            try w.writeAll("CONSTRAINT ");
            try ident(w, n);
            try w.writeByte(' ');
        };
        try w.writeAll("PRIMARY KEY (");
        if (t.primary_key) |pk| try idents(w, pk.columns) else {
            var n: usize = 0;
            for (t.columns) |c| if (c.primary_key) {
                if (n > 0) try w.writeAll(", ");
                n += 1;
                try ident(w, c.name);
            };
        }
        try w.writeByte(')');
    }
    for (t.checks) |c| {
        try w.writeAll(",\n  CONSTRAINT ");
        try ident(w, c.name);
        try w.print(" CHECK ({s})", .{c.expression});
    }
    try w.writeAll("\n);");
}

fn columnDecl(w: W, c: Column) !void {
    try ident(w, c.name);
    try w.print(" {s}", .{c.sql_type});
    if (!c.nullable) try w.writeAll(" NOT NULL");
    if (c.default) |d| {
        try w.writeAll(" DEFAULT ");
        try formatDefault(w, d, c.sql_type, c.default_sql);
    }
}

fn alterColumn(w: W, table: []const u8, before: Column, after: Column) !void {
    var stmts: usize = 0;
    const Stmt = struct {
        fn begin(ww: W, n: *usize, t: []const u8, cname: []const u8) !void {
            if (n.* > 0) try ww.writeByte('\n');
            n.* += 1;
            try alterTable(ww, t);
            try ww.writeAll(" ALTER COLUMN ");
            try ident(ww, cname);
        }
    };
    if (!std.mem.eql(u8, before.sql_type, after.sql_type)) {
        try Stmt.begin(w, &stmts, table, after.name);
        try w.print(" TYPE {s} USING ", .{after.sql_type});
        try ident(w, after.name);
        try w.print("::{s};", .{after.sql_type});
    }
    const default_changed = !optEql(before.default, after.default) or before.default_sql != after.default_sql;
    const null_changed = before.nullable != after.nullable;
    // Loosening: DROP DEFAULT before DROP NOT NULL; else NOT NULL first.
    const losing = !before.nullable and after.nullable;
    var step: usize = 0;
    while (step < 2) : (step += 1) {
        const do_default = (step == 0) == losing;
        if (do_default and default_changed) {
            try Stmt.begin(w, &stmts, table, after.name);
            if (after.default) |d| {
                try w.writeAll(" SET DEFAULT ");
                try formatDefault(w, d, after.sql_type, after.default_sql);
                try w.writeByte(';');
            } else try w.writeAll(" DROP DEFAULT;");
        } else if (!do_default and null_changed) {
            try Stmt.begin(w, &stmts, table, after.name);
            try w.writeAll(if (after.nullable) " DROP NOT NULL;" else " SET NOT NULL;");
        }
    }
}

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

const enum_drop_header = "-- KICK ENUM REMOVE";

fn removeEnumValue(w: W, x: @FieldType(Change, "remove_enum_value")) !void {
    try w.print("{s}\n-- enum: ", .{enum_drop_header});
    try commentSafe(w, x.@"enum", .ident);
    try w.writeAll("\n-- removed: ");
    for (x.removed, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try commentSafe(w, v, .literal);
    }
    try w.writeAll("\n-- columns: ");
    if (x.affected.len == 0) try w.writeAll("(none)");
    for (x.affected, 0..) |c, i| {
        if (i > 0) try w.writeAll(", ");
        try commentSafe(w, c.table, .raw);
        try w.writeByte('.');
        try commentSafe(w, c.column, .raw);
    }
    try w.writeAll(
        \\
        \\--
        \\-- This migration drops values from a PostgreSQL ENUM type. The
        \\-- runner refuses to apply it without the --confirm-enum-drop flag
        \\-- (or `confirmEnumDrop: true` in RunnerOptions). Inspect the
        \\-- column USING clauses below to confirm rows holding a removed
        \\-- value will fail loudly rather than silently coerce.
        \\ALTER TYPE 
    );
    try ident(w, x.@"enum");
    try w.writeAll(" RENAME TO ");
    var buf: [256]u8 = undefined;
    const old = std.fmt.bufPrint(&buf, "{s}__old", .{x.@"enum"}) catch return error.WriteFailed;
    try ident(w, old);
    try w.writeAll(";\n");
    try createEnum(w, x.@"enum", x.values);
    for (x.affected) |c| {
        if (c.default != null) {
            try w.writeByte('\n');
            try alterTable(w, c.table);
            try w.writeAll(" ALTER COLUMN ");
            try ident(w, c.column);
            try w.writeAll(" DROP DEFAULT;");
        }
        try w.writeByte('\n');
        try alterTable(w, c.table);
        try w.writeAll("\n  ALTER COLUMN ");
        try ident(w, c.column);
        try w.writeAll(" TYPE ");
        try ident(w, x.@"enum");
        try w.writeAll("\n  USING ");
        try ident(w, c.column);
        try w.writeAll("::text::");
        try ident(w, x.@"enum");
        try w.writeByte(';');
        if (c.default) |d| {
            try w.writeByte('\n');
            try alterTable(w, c.table);
            try w.writeAll(" ALTER COLUMN ");
            try ident(w, c.column);
            try w.print(" SET DEFAULT {s}::", .{stripCast(d)});
            try ident(w, x.@"enum");
            try w.writeByte(';');
        }
    }
    try w.writeAll("\nDROP TYPE ");
    try ident(w, old);
    try w.writeByte(';');
}

/// A trailing `::"type"` / `::type` cast removed.
fn stripCast(expr: []const u8) []const u8 {
    const e = std.mem.trimEnd(u8, expr, " ");
    const i = std.mem.findLast(u8, e, "::") orelse return std.mem.trim(u8, e, " ");
    const t = std.mem.trim(u8, std.mem.trim(u8, e[i + 2 ..], " "), "\"");
    if (t.len == 0 or !(std.ascii.isAlphabetic(t[0]) or t[0] == '_')) return std.mem.trim(u8, e, " ");
    for (t) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return std.mem.trim(u8, e, " ");
    return std.mem.trim(u8, e[0..i], " ");
}

/// A value in a `--` comment: line breaks collapse to a space, control
/// bytes become `\xhh`, so nothing ends the comment.
fn commentSafe(w: W, v: []const u8, how: enum { ident, literal, raw }) !void {
    var buf: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buf.deinit();
    switch (how) {
        .ident => try ident(&buf.writer, v),
        .literal => try literal(&buf.writer, v),
        .raw => try buf.writer.writeAll(v),
    }
    var prev_break = false;
    for (buf.written()) |ch| {
        if (ch == '\n' or ch == '\r') {
            if (!prev_break) try w.writeByte(' ');
            prev_break = true;
            continue;
        }
        prev_break = false;
        if ((ch <= 0x08) or ch == 0x0b or ch == 0x0c or (ch >= 0x0e and ch <= 0x1f) or ch == 0x7f) {
            try w.print("\\x{x:0>2}", .{ch});
        } else try w.writeByte(ch);
    }
}

/// kick/db's `formatDefault`: a text column's default is always a value; a
/// value with a cast is SQL; other types quote unless the value is a
/// keyword, function call, number or boolean their type takes bare.
pub fn formatDefault(w: W, value: []const u8, sql_type: []const u8, is_sql: bool) !void {
    if (is_sql) return w.writeAll(value);
    if (startsWord(sql_type, &.{ "text", "varchar", "char", "character", "citext" })) return literal(w, value);
    if (isCast(value)) return w.writeAll(value);
    if (!allowsExpressionDefault(sql_type)) return literal(w, value);
    if (value.len > 0 and for (value) |ch| {
        if (!(std.ascii.isUpper(ch) or ch == '_')) break false;
    } else true) return w.writeAll(value);
    if (isFunctionCall(value)) return w.writeAll(value);
    if (isNumber(value) or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return w.writeAll(value);
    return literal(w, value);
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// `^(a|b|…)\b`, case-insensitive.
fn startsWord(s: []const u8, words: []const []const u8) bool {
    for (words) |word| {
        if (s.len >= word.len and std.ascii.eqlIgnoreCase(s[0..word.len], word) and (s.len == word.len or !isWordChar(s[word.len]))) return true;
    }
    return false;
}

fn allowsExpressionDefault(sql_type: []const u8) bool {
    const base = if (std.mem.endsWith(u8, sql_type, "[]")) sql_type[0 .. sql_type.len - 2] else sql_type;
    return startsWord(base, &.{ "tinyint", "smallint", "mediumint", "integer", "int", "int2", "int4", "int8", "bigint", "serial", "bigserial", "smallserial", "real", "float", "float4", "float8", "double", "double precision", "numeric", "decimal", "money", "bit", "bool", "boolean", "timestamp", "timestamptz", "datetime", "date", "time", "timetz", "year", "interval", "uuid" });
}

/// `-?\d+(\.\d+)?`
fn isNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    const start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == start) return false;
    if (i == s.len) return true;
    if (s[i] != '.') return false;
    i += 1;
    const frac = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i > frac and i == s.len;
}

fn isFunctionCall(s: []const u8) bool {
    if (std.mem.findScalar(u8, s, '\\') != null) return false;
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    var i: usize = 1;
    while (i < s.len and isWordChar(s[i])) i += 1;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i >= s.len or s[i] != '(') return false;
    var depth: usize = 0;
    var quoted = false;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quoted) {
            if (ch == '\'') {
                if (i + 1 < s.len and s[i + 1] == '\'') i += 1 else quoted = false;
            }
            continue;
        }
        if (ch == '\'') quoted = true else if (ch == '(') depth += 1 else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i == s.len - 1;
        }
    }
    return false;
}

/// `'x'::jsonb`, `now()::date`, `ARRAY[1]::int[]`, `'x'::text::citext`.
fn isCast(s: []const u8) bool {
    const at = std.mem.findLast(u8, s, "::") orelse return false;
    if (!isTypeName(std.mem.trim(u8, s[at + 2 ..], " \t\n\r"))) return false;
    const v = s[0..at];
    return isQuoted(v) or isFunctionCall(v) or isArrayLiteral(v) or isCast(v);
}

/// `'…'` with `''` escapes and no backslash.
fn isQuoted(v: []const u8) bool {
    if (v.len < 2 or v[0] != '\'' or v[v.len - 1] != '\'') return false;
    var i: usize = 1;
    while (i < v.len - 1) : (i += 1) {
        if (v[i] == '\\') return false;
        if (v[i] == '\'') {
            if (i + 1 < v.len - 1 and v[i + 1] == '\'') i += 1 else return false;
        }
    }
    return true;
}

fn isArrayLiteral(v: []const u8) bool {
    if (v.len < 7 or !std.ascii.eqlIgnoreCase(v[0..6], "ARRAY[") or v[v.len - 1] != ']') return false;
    var it = std.mem.splitScalar(u8, v[6 .. v.len - 1], ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " \t\n\r");
        if (x.len == 0) continue;
        if (!(isQuoted(x) or isNumber(x))) return false;
    }
    return true;
}

/// A plain or quoted name, optionally schema-qualified, with `(n)` /
/// `(p, s)` and `[]`s.
fn isTypeName(t: []const u8) bool {
    var i: usize = 0;
    if (!namePart(t, &i)) return false;
    if (i < t.len and t[i] == '.') {
        i += 1;
        if (!namePart(t, &i)) return false;
    }
    var j = i;
    while (j < t.len and std.ascii.isWhitespace(t[j])) j += 1;
    if (j < t.len and t[j] == '(') {
        j += 1;
        const close = std.mem.findScalarPos(u8, t, j, ')') orelse return false;
        var it = std.mem.splitScalar(u8, t[j..close], ',');
        var n: usize = 0;
        while (it.next()) |p| : (n += 1) {
            const d = std.mem.trim(u8, p, " ");
            if (d.len == 0 or n > 1) return false;
            for (d) |ch| if (!std.ascii.isDigit(ch)) return false;
        }
        i = close + 1;
    }
    while (i + 1 < t.len and t[i] == '[' and t[i + 1] == ']') i += 2;
    return i == t.len;
}

fn namePart(t: []const u8, i: *usize) bool {
    if (i.* >= t.len) return false;
    if (t[i.*] == '"') {
        i.* += 1;
        const start = i.*;
        while (i.* < t.len) : (i.* += 1) if (t[i.*] == '"') {
            if (i.* + 1 < t.len and t[i.* + 1] == '"') i.* += 1 else break;
        };
        if (i.* >= t.len or i.* == start) return false;
        i.* += 1;
        return true;
    }
    if (!(std.ascii.isAlphabetic(t[i.*]) or t[i.*] == '_')) return false;
    i.* += 1;
    while (i.* < t.len and (isWordChar(t[i.*]) or t[i.*] == '$')) i.* += 1;
    return true;
}

const testing = std.testing;

fn col(name: []const u8, sql_type: []const u8, nullable: bool, default: ?[]const u8) Column {
    return .{ .key = name, .name = name, .sql_type = sql_type, .nullable = nullable, .default = default, .default_sql = false, .primary_key = false };
}

fn expectEmit(want: []const u8, changes: []const Change) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try emit(arena.allocator(), changes));
}

fn addDefault(sql_type: []const u8, default: []const u8) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var fba: std.heap.FixedBufferAllocator = .init(&S.buf);
    return emit(fba.allocator(), &.{.{ .add_column = .{ .table = "t", .column = col("c", sql_type, true, default) } }});
}

test "columns: add, drop, rename, alter in kick/db's statement order" {
    try expectEmit("ALTER TABLE \"users\" ADD COLUMN \"email\" varchar(255) NOT NULL;", &.{.{ .add_column = .{ .table = "users", .column = col("email", "varchar(255)", false, null) } }});
    try expectEmit("ALTER TABLE \"users\" DROP COLUMN \"legacy\";", &.{.{ .drop_column = .{ .table = "users", .column = col("legacy", "text", true, null) } }});
    try expectEmit("ALTER TABLE \"users\" RENAME COLUMN \"emailAddr\" TO \"email\";", &.{.{ .rename_column = .{ .table = "users", .from = "emailAddr", .to = "email" } }});
    try expectEmit(
        "ALTER TABLE \"users\" ALTER COLUMN \"age\" TYPE bigint USING \"age\"::bigint;\nALTER TABLE \"users\" ALTER COLUMN \"age\" SET NOT NULL;\nALTER TABLE \"users\" ALTER COLUMN \"age\" SET DEFAULT 0;",
        &.{.{ .alter_column = .{ .table = "users", .column = "age", .before = col("age", "integer", true, null), .after = col("age", "bigint", false, "0") } }},
    );
    // Loosening: the default goes before NOT NULL does.
    try expectEmit(
        "ALTER TABLE \"users\" ALTER COLUMN \"age\" DROP DEFAULT;\nALTER TABLE \"users\" ALTER COLUMN \"age\" DROP NOT NULL;",
        &.{.{ .alter_column = .{ .table = "users", .column = "age", .before = col("age", "integer", false, "0"), .after = col("age", "integer", true, null) } }},
    );
}

test "defaults: the column's type decides, as kick/db's formatDefault" {
    try testing.expect(std.mem.endsWith(u8, try addDefault("varchar(20)", "ACTIVE"), "DEFAULT 'ACTIVE';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("text", "0800"), "DEFAULT '0800';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("text", "true"), "DEFAULT 'true';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("varchar(40)", "now()"), "DEFAULT 'now()';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("jsonb", "{}"), "DEFAULT '{}';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("text[]", "{}"), "DEFAULT '{}';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("order_status", "ACTIVE"), "DEFAULT 'ACTIVE';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("flag_kind", "true"), "DEFAULT 'true';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("inet", "0.0.0.0"), "DEFAULT '0.0.0.0';"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("integer", "nextval('shared_ids')"), "DEFAULT nextval('shared_ids');"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("timestamptz", "CURRENT_TIMESTAMP"), "DEFAULT CURRENT_TIMESTAMP;"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("uuid", "gen_random_uuid()"), "DEFAULT gen_random_uuid();"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("integer", "0"), "DEFAULT 0;"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("boolean", "false"), "DEFAULT false;"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("status", "'active'::\"status\""), "DEFAULT 'active'::\"status\";"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("jsonb", "'[]'::jsonb"), "DEFAULT '[]'::jsonb;"));
    try testing.expect(std.mem.endsWith(u8, try addDefault("text", "it's"), "DEFAULT 'it''s';"));
}

test "indexes, keys, enums, checks, primary keys" {
    try expectEmit("CREATE UNIQUE INDEX \"u\" ON \"t\" USING gin (\"a\", \"b\") WHERE a > 0;", &.{.{ .add_index = .{ .table = "t", .index = .{ .name = "u", .columns = &.{ "a", "b" }, .unique = true, .where = "a > 0", .using = "gin" } } }});
    try expectEmit("DROP INDEX \"u\";", &.{.{ .drop_index = .{ .table = "t", .index = .{ .name = "u", .columns = &.{"a"}, .unique = false } } }});
    try expectEmit(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"posts_userId_fk\" FOREIGN KEY (\"userId\") REFERENCES \"users\" (\"id\") ON DELETE SET NULL ON UPDATE NO ACTION;",
        &.{.{ .add_foreign_key = .{ .table = "posts", .fk = .{ .name = "posts_userId_fk", .columns = &.{"userId"}, .ref_table = "users", .ref_columns = &.{"id"}, .on_delete = .set_null, .on_update = .no_action } } }},
    );
    try expectEmit("CREATE TYPE \"role\" AS ENUM ('a', 'b''c');", &.{.{ .create_enum = .{ .name = "role", .values = &.{ "a", "b'c" } } }});
    try expectEmit("ALTER TYPE \"role\" ADD VALUE 'z' BEFORE 'a';", &.{.{ .add_enum_value = .{ .@"enum" = "role", .value = "z", .before = "a" } }});
    try expectEmit(
        \\-- KICK ENUM REMOVE
        \\-- enum: "role"
        \\-- removed: 'a'
        \\-- columns: t.role
        \\--
        \\-- This migration drops values from a PostgreSQL ENUM type. The
        \\-- runner refuses to apply it without the --confirm-enum-drop flag
        \\-- (or `confirmEnumDrop: true` in RunnerOptions). Inspect the
        \\-- column USING clauses below to confirm rows holding a removed
        \\-- value will fail loudly rather than silently coerce.
        \\ALTER TYPE "role" RENAME TO "role__old";
        \\CREATE TYPE "role" AS ENUM ('b');
        \\ALTER TABLE "t" ALTER COLUMN "role" DROP DEFAULT;
        \\ALTER TABLE "t"
        \\  ALTER COLUMN "role" TYPE "role"
        \\  USING "role"::text::"role";
        \\ALTER TABLE "t" ALTER COLUMN "role" SET DEFAULT 'b'::"role";
        \\DROP TYPE "role__old";
    , &.{.{ .remove_enum_value = .{ .@"enum" = "role", .removed = &.{"a"}, .values = &.{"b"}, .affected = &.{.{ .table = "t", .column = "role", .default = "'b'::\"role__old\"" }} } }});
    try expectEmit("ALTER TABLE \"t\" ADD CONSTRAINT \"pos\" CHECK (a > 0);", &.{.{ .add_check = .{ .table = "t", .check = .{ .name = "pos", .expression = "a > 0" } } }});
    try expectEmit(
        "ALTER TABLE \"t\" DROP CONSTRAINT \"t_pkey\";\nALTER TABLE \"t\" ADD CONSTRAINT \"t_pkey\" PRIMARY KEY (\"a\", \"b\");",
        &.{ .{ .alter_primary_key = .{ .table = "t", .before = .{ .name = "t_pkey", .columns = &.{"a"} }, .after = .{} } }, .{ .alter_primary_key = .{ .table = "t", .before = .{}, .after = .{ .name = "t_pkey", .columns = &.{ "a", "b" } } } } },
    );
    try expectEmit("ALTER TABLE \"a\" RENAME TO \"b\";\nDROP TABLE \"b\";", &.{ .{ .rename_table = .{ .from = "a", .to = "b" } }, .{ .drop_table = .{ .name = "b", .columns = &.{}, .indexes = &.{}, .foreign_keys = &.{}, .checks = &.{}, .primary_key = null } } });
}
