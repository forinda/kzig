//! kick/db's query builder: `selectFrom`, `insertInto`, `updateTable`,
//! `deleteFrom`, checked against a `db.Schema` at comptime. Builders are
//! values; SQL is written when a query runs, with every value a parameter.
const std = @import("std");
const schema = @import("schema.zig");
const Timestamp = @import("timestamp.zig").Timestamp;
const pg = @import("pg.zig");
const emit_sqlite = @import("emit_sqlite.zig");
const relational = @import("relational.zig");
const dbm = @import("db.zig");

const Allocator = std.mem.Allocator;
const EnumLiteral = @TypeOf(.enum_literal);

/// A query as written: SQL with `$n` placeholders and their values as text.
pub const Sql = struct { sql: []const u8, params: []const dbm.Param, dialect: Dialect = .postgres };
const Dialect = dbm.Dialect;

pub const InsertManyOptions = struct {
    /// Parameters one statement may bind; the database's limit by default.
    max_params: ?usize = null,
    /// Several statements in one transaction (D1: one batch).
    atomic: bool = true,
};

/// Where queries run: the pool, or a transaction.
pub const Conn = union(enum) { pool: *dbm.Pool, tx: *dbm.Tx };

/// kick/db's client over a schema: `selectFrom(.users)`, `insertInto`,
/// `updateTable`, `deleteFrom`. Every allocator passed in is a request arena:
/// rows, SQL and strings are left in it, never freed one by one.
pub fn Client(comptime S: type) type {
    return struct {
        conn: Conn,

        const Self = @This();

        pub fn init(conn: Conn) Self {
            return .{ .conn = conn };
        }

        pub fn selectFrom(self: Self, comptime t: S.Tag) Select(S, .{ .from = @tagName(t) }, void, void) {
            return .{ .conn = self.conn, .wheres = {}, .ons = {} };
        }

        pub fn insertInto(self: Self, comptime t: S.Tag) Insert(S, @tagName(t), null, null) {
            return .{ .conn = self.conn };
        }

        pub fn updateTable(self: Self, comptime t: S.Tag) Update(S, @tagName(t), void, null) {
            return .{ .conn = self.conn, .wheres = {} };
        }

        pub fn deleteFrom(self: Self, comptime t: S.Tag) Delete(S, @tagName(t), void, null) {
            return .{ .conn = self.conn, .wheres = {} };
        }

        /// kick/db's `db.query.<table>`: `findMany`, `findFirst`, `findUnique`
        /// with `columns`, `where`, `orderBy`, `limit`, `offset` and `with`.
        pub fn query(self: Self, comptime t: S.Tag) relational.Relational(S, @tagName(t)) {
            return .{ .conn = self.conn };
        }

        /// kick/db's `insertMany`: any number of rows, in as few statements as
        /// the database's parameter limit allows (Postgres 65,535; SQLite
        /// 32,766; D1 100), counted on the compiled SQL. With `.atomic` more
        /// than one statement runs in one transaction (on D1: one batch).
        /// The rows inserted.
        pub fn insertMany(self: Self, a: Allocator, comptime t: S.Tag, rows: []const S.Table(t).Insert, opts: InsertManyOptions) !u64 {
            const chunks = try self.chunksOf(a, t, rows, opts);
            if (chunks.len > 1 and opts.atomic) switch (self.conn) {
                .pool => |pool| if (pool.batchOnly()) {
                    const stmts = try a.alloc(@import("d1.zig").Stmt, chunks.len);
                    for (chunks, stmts) |chunk, *st| {
                        const q = try self.insertInto(t).valuesMany(chunk).toSql(a);
                        st.* = .{ .sql = q.sql, .params = q.params };
                    }
                    try pool.batch(stmts);
                    return rows.len;
                } else {
                    var tx = try pool.begin();
                    defer tx.deinit();
                    const n = try Self.init(.{ .tx = &tx }).insertChunks(a, t, chunks);
                    try tx.commit();
                    return n;
                },
                .tx => {},
            };
            return self.insertChunks(a, t, chunks);
        }

        /// `insertMany`, the stored rows back in input order. On D1 more
        /// than one statement can't be atomic (a batch's rows don't come
        /// back): `.atomic = false`, or `error.TransactionsUnsupported`.
        pub fn insertManyReturning(self: Self, a: Allocator, comptime t: S.Tag, rows: []const S.Table(t).Insert, opts: InsertManyOptions) ![]S.Table(t).Row {
            const chunks = try self.chunksOf(a, t, rows, opts);
            if (chunks.len > 1 and opts.atomic) switch (self.conn) {
                .pool => |pool| {
                    var tx = try pool.begin(); // D1: TransactionsUnsupported
                    defer tx.deinit();
                    const out = try Self.init(.{ .tx = &tx }).returningChunks(a, t, chunks);
                    try tx.commit();
                    return out;
                },
                .tx => {},
            };
            return self.returningChunks(a, t, chunks);
        }

        fn insertChunks(self: Self, a: Allocator, comptime t: S.Tag, chunks: []const []const S.Table(t).Insert) !u64 {
            var n: u64 = 0;
            for (chunks) |chunk| n += try self.insertInto(t).valuesMany(chunk).execute(a);
            return n;
        }

        fn returningChunks(self: Self, a: Allocator, comptime t: S.Tag, chunks: []const []const S.Table(t).Insert) ![]S.Table(t).Row {
            var out: std.ArrayList(S.Table(t).Row) = .empty;
            for (chunks) |chunk| try out.appendSlice(a, try self.insertInto(t).valuesMany(chunk).returningAll().execute(a));
            return out.items;
        }

        /// kick/db's `chunksFor`: a first guess of one parameter per column,
        /// shrunk in proportion when a chunk's statement binds too many.
        fn chunksOf(self: Self, a: Allocator, comptime t: S.Tag, rows: []const S.Table(t).Insert, opts: InsertManyOptions) ![]const []const S.Table(t).Insert {
            const pool = switch (self.conn) {
                .pool => |p| p,
                .tx => |tx| tx.pool,
            };
            const max: usize = opts.max_params orelse if (pool.batchOnly()) @as(usize, @import("d1.zig").max_params) else switch (S.dialect) {
                .postgres => 65_535,
                .sqlite => 32_766,
            };
            if (max == 0) return error.MaxParamsTooSmall;
            var size: usize = @max(1, max / @max(1, S.Table(t).column_keys.len));
            var out: std.ArrayList([]const S.Table(t).Insert) = .empty;
            var i: usize = 0;
            while (i < rows.len) {
                const chunk = rows[i..@min(rows.len, i + size)];
                const n = (try self.insertInto(t).valuesMany(chunk).toSql(a)).params.len;
                if (n > max) {
                    if (chunk.len == 1) return error.MaxParamsTooSmall;
                    size = @max(1, @min(chunk.len - 1, chunk.len * max / n));
                    continue;
                }
                try out.append(a, chunk);
                i += chunk.len;
            }
            return out.items;
        }

        /// kick/db's `upsert`: insert, or update the row whose `target` key
        /// exists (`.update = .all` (default), `.none`, or a tuple of columns).
        /// The row as stored comes back either way.
        pub fn upsert(self: Self, a: Allocator, comptime t: S.Tag, values: S.Table(t).Insert, comptime opts: anytype) !S.Table(t).Row {
            const update = if (@hasField(@TypeOf(opts), "update")) opts.update else .all;
            if (try self.insertInto(t).values(values).onConflict(opts.target, update).returningAll().executeTakeFirst(a)) |row| return row;
            // DO NOTHING returned nothing: the row was there; read it by its key.
            var key: TargetValues(S.Table(t), opts.target) = undefined;
            inline for (@typeInfo(@TypeOf(key)).@"struct".field_names) |f| {
                const v = @field(values, f);
                @field(key, f) = if (@typeInfo(@TypeOf(v)) == .optional) (v orelse return error.MissingTarget) else v;
            }
            return self.selectFrom(t).whereExpr(Match(@TypeOf(key)){ .values = key }).executeTakeFirstOrThrow(a);
        }

        /// kick/db's `findOrCreate`: the row matching `where`, or one created
        /// from `where` and `create`. Race-safe: a creator that loses reads
        /// the winner's row; inside a transaction the insert runs in a
        /// savepoint so the loss doesn't abort it.
        pub fn findOrCreate(self: Self, a: Allocator, comptime t: S.Tag, where: anytype, create: anytype) !struct { row: S.Table(t).Row, created: bool } {
            const T = S.Table(t);
            if (@typeInfo(@TypeOf(where)).@"struct".field_names.len == 0) @compileError(T.name_ ++ ": findOrCreate needs a where");
            inline for (@typeInfo(@TypeOf(create)).@"struct".field_names) |f| if (!@hasField(T.Insert, f))
                @compileError(T.name_ ++ "." ++ f ++ ": no such column for findOrCreate's create");
            const find = self.selectFrom(t).whereExpr(Match(@TypeOf(where)){ .values = where });
            if (try find.executeTakeFirst(a)) |row| return .{ .row = row, .created = false };
            var ins: T.Insert = undefined;
            inline for (@typeInfo(T.Insert).@"struct".field_names) |f| {
                if (@hasField(@TypeOf(create), f)) {
                    @field(ins, f) = @field(create, f);
                } else if (@hasField(@TypeOf(where), f)) {
                    @field(ins, f) = @field(where, f);
                } else if (comptime @typeInfo(@FieldType(T.Insert, f)) == .optional) {
                    @field(ins, f) = null;
                } else @compileError(T.name_ ++ "." ++ f ++ ": findOrCreate needs it in where or create");
            }
            const q = self.insertInto(t).values(ins).returningAll();
            const row = switch (self.conn) {
                .pool => q.executeTakeFirstOrThrow(a),
                .tx => |tx| blk: {
                    try tx.execScript("SAVEPOINT kzig_find_or_create");
                    const r = q.executeTakeFirstOrThrow(a);
                    try tx.execScript(if (r) |_| "RELEASE SAVEPOINT kzig_find_or_create" else |_| "ROLLBACK TO SAVEPOINT kzig_find_or_create");
                    break :blk r;
                },
            } catch |err| switch (err) {
                error.Conflict => return .{ .row = try find.executeTakeFirst(a) orelse return error.Conflict, .created = false },
                else => return err,
            };
            return .{ .row = row, .created = true };
        }
    };
}

// ---- writing SQL

pub const Writer = struct {
    a: Allocator,
    dialect: Dialect = .postgres,
    buf: std.ArrayList(u8) = .empty,
    params: std.ArrayList(dbm.Param) = .empty,

    pub fn raw(w: *Writer, s: []const u8) !void {
        try w.buf.appendSlice(w.a, s);
    }

    pub fn ident(w: *Writer, s: []const u8) !void {
        try w.buf.append(w.a, '"');
        for (s) |ch| {
            if (ch == '"') try w.buf.append(w.a, '"');
            try w.buf.append(w.a, ch);
        }
        try w.buf.append(w.a, '"');
    }

    pub fn param(w: *Writer, v: anytype) !void {
        try w.params.append(w.a, try pg.encodeValue(w.a, v, w.dialect));
        try w.buf.print(w.a, "{s}{d}", .{ if (w.dialect == .sqlite) "?" else "$", w.params.items.len });
    }

    /// A comparison's operator; SQLite has no ILIKE, and its LIKE already
    /// ignores ASCII case.
    pub fn op(w: *Writer, comptime o: []const u8) !void {
        if (w.dialect == .sqlite and comptime std.mem.endsWith(u8, o, "ILIKE")) return w.raw(" " ++ o[0 .. o.len - 5] ++ "LIKE ");
        try w.raw(" " ++ o ++ " ");
    }

    pub fn done(w: *Writer) Sql {
        return .{ .sql = w.buf.items, .params = w.params.items, .dialect = w.dialect };
    }
};

/// What unqualified column names mean while rendering.
pub const Scope = struct {
    S: type,
    from: []const u8,
    qualify: bool,
    /// The table's alias in this statement (relational reads): its columns
    /// are written `"alias"."col"`.
    alias: ?[]const u8 = null,
};

const ColRef = struct {
    table: []const u8,
    key: []const u8,
    name: []const u8,
    Z: type,
    nullable: bool,
    qualified: bool,
    alias: ?[]const u8 = null,
};

fn tableTag(comptime S: type, comptime declared: []const u8) ?[]const u8 {
    for (@typeInfo(S.Tag).@"enum".field_names) |tag| {
        if (std.mem.eql(u8, S.Table(@field(S.Tag, tag)).name_, declared)) return tag;
    }
    return null;
}

/// `.email` (the scope's table) or `.@"tasks.id"` (any table, by SQL name).
fn resolveCol(comptime sc: Scope, comptime ref: []const u8) ColRef {
    comptime {
        const S = sc.S;
        const dot = std.mem.findScalar(u8, ref, '.');
        if (dot != null and sc.alias != null)
            @compileError(ref ++ ": a relational query names its own table's columns unqualified");
        const tag = if (dot) |i| (tableTag(S, ref[0..i]) orelse @compileError(ref ++ ": no table " ++ ref[0..i])) else sc.from;
        const key = if (dot) |i| ref[i + 1 ..] else ref;
        const T = S.Table(@field(S.Tag, tag));
        const info = S.info(@field(S.Tag, tag));
        for (T.column_keys, T.column_defs, info.columns) |k, def, col| if (std.mem.eql(u8, k, key)) return .{
            .table = info.name,
            .key = k,
            .name = col.name,
            .Z = schema.ZigType(def.type),
            .nullable = col.nullable,
            .qualified = sc.qualify or dot != null,
            .alias = if (dot == null) sc.alias else null,
        };
        @compileError(info.name ++ ": no column " ++ key);
    }
}

fn zigName(comptime Z: type) []const u8 {
    return if (@typeInfo(Z) == .@"enum" and @hasDecl(Z, "pg_name")) Z.pg_name else @typeName(Z);
}

fn writeCol(w: *Writer, comptime r: ColRef) !void {
    if (r.alias) |al| {
        try w.ident(al);
        try w.raw(".");
    } else if (r.qualified) {
        try w.ident(r.table);
        try w.raw(".");
    }
    try w.ident(r.name);
}

fn isStringLike(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| (p.size == .slice and p.child == u8) or (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8),
        else => false,
    };
}

/// A value's type as stored in a builder: literals become runtime types.
fn Norm(comptime V: type) type {
    if (V == comptime_int) return i64;
    if (V == comptime_float) return f64;
    if (V == EnumLiteral) return void;
    if (isStringLike(V)) return []const u8;
    if (@typeInfo(V) == .pointer and @typeInfo(V).pointer.size == .one and @typeInfo(@typeInfo(V).pointer.child) == .array)
        return []const Norm(@typeInfo(@typeInfo(V).pointer.child).array.child);
    return V;
}

fn norm(v: anytype) Norm(@TypeOf(v)) {
    const V = @TypeOf(v);
    if (V == EnumLiteral) return {};
    if (comptime (@typeInfo(V) == .pointer and @typeInfo(V).pointer.size == .one and @typeInfo(@typeInfo(V).pointer.child) == .array and !isStringLike(V))) {
        const E = Norm(@typeInfo(@typeInfo(V).pointer.child).array.child);
        if (E == @typeInfo(@typeInfo(V).pointer.child).array.child) return v;
        @compileError("db: give inArray a slice of runtime values");
    }
    return v;
}

fn litName(comptime V: type, v: anytype) ?[]const u8 {
    return if (V == EnumLiteral) @tagName(v) else null;
}

/// A value of type `V` for column `r`: a compile error naming both otherwise.
fn checkValue(comptime r: ColRef, comptime V: type) void {
    const Z = r.Z;
    const ok = V == Z or
        (@typeInfo(Z) == .int and (@typeInfo(V) == .int or V == comptime_int)) or
        (@typeInfo(Z) == .float and (@typeInfo(V) == .int or @typeInfo(V) == .float or V == comptime_int or V == comptime_float)) or
        (Z == []const u8 and isStringLike(V));
    if (!ok) @compileError(r.table ++ "." ++ r.key ++ ": expects " ++ @typeName(Z) ++ ", got " ++ @typeName(V));
}

// ---- conditions

fn Cmp(comptime col: []const u8, comptime op: []const u8, comptime V: type, comptime lit: ?[]const u8) type {
    return struct {
        value: Norm(V),

        pub fn render(self: @This(), comptime sc: Scope, w: *Writer) !void {
            const l = comptime resolveCol(sc, col);
            try writeCol(w, l);
            try w.op(op);
            if (lit) |name| {
                // An enum's value, or another column (`.@"teams.id"`).
                if (comptime @typeInfo(l.Z) == .@"enum" and @hasField(l.Z, name)) return w.param(@as([]const u8, name));
                const r = comptime resolveCol(sc, name);
                if (comptime r.Z != l.Z) @compileError(l.table ++ "." ++ l.key ++ " and " ++ r.table ++ "." ++ r.key ++ ": compares " ++ zigName(l.Z) ++ " with " ++ zigName(r.Z));
                return writeCol(w, r);
            }
            comptime checkValue(l, V);
            try w.param(self.value);
        }
    };
}

fn cmp(comptime col: anytype, comptime op: []const u8, value: anytype) Cmp(@tagName(col), op, @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return .{ .value = norm(value) };
}

pub fn eq(comptime col: anytype, value: anytype) Cmp(@tagName(col), "=", @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return cmp(col, "=", value);
}
pub fn ne(comptime col: anytype, value: anytype) Cmp(@tagName(col), "<>", @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return cmp(col, "<>", value);
}
pub fn gt(comptime col: anytype, value: anytype) Cmp(@tagName(col), ">", @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return cmp(col, ">", value);
}
pub fn gte(comptime col: anytype, value: anytype) Cmp(@tagName(col), ">=", @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return cmp(col, ">=", value);
}
pub fn lt(comptime col: anytype, value: anytype) Cmp(@tagName(col), "<", @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return cmp(col, "<", value);
}
pub fn lte(comptime col: anytype, value: anytype) Cmp(@tagName(col), "<=", @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return cmp(col, "<=", value);
}
pub fn like(comptime col: anytype, pattern: []const u8) Cmp(@tagName(col), "LIKE", []const u8, null) {
    return .{ .value = pattern };
}
pub fn notLike(comptime col: anytype, pattern: []const u8) Cmp(@tagName(col), "NOT LIKE", []const u8, null) {
    return .{ .value = pattern };
}
pub fn ilike(comptime col: anytype, pattern: []const u8) Cmp(@tagName(col), "ILIKE", []const u8, null) {
    return .{ .value = pattern };
}

/// `pattern` with `\`, `%` and `_` escaped, for `like` on user input.
pub fn escapeLike(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (ch == '\\' or ch == '%' or ch == '_') try out.append(a, '\\');
        try out.append(a, ch);
    }
    return out.items;
}

fn Null(comptime col: []const u8, comptime negate: bool) type {
    return struct {
        pub fn render(_: @This(), comptime sc: Scope, w: *Writer) !void {
            try writeCol(w, comptime resolveCol(sc, col));
            try w.raw(if (negate) " IS NOT NULL" else " IS NULL");
        }
    };
}
pub fn isNull(comptime col: anytype) Null(@tagName(col), false) {
    return .{};
}
pub fn isNotNull(comptime col: anytype) Null(@tagName(col), true) {
    return .{};
}

fn In(comptime col: []const u8, comptime negate: bool, comptime L: type) type {
    return struct {
        values: L,

        pub fn render(self: @This(), comptime sc: Scope, w: *Writer) !void {
            const r = comptime resolveCol(sc, col);
            comptime checkValue(r, @typeInfo(L).pointer.child);
            // kick/db: an empty IN matches nothing, an empty NOT IN everything.
            if (self.values.len == 0) return w.raw(if (negate) "true" else "false");
            try writeCol(w, r);
            try w.raw(if (negate) " NOT IN (" else " IN (");
            for (self.values, 0..) |v, i| {
                if (i > 0) try w.raw(", ");
                try w.param(v);
            }
            try w.raw(")");
        }
    };
}
pub fn inArray(comptime col: anytype, values: anytype) In(@tagName(col), false, Norm(@TypeOf(values))) {
    return .{ .values = norm(values) };
}
pub fn notInArray(comptime col: anytype, values: anytype) In(@tagName(col), true, Norm(@TypeOf(values))) {
    return .{ .values = norm(values) };
}

fn Between(comptime col: []const u8, comptime V: type) type {
    return struct {
        low: Norm(V),
        high: Norm(V),

        pub fn render(self: @This(), comptime sc: Scope, w: *Writer) !void {
            const r = comptime resolveCol(sc, col);
            comptime checkValue(r, V);
            try writeCol(w, r);
            try w.raw(" BETWEEN ");
            try w.param(self.low);
            try w.raw(" AND ");
            try w.param(self.high);
        }
    };
}
pub fn between(comptime col: anytype, low: anytype, high: @TypeOf(low)) Between(@tagName(col), @TypeOf(low)) {
    return .{ .low = norm(low), .high = norm(high) };
}

fn Group(comptime T: type, comptime joiner: []const u8, comptime empty: []const u8) type {
    return struct {
        parts: T,

        pub fn render(self: @This(), comptime sc: Scope, w: *Writer) !void {
            var n: usize = 0;
            inline for (@typeInfo(T).@"struct".field_names) |f| {
                if (present(@field(self.parts, f))) n += 1;
            }
            // kick/db: `and()` of nothing matches everything, `or()` nothing;
            // a null member is left out.
            if (n == 0) return w.raw(empty);
            try w.raw("(");
            var first = true;
            inline for (@typeInfo(T).@"struct".field_names) |f| {
                const part = @field(self.parts, f);
                switch (@typeInfo(@TypeOf(part))) {
                    .null => {},
                    .optional => if (part) |p| {
                        if (!first) try w.raw(joiner);
                        first = false;
                        try p.render(sc, w);
                    },
                    else => {
                        if (!first) try w.raw(joiner);
                        first = false;
                        try part.render(sc, w);
                    },
                }
            }
            try w.raw(")");
        }
    };
}

fn present(part: anytype) bool {
    return switch (@typeInfo(@TypeOf(part))) {
        .null => false,
        .optional => part != null,
        else => true,
    };
}

/// kick/db's `and(…)`: `and` is a Zig keyword.
pub fn all(parts: anytype) Group(@TypeOf(parts), " AND ", "true") {
    return .{ .parts = parts };
}
/// kick/db's `or(…)`.
pub fn any(parts: anytype) Group(@TypeOf(parts), " OR ", "false") {
    return .{ .parts = parts };
}

fn Not(comptime E: type) type {
    return struct {
        inner: E,

        pub fn render(self: @This(), comptime sc: Scope, w: *Writer) !void {
            try w.raw("NOT (");
            try self.inner.render(sc, w);
            try w.raw(")");
        }
    };
}
pub fn not(e: anytype) Not(@TypeOf(e)) {
    return .{ .inner = e };
}

fn Exists(comptime Q: type) type {
    return struct {
        q: Q,

        pub fn render(self: @This(), comptime _: Scope, w: *Writer) !void {
            try w.raw("EXISTS (");
            try self.q.renderInto(w);
            try w.raw(")");
        }
    };
}
pub fn exists(subquery: anytype) Exists(@TypeOf(subquery)) {
    return .{ .q = subquery };
}

const Raw = struct {
    text: []const u8,

    /// In parentheses, so an OR inside can't swallow the conditions around it.
    pub fn render(self: Raw, comptime _: Scope, w: *Writer) !void {
        try w.raw("(");
        try w.raw(self.text);
        try w.raw(")");
    }
};
/// SQL written as is: never put input in it, pass values to the helpers.
pub fn sql(comptime text: []const u8) Raw {
    return .{ .text = text };
}

pub const Op = enum { eq, ne, gt, gte, lt, lte, like, not_like, ilike, in, not_in, is_null, is_not_null };

fn OpExpr(comptime col: anytype, comptime op: Op, comptime V: type, comptime lit: ?[]const u8) type {
    return switch (op) {
        .eq => Cmp(@tagName(col), "=", V, lit),
        .ne => Cmp(@tagName(col), "<>", V, lit),
        .gt => Cmp(@tagName(col), ">", V, lit),
        .gte => Cmp(@tagName(col), ">=", V, lit),
        .lt => Cmp(@tagName(col), "<", V, lit),
        .lte => Cmp(@tagName(col), "<=", V, lit),
        .like => Cmp(@tagName(col), "LIKE", V, lit),
        .not_like => Cmp(@tagName(col), "NOT LIKE", V, lit),
        .ilike => Cmp(@tagName(col), "ILIKE", V, lit),
        .in => In(@tagName(col), false, Norm(V)),
        .not_in => In(@tagName(col), true, Norm(V)),
        .is_null => Null(@tagName(col), false),
        .is_not_null => Null(@tagName(col), true),
    };
}

fn opExpr(comptime col: anytype, comptime op: Op, value: anytype) OpExpr(col, op, @TypeOf(value), if (@TypeOf(value) == EnumLiteral) @tagName(value) else null) {
    return switch (op) {
        .in, .not_in => .{ .values = norm(value) },
        .is_null, .is_not_null => .{},
        else => .{ .value = norm(value) },
    };
}

// ---- running

fn connDialect(conn: Conn) Dialect {
    return switch (conn) {
        .pool => |p| p.dialect(),
        .tx => |t| t.pool.dialect(),
    };
}

pub fn runRows(conn: Conn, a: Allocator, comptime Row: type, q: Sql) ![]Row {
    // A schema's SQL only runs on its own kind of database.
    if (connDialect(conn) != q.dialect) return error.DialectMismatch;
    return switch (conn) {
        .pool => |p| p.queryParams(a, Row, q.sql, q.params),
        .tx => |t| t.queryParams(a, Row, q.sql, q.params),
    };
}

fn runExec(conn: Conn, q: Sql) !u64 {
    if (connDialect(conn) != q.dialect) return error.DialectMismatch;
    return switch (conn) {
        .pool => |p| p.execParams(q.sql, q.params),
        .tx => |t| t.execParams(q.sql, q.params),
    };
}

/// Rows, or the affected count for a statement without RETURNING.
fn Result(comptime Row: type) type {
    return if (Row == void) u64 else []Row;
}

fn execute_(b: anytype, a: Allocator) !Result(@TypeOf(b).Row) {
    const Row = @TypeOf(b).Row;
    const q = try b.toSql(a);
    if (Row == void) return runExec(b.conn, q);
    return runRows(b.conn, a, Row, q);
}

fn takeFirst(b: anytype, a: Allocator) !?@TypeOf(b).Row {
    if (@TypeOf(b).Row == void) @compileError("db: executeTakeFirst needs rows: add returning(…)");
    const rows = try execute_(b, a);
    return if (rows.len > 0) rows[0] else null;
}

/// kick/db's `executeTakeFirstOrThrow`: no row is `error.NotFound` (404).
fn takeFirstOrThrow(b: anytype, a: Allocator) !@TypeOf(b).Row {
    return try takeFirst(b, a) orelse error.NotFound;
}

const Conflict = struct {
    target: []const []const u8,
    update: union(enum) { all, none, cols: []const []const u8 },
};

fn conflictOf(comptime sc: Scope, comptime target: anytype, comptime update: anytype) Conflict {
    const U = @TypeOf(update);
    if (@typeInfo(@TypeOf(target)).@"struct".field_names.len == 0)
        @compileError(sc.S.Table(@field(sc.S.Tag, sc.from)).name_ ++ ": upsert needs a target");
    for (groupRefs(target)) |k| _ = resolveCol(sc, k);
    if (U != EnumLiteral) for (groupRefs(update)) |k| {
        _ = resolveCol(sc, k);
    };
    return .{
        .target = groupRefs(target),
        .update = if (U == EnumLiteral) (if (update == .all) .all else if (update == .none) .none else @compileError("db: update is .all, .none or a tuple of columns")) else .{ .cols = groupRefs(update) },
    };
}

/// The `target` columns of an Insert, unwrapped.
fn TargetValues(comptime T: type, comptime target: anytype) type {
    comptime {
        const keys = groupRefs(target);
        var types: [keys.len]type = undefined;
        var attrs: [keys.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (keys, 0..) |k, i| {
            const F = @FieldType(T.Insert, k);
            types[i] = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
            attrs[i] = .{};
        }
        const t = types;
        const at = attrs;
        return @Struct(.auto, null, keys[0..keys.len], &t, &at);
    }
}

fn contains(comptime list: []const []const u8, comptime k: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, k)) return true;
    return false;
}

/// `"a" = $1 AND "b" = $2` from a struct's fields (findOrCreate's `where`).
fn Match(comptime V: type) type {
    return struct {
        values: V,

        pub fn render(self: @This(), comptime sc: Scope, w: *Writer) !void {
            inline for (@typeInfo(V).@"struct".field_names, 0..) |f, i| {
                if (i > 0) try w.raw(" AND ");
                const r = comptime resolveCol(sc, f);
                const v = @field(self.values, f);
                const F = @TypeOf(v);
                try writeCol(w, r);
                if (comptime @typeInfo(F) == .optional) {
                    if (v) |x| {
                        try w.raw(" = ");
                        try w.param(x);
                    } else try w.raw(" IS NULL");
                } else {
                    if (comptime F != EnumLiteral) comptime checkValue(r, F);
                    try w.raw(" = ");
                    try w.param(v);
                }
            }
        }
    };
}

// ---- builders

/// Conditions added one `where` at a time, ANDed.
fn Chain(comptime Prev: type, comptime E: type) type {
    return struct {
        prev: Prev,
        last: E,

        const len = chainLen(Prev) + 1;
    };
}

fn chainLen(comptime C: type) usize {
    return if (C == void) 0 else C.len;
}

fn renderWheres(chain: anytype, comptime sc: Scope, w: *Writer) !void {
    const C = @TypeOf(chain);
    if (C == void) return;
    if (chainLen(C) == 1) try w.raw(" WHERE ") else {
        try renderWheres(chain.prev, sc, w);
        try w.raw(" AND ");
    }
    if (chainLen(C) == 1) return chain.last.render(sc, w);
    try chain.last.render(sc, w);
}

const Item = struct { ref: []const u8, as: []const u8 };
const Join = struct { tag: []const u8, left: bool };
const Order = struct { ref: []const u8, desc: bool };

const SelectSpec = struct {
    from: []const u8,
    items: ?[]const Item = null,
    joins: []const Join = &.{},
    order: []const Order = &.{},
    group: []const []const u8 = &.{},
    distinct: bool = false,
};

/// `.id`, `.@"tasks.id"` or `"tasks.title as taskTitle"`.
fn parseItems(comptime items: anytype) []const Item {
    comptime {
        var out: []const Item = &.{};
        for (@typeInfo(@TypeOf(items)).@"struct".field_names) |f| {
            const v = @field(items, f);
            const text: []const u8 = if (@TypeOf(v) == EnumLiteral) @tagName(v) else v;
            const item: Item = if (std.mem.find(u8, text, " as ")) |i|
                .{ .ref = text[0..i], .as = text[i + 4 ..] }
            else
                .{ .ref = text, .as = if (std.mem.findScalar(u8, text, '.')) |d| text[d + 1 ..] else text };
            out = out ++ [_]Item{item};
        }
        return out;
    }
}

fn allItems(comptime S: type, comptime tag: []const u8) []const Item {
    comptime {
        var out: []const Item = &.{};
        for (S.Table(@field(S.Tag, tag)).column_keys) |k| out = out ++ [_]Item{.{ .ref = k, .as = k }};
        return out;
    }
}

fn leftJoined(comptime spec: SelectSpec, comptime table_name: []const u8, comptime S: type) bool {
    for (spec.joins) |j| if (j.left and std.mem.eql(u8, S.info(@field(S.Tag, j.tag)).name, table_name)) return true;
    return false;
}

fn RowOf(comptime sc: Scope, comptime items: []const Item, comptime spec: ?SelectSpec) type {
    comptime {
        // Every column of the table, in order: its own Row type.
        const all_cols = allItems(sc.S, sc.from);
        if (items.len == all_cols.len and (spec == null or spec.?.joins.len == 0)) {
            const same = for (items, all_cols) |x, y| {
                if (!std.mem.eql(u8, x.ref, y.ref) or !std.mem.eql(u8, x.as, y.as)) break false;
            } else true;
            if (same) return sc.S.Table(@field(sc.S.Tag, sc.from)).Row;
        }
        var names: [items.len][]const u8 = undefined;
        var types: [items.len]type = undefined;
        var attrs: [items.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (items, 0..) |it, i| {
            const r = resolveCol(sc, it.ref);
            const optional = r.nullable or (spec != null and leftJoined(spec.?, r.table, sc.S));
            names[i] = it.as;
            types[i] = if (optional) ?r.Z else r.Z;
            attrs[i] = .{};
        }
        const n = names;
        const t = types;
        const a = attrs;
        return @Struct(.auto, null, &n, &t, &a);
    }
}

fn renderItems(comptime sc: Scope, comptime items: []const Item, w: *Writer) !void {
    inline for (items, 0..) |it, i| {
        if (i > 0) try w.raw(", ");
        const r = comptime resolveCol(sc, it.ref);
        try writeCol(w, r);
        if (comptime !std.mem.eql(u8, r.name, it.as)) {
            try w.raw(" AS ");
            try w.ident(it.as);
        }
    }
}

/// Copies the fields two builder types share.
fn retype(comptime To: type, from: anytype) To {
    var out: To = undefined;
    inline for (@typeInfo(To).@"struct".field_names) |f| {
        // Fields that changed type are set by the caller.
        if (@hasField(@TypeOf(from), f) and @FieldType(@TypeOf(from), f) == @FieldType(To, f)) @field(out, f) = @field(from, f);
    }
    return out;
}

pub fn Select(comptime S: type, comptime spec: SelectSpec, comptime W: type, comptime J: type) type {
    return struct {
        conn: Conn,
        wheres: W,
        ons: J,
        lim: ?u64 = null,
        off: ?u64 = null,

        const Self = @This();
        const scope: Scope = .{ .S = S, .from = spec.from, .qualify = spec.joins.len > 0 };
        const items = spec.items orelse allItems(S, spec.from);
        pub const Row = if (spec.items == null) S.Table(@field(S.Tag, spec.from)).Row else RowOf(scope, items, spec);

        fn with(self: Self, comptime spec2: SelectSpec) Select(S, spec2, W, J) {
            return retype(Select(S, spec2, W, J), self);
        }

        pub fn select(self: Self, comptime cols: anytype) Select(S, withField(spec, "items", @as(?[]const Item, parseItems(cols))), W, J) {
            return self.with(withField(spec, "items", @as(?[]const Item, parseItems(cols))));
        }

        pub fn selectAll(self: Self) Self {
            return self;
        }

        pub fn distinct(self: Self) Select(S, withField(spec, "distinct", true), W, J) {
            return self.with(withField(spec, "distinct", true));
        }

        pub fn where(self: Self, comptime col: anytype, comptime op: Op, value: anytype) Select(S, spec, Chain(W, @TypeOf(opExpr(col, op, value))), J) {
            var out = retype(Select(S, spec, Chain(W, @TypeOf(opExpr(col, op, value))), J), self);
            out.wheres = .{ .prev = self.wheres, .last = opExpr(col, op, value) };
            return out;
        }

        /// kick/db's `.where(expr)`: `db.all(…)`, `db.eq(…)`, `db.exists(…)`.
        pub fn whereExpr(self: Self, e: anytype) Select(S, spec, Chain(W, @TypeOf(e)), J) {
            var out = retype(Select(S, spec, Chain(W, @TypeOf(e)), J), self);
            out.wheres = .{ .prev = self.wheres, .last = e };
            return out;
        }

        pub fn innerJoin(self: Self, comptime t: S.Tag, on: anytype) Select(S, withField(spec, "joins", spec.joins ++ [_]Join{.{ .tag = @tagName(t), .left = false }}), W, Chain(J, @TypeOf(on))) {
            return self.join(withField(spec, "joins", spec.joins ++ [_]Join{.{ .tag = @tagName(t), .left = false }}), on);
        }

        /// The joined table's columns read as optionals.
        pub fn leftJoin(self: Self, comptime t: S.Tag, on: anytype) Select(S, withField(spec, "joins", spec.joins ++ [_]Join{.{ .tag = @tagName(t), .left = true }}), W, Chain(J, @TypeOf(on))) {
            return self.join(withField(spec, "joins", spec.joins ++ [_]Join{.{ .tag = @tagName(t), .left = true }}), on);
        }

        fn join(self: Self, comptime spec2: SelectSpec, on: anytype) Select(S, spec2, W, Chain(J, @TypeOf(on))) {
            var out = retype(Select(S, spec2, W, Chain(J, @TypeOf(on))), self);
            out.ons = .{ .prev = self.ons, .last = on };
            return out;
        }

        pub fn orderBy(self: Self, comptime col: anytype, comptime dir: enum { asc, desc }) Select(S, withField(spec, "order", spec.order ++ [_]Order{.{ .ref = @tagName(col), .desc = dir == .desc }}), W, J) {
            return self.with(withField(spec, "order", spec.order ++ [_]Order{.{ .ref = @tagName(col), .desc = dir == .desc }}));
        }

        pub fn groupBy(self: Self, comptime cols: anytype) Select(S, withField(spec, "group", groupRefs(cols)), W, J) {
            return self.with(withField(spec, "group", groupRefs(cols)));
        }

        pub fn limit(self: Self, n: u64) Self {
            var out = self;
            out.lim = n;
            return out;
        }

        pub fn offset(self: Self, n: u64) Self {
            var out = self;
            out.off = n;
            return out;
        }

        pub fn execute(self: Self, a: Allocator) !Result(Row) {
            return execute_(self, a);
        }

        pub fn executeTakeFirst(self: Self, a: Allocator) !?Row {
            return takeFirst(self, a);
        }

        pub fn executeTakeFirstOrThrow(self: Self, a: Allocator) !Row {
            return takeFirstOrThrow(self, a);
        }

        pub fn toSql(self: Self, a: Allocator) !Sql {
            var w: Writer = .{ .a = a, .dialect = S.dialect };
            try self.renderInto(&w);
            return w.done();
        }

        /// `count(*)` of the rows this query matches (its columns, order and
        /// limit left out).
        pub fn count(self: Self, a: Allocator) !i64 {
            var w: Writer = .{ .a = a, .dialect = S.dialect };
            if (spec.distinct or spec.group.len > 0) {
                // Distinct rows or groups: count the query's own rows.
                var inner = self;
                inner.lim = null;
                inner.off = null;
                try w.raw("SELECT count(*) AS \"count\" FROM (");
                try inner.renderInto(&w);
                try w.raw(") AS \"q\"");
            } else {
                try w.raw("SELECT count(*) AS \"count\" FROM ");
                try w.ident(S.info(@field(S.Tag, spec.from)).name);
                try renderJoins(self.ons, &w);
                try renderWheres(self.wheres, scope, &w);
            }
            const rows = try runRows(self.conn, a, struct { count: i64 }, w.done());
            return rows[0].count;
        }

        pub fn renderInto(self: Self, w: *Writer) !void {
            try w.raw(if (spec.distinct) "SELECT DISTINCT " else "SELECT ");
            try renderItems(scope, items, w);
            try w.raw(" FROM ");
            try w.ident(S.info(@field(S.Tag, spec.from)).name);
            try renderJoins(self.ons, w);
            try renderWheres(self.wheres, scope, w);
            inline for (spec.group, 0..) |g, i| {
                try w.raw(if (i == 0) " GROUP BY " else ", ");
                try writeCol(w, comptime resolveCol(scope, g));
            }
            inline for (spec.order, 0..) |o, i| {
                try w.raw(if (i == 0) " ORDER BY " else ", ");
                try writeCol(w, comptime resolveCol(scope, o.ref));
                try w.raw(if (o.desc) " DESC" else " ASC");
            }
            if (self.lim) |n| {
                try w.raw(" LIMIT ");
                try w.param(n);
            }
            if (self.off) |n| {
                try w.raw(" OFFSET ");
                try w.param(n);
            }
        }

        fn renderJoins(chain: anytype, w: *Writer) !void {
            const C = @TypeOf(chain);
            if (C == void) return;
            try renderJoins(chain.prev, w);
            const j = spec.joins[C.len - 1];
            try w.raw(if (j.left) " LEFT JOIN " else " INNER JOIN ");
            try w.ident(S.info(@field(S.Tag, j.tag)).name);
            try w.raw(" ON ");
            try chain.last.render(scope, w);
        }
    };
}

fn withField(comptime spec: SelectSpec, comptime field: []const u8, comptime value: anytype) SelectSpec {
    var out = spec;
    @field(out, field) = value;
    return out;
}

fn groupRefs(comptime cols: anytype) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (@typeInfo(@TypeOf(cols)).@"struct".field_names) |f| out = out ++ [_][]const u8{@tagName(@field(cols, f))};
        return out;
    }
}

fn returningClause(comptime sc: Scope, comptime ret: ?[]const Item, w: *Writer) !void {
    if (ret) |r| {
        try w.raw(" RETURNING ");
        try renderItems(sc, r, w);
    }
}

pub fn Insert(comptime S: type, comptime tag: []const u8, comptime ret: ?[]const Item, comptime conflict: ?Conflict) type {
    return struct {
        conn: Conn,
        one: ?T.Insert = null,
        many: []const T.Insert = &.{},

        const Self = @This();
        const T = S.Table(@field(S.Tag, tag));
        const scope: Scope = .{ .S = S, .from = tag, .qualify = false };
        pub const Row = if (ret) |r| RowOf(scope, r, null) else void;

        pub fn values(self: Self, row: T.Insert) Self {
            var out = self;
            out.one = row;
            return out;
        }

        pub fn valuesMany(self: Self, rows: []const T.Insert) Self {
            var out = self;
            out.many = rows;
            return out;
        }

        /// `ON CONFLICT (target) DO UPDATE SET … = EXCLUDED.…` (`.all`: every
        /// given column outside the target; or the named ones), or `DO NOTHING` (`.none`).
        pub fn onConflict(self: Self, comptime target: anytype, comptime update: anytype) Insert(S, tag, ret, conflictOf(scope, target, update)) {
            return retype(Insert(S, tag, ret, conflictOf(scope, target, update)), self);
        }

        pub fn returning(self: Self, comptime cols: anytype) Insert(S, tag, parseItems(cols), conflict) {
            return retype(Insert(S, tag, parseItems(cols), conflict), self);
        }

        pub fn returningAll(self: Self) Insert(S, tag, allItems(S, tag), conflict) {
            return retype(Insert(S, tag, allItems(S, tag), conflict), self);
        }

        pub fn execute(self: Self, a: Allocator) !Result(Row) {
            return execute_(self, a);
        }

        pub fn executeTakeFirst(self: Self, a: Allocator) !?Row {
            return takeFirst(self, a);
        }

        pub fn executeTakeFirstOrThrow(self: Self, a: Allocator) !Row {
            return takeFirstOrThrow(self, a);
        }

        pub fn toSql(self: Self, a: Allocator) !Sql {
            const rows: []const T.Insert = if (self.one) |*r| r[0..1] else self.many;
            if (rows.len == 0) return error.NothingToInsert;
            const info = S.info(@field(S.Tag, tag));
            const keys = T.column_keys;
            // A column is listed when any row gives it; rows without it get DEFAULT.
            var given: [keys.len]bool = @splat(false);
            for (rows) |row| inline for (keys, 0..) |k, i| {
                if (comptime @typeInfo(@FieldType(T.Insert, k)) != .optional) given[i] = true else if (@field(row, k) != null) given[i] = true;
            };
            var w: Writer = .{ .a = a, .dialect = S.dialect };
            try w.raw("INSERT INTO ");
            try w.ident(info.name);
            if (std.mem.findScalar(bool, &given, true) == null) {
                if (rows.len > 1) return error.NothingToInsert;
                try w.raw(" DEFAULT VALUES");
            } else {
                try w.raw(" (");
                var first = true;
                inline for (keys, 0..) |_, i| if (given[i]) {
                    if (!first) try w.raw(", ");
                    first = false;
                    try w.ident(info.columns[i].name);
                };
                try w.raw(") VALUES ");
                for (rows, 0..) |row, ri| {
                    try w.raw(if (ri == 0) "(" else ", (");
                    first = true;
                    inline for (keys, 0..) |k, i| if (given[i]) {
                        if (!first) try w.raw(", ");
                        first = false;
                        const v = @field(row, k);
                        if (comptime @typeInfo(@TypeOf(v)) == .optional) {
                            if (v) |x| try w.param(x) else if (S.dialect == .sqlite) {
                                // No DEFAULT in SQLite's VALUES: the default itself.
                                const col = info.columns[i];
                                if (col.default) |d| {
                                    var out: std.Io.Writer.Allocating = .init(w.a);
                                    try emit_sqlite.formatDefault(&out.writer, d, col.sql_type, col.default_sql);
                                    try w.raw(out.written());
                                } else try w.raw("NULL");
                            } else try w.raw("DEFAULT");
                        } else try w.param(v);
                    };
                    try w.raw(")");
                }
            }
            if (conflict) |cf| {
                try w.raw(" ON CONFLICT (");
                inline for (cf.target, 0..) |k, i| {
                    if (i > 0) try w.raw(", ");
                    try w.ident(comptime resolveCol(scope, k).name);
                }
                try w.raw(")");
                var first = true;
                inline for (keys, 0..) |k, i| {
                    const named = comptime switch (cf.update) {
                        .all => !contains(cf.target, k),
                        .none => false,
                        .cols => |cols| contains(cols, k),
                    };
                    if (named and (given[i] or cf.update == .cols)) {
                        try w.raw(if (first) " DO UPDATE SET " else ", ");
                        first = false;
                        try w.ident(info.columns[i].name);
                        try w.raw(" = EXCLUDED.");
                        try w.ident(info.columns[i].name);
                    }
                }
                if (first) try w.raw(" DO NOTHING");
            }
            try returningClause(scope, ret, &w);
            return w.done();
        }
    };
}

pub fn Update(comptime S: type, comptime tag: []const u8, comptime W: type, comptime ret: ?[]const Item) type {
    return struct {
        conn: Conn,
        wheres: W,
        sets: T.Update = .{},

        const Self = @This();
        const T = S.Table(@field(S.Tag, tag));
        const scope: Scope = .{ .S = S, .from = tag, .qualify = false };
        pub const Row = if (ret) |r| RowOf(scope, r, null) else void;

        pub fn set(self: Self, values: T.Update) Self {
            var out = self;
            out.sets = values;
            return out;
        }

        pub fn where(self: Self, comptime col: anytype, comptime op: Op, value: anytype) Update(S, tag, Chain(W, @TypeOf(opExpr(col, op, value))), ret) {
            var out = retype(Update(S, tag, Chain(W, @TypeOf(opExpr(col, op, value))), ret), self);
            out.wheres = .{ .prev = self.wheres, .last = opExpr(col, op, value) };
            return out;
        }

        pub fn whereExpr(self: Self, e: anytype) Update(S, tag, Chain(W, @TypeOf(e)), ret) {
            var out = retype(Update(S, tag, Chain(W, @TypeOf(e)), ret), self);
            out.wheres = .{ .prev = self.wheres, .last = e };
            return out;
        }

        pub fn returning(self: Self, comptime cols: anytype) Update(S, tag, W, parseItems(cols)) {
            return retype(Update(S, tag, W, parseItems(cols)), self);
        }

        pub fn returningAll(self: Self) Update(S, tag, W, allItems(S, tag)) {
            return retype(Update(S, tag, W, allItems(S, tag)), self);
        }

        pub fn execute(self: Self, a: Allocator) !Result(Row) {
            return execute_(self, a);
        }

        pub fn executeTakeFirst(self: Self, a: Allocator) !?Row {
            return takeFirst(self, a);
        }

        pub fn executeTakeFirstOrThrow(self: Self, a: Allocator) !Row {
            return takeFirstOrThrow(self, a);
        }

        pub fn toSql(self: Self, a: Allocator) !Sql {
            const info = S.info(@field(S.Tag, tag));
            var w: Writer = .{ .a = a, .dialect = S.dialect };
            try w.raw("UPDATE ");
            try w.ident(info.name);
            try w.raw(" SET ");
            var first = true;
            inline for (T.column_keys, 0..) |k, i| if (@field(self.sets, k)) |v| {
                if (!first) try w.raw(", ");
                first = false;
                try w.ident(info.columns[i].name);
                try w.raw(" = ");
                try w.param(v);
            };
            if (first) return error.NothingToSet;
            try renderWheres(self.wheres, scope, &w);
            try returningClause(scope, ret, &w);
            return w.done();
        }
    };
}

pub fn Delete(comptime S: type, comptime tag: []const u8, comptime W: type, comptime ret: ?[]const Item) type {
    return struct {
        conn: Conn,
        wheres: W,

        const Self = @This();
        const scope: Scope = .{ .S = S, .from = tag, .qualify = false };
        pub const Row = if (ret) |r| RowOf(scope, r, null) else void;

        pub fn where(self: Self, comptime col: anytype, comptime op: Op, value: anytype) Delete(S, tag, Chain(W, @TypeOf(opExpr(col, op, value))), ret) {
            var out = retype(Delete(S, tag, Chain(W, @TypeOf(opExpr(col, op, value))), ret), self);
            out.wheres = .{ .prev = self.wheres, .last = opExpr(col, op, value) };
            return out;
        }

        pub fn whereExpr(self: Self, e: anytype) Delete(S, tag, Chain(W, @TypeOf(e)), ret) {
            var out = retype(Delete(S, tag, Chain(W, @TypeOf(e)), ret), self);
            out.wheres = .{ .prev = self.wheres, .last = e };
            return out;
        }

        pub fn returning(self: Self, comptime cols: anytype) Delete(S, tag, W, parseItems(cols)) {
            return retype(Delete(S, tag, W, parseItems(cols)), self);
        }

        pub fn returningAll(self: Self) Delete(S, tag, W, allItems(S, tag)) {
            return retype(Delete(S, tag, W, allItems(S, tag)), self);
        }

        pub fn execute(self: Self, a: Allocator) !Result(Row) {
            return execute_(self, a);
        }

        pub fn executeTakeFirst(self: Self, a: Allocator) !?Row {
            return takeFirst(self, a);
        }

        pub fn executeTakeFirstOrThrow(self: Self, a: Allocator) !Row {
            return takeFirstOrThrow(self, a);
        }

        pub fn toSql(self: Self, a: Allocator) !Sql {
            var w: Writer = .{ .a = a, .dialect = S.dialect };
            try w.raw("DELETE FROM ");
            try w.ident(S.info(@field(S.Tag, tag)).name);
            try renderWheres(self.wheres, scope, &w);
            try returningClause(scope, ret, &w);
            return w.done();
        }
    };
}

const testing = std.testing;

const Role = enum {
    admin,
    member,
    pub const pg_name = "role";
};
const teams = schema.table("teams", .{
    .id = .{ .type = .serial, .primary_key = true },
    .title = .{ .type = .text, .not_null = true },
}, .{});
const people = schema.table("people", .{
    .id = .{ .type = .serial, .primary_key = true },
    .name = .{ .type = .text, .not_null = true },
    .email = .{ .type = .{ .varchar = 255 }, .unique = true },
    .role = .{ .type = .{ .@"enum" = Role }, .not_null = true, .default = .{ .value = "member" } },
    .age = .{ .type = .smallint },
    .joined = .{ .type = .timestamp, .not_null = true, .default = .now },
    .teamId = .{ .type = .integer, .references = .{ .to = "teams.id" } },
}, .{});
const TestSchema = schema.Schema(.{ .teams = teams, .people = people }, .{});
const Snake = schema.Schema(.{ .teams = teams, .people = people }, .{ .casing = .snake_case });
const Lite = schema.Schema(.{ .teams = teams, .people = people }, .{ .dialect = .sqlite });

fn expectSql(q: anytype, text: []const u8, params: []const ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try q.toSql(arena.allocator());
    try testing.expectEqualStrings(text, got.sql);
    try testing.expectEqual(params.len, got.params.len);
    for (params, got.params) |want, have| {
        if (want) |w| try testing.expectEqualStrings(w, have.value.?) else try testing.expectEqual(null, have.value);
    }
}

const c: Client(TestSchema) = .{ .conn = undefined };

test "select: columns, conditions, order, limit and offset" {
    try expectSql(c.selectFrom(.teams), "SELECT \"id\", \"title\" FROM \"teams\"", &.{});
    try expectSql(
        c.selectFrom(.people).select(.{ .id, .name }).where(.role, .eq, .admin).where(.age, .gte, 18)
            .orderBy(.joined, .desc).orderBy(.id, .asc).limit(20).offset(40),
        "SELECT \"id\", \"name\" FROM \"people\" WHERE \"role\" = $1 AND \"age\" >= $2 ORDER BY \"joined\" DESC, \"id\" ASC LIMIT $3 OFFSET $4",
        &.{ "admin", "18", "20", "40" },
    );
    const Row = @TypeOf(c.selectFrom(.people).select(.{ .id, .email })).Row;
    try testing.expect(@FieldType(Row, "id") == i32);
    try testing.expect(@FieldType(Row, "email") == ?[]const u8);
}

test "conditions: all, any, not, in, between, like, null; kick/db's empty rules" {
    const ts: Timestamp = .{ .us = 0 };
    try expectSql(
        c.selectFrom(.teams).select(.{.id}).whereExpr(all(.{ eq(.title, "x"), any(.{ isNull(.id), gt(.id, 3) }) })),
        "SELECT \"id\" FROM \"teams\" WHERE (\"title\" = $1 AND (\"id\" IS NULL OR \"id\" > $2))",
        &.{ "x", "3" },
    );
    try expectSql(c.selectFrom(.people).select(.{.id}).whereExpr(not(lt(.joined, ts))), "SELECT \"id\" FROM \"people\" WHERE NOT (\"joined\" < $1)", &.{"1970-01-01T00:00:00Z"});
    const ids = [_]i32{ 1, 2 };
    try expectSql(c.selectFrom(.teams).select(.{.id}).whereExpr(inArray(.id, &ids)), "SELECT \"id\" FROM \"teams\" WHERE \"id\" IN ($1, $2)", &.{ "1", "2" });
    try expectSql(c.selectFrom(.teams).select(.{.id}).whereExpr(inArray(.id, &[_]i32{})), "SELECT \"id\" FROM \"teams\" WHERE false", &.{});
    try expectSql(c.selectFrom(.teams).select(.{.id}).whereExpr(notInArray(.id, &[_]i32{})), "SELECT \"id\" FROM \"teams\" WHERE true", &.{});
    try expectSql(c.selectFrom(.teams).select(.{.id}).whereExpr(all(.{})), "SELECT \"id\" FROM \"teams\" WHERE true", &.{});
    try expectSql(c.selectFrom(.teams).select(.{.id}).whereExpr(any(.{})), "SELECT \"id\" FROM \"teams\" WHERE false", &.{});
    try expectSql(c.selectFrom(.teams).select(.{.id}).whereExpr(all(.{ null, eq(.title, "x") })), "SELECT \"id\" FROM \"teams\" WHERE (\"title\" = $1)", &.{"x"});
    try expectSql(c.selectFrom(.people).select(.{.id}).whereExpr(between(.age, 18, 65)), "SELECT \"id\" FROM \"people\" WHERE \"age\" BETWEEN $1 AND $2", &.{ "18", "65" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectSql(c.selectFrom(.people).select(.{.id}).whereExpr(like(.name, try escapeLike(arena.allocator(), "50%_off\\"))), "SELECT \"id\" FROM \"people\" WHERE \"name\" LIKE $1", &.{"50\\%\\_off\\\\"});
    try expectSql(c.selectFrom(.people).select(.{.id}).where(.email, .is_not_null, {}), "SELECT \"id\" FROM \"people\" WHERE \"email\" IS NOT NULL", &.{});
    try expectSql(c.selectFrom(.people).select(.{.id}).whereExpr(sql("1=1 OR 2=2")).where(.id, .eq, 1), "SELECT \"id\" FROM \"people\" WHERE (1=1 OR 2=2) AND \"id\" = $1", &.{"1"});
}

test "joins: qualified columns, aliases, left-joined columns are optional, exists" {
    const q = c.selectFrom(.people).innerJoin(.teams, eq(.@"teams.id", .@"people.teamId"))
        .select(.{ .@"people.name", "teams.title as teamTitle" }).where(.@"teams.title", .eq, "core");
    try expectSql(q, "SELECT \"people\".\"name\", \"teams\".\"title\" AS \"teamTitle\" FROM \"people\" INNER JOIN \"teams\" ON \"teams\".\"id\" = \"people\".\"teamId\" WHERE \"teams\".\"title\" = $1", &.{"core"});
    try testing.expect(@FieldType(@TypeOf(q).Row, "teamTitle") == []const u8);
    const l = c.selectFrom(.people).leftJoin(.teams, eq(.@"teams.id", .@"people.teamId")).select(.{ .name, "teams.title as teamTitle" });
    try expectSql(l, "SELECT \"people\".\"name\", \"teams\".\"title\" AS \"teamTitle\" FROM \"people\" LEFT JOIN \"teams\" ON \"teams\".\"id\" = \"people\".\"teamId\"", &.{});
    try testing.expect(@FieldType(@TypeOf(l).Row, "teamTitle") == ?[]const u8);
    try expectSql(
        c.selectFrom(.teams).select(.{.id}).whereExpr(exists(c.selectFrom(.people).select(.{.id}).whereExpr(all(.{ eq(.@"people.teamId", .@"teams.id"), eq(.role, .admin) })))),
        "SELECT \"id\" FROM \"teams\" WHERE EXISTS (SELECT \"id\" FROM \"people\" WHERE (\"people\".\"teamId\" = \"teams\".\"id\" AND \"role\" = $1))",
        &.{"admin"},
    );
}

test "insert: given columns only, DEFAULT cells across rows, returning" {
    try expectSql(c.insertInto(.people).values(.{ .name = "Ada" }).returning(.{.id}), "INSERT INTO \"people\" (\"name\") VALUES ($1) RETURNING \"id\"", &.{"Ada"});
    try expectSql(c.insertInto(.people).values(.{ .name = "O'Brien; DROP TABLE x --", .role = .admin, .age = null }), "INSERT INTO \"people\" (\"name\", \"role\") VALUES ($1, $2)", &.{ "O'Brien; DROP TABLE x --", "admin" });
    try expectSql(
        c.insertInto(.people).valuesMany(&.{ .{ .name = "A" }, .{ .name = "B", .age = 3 } }).returningAll(),
        "INSERT INTO \"people\" (\"name\", \"age\") VALUES ($1, DEFAULT), ($2, $3) RETURNING \"id\", \"name\", \"email\", \"role\", \"age\", \"joined\", \"teamId\"",
        &.{ "A", "B", "3" },
    );
    try expectSql(c.insertInto(.teams).valuesMany(&.{ .{ .title = "t" }, .{ .title = "u" } }), "INSERT INTO \"teams\" (\"title\") VALUES ($1), ($2)", &.{ "t", "u" });
}

test "update and delete" {
    try expectSql(
        c.updateTable(.people).set(.{ .name = "B", .email = @as(?[]const u8, null) }).where(.id, .eq, 1).returning(.{.id}),
        "UPDATE \"people\" SET \"name\" = $1, \"email\" = $2 WHERE \"id\" = $3 RETURNING \"id\"",
        &.{ "B", null, "1" },
    );
    try expectSql(c.deleteFrom(.people).where(.id, .eq, 7).returning(.{.name}), "DELETE FROM \"people\" WHERE \"id\" = $1 RETURNING \"name\"", &.{"7"});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NothingToSet, c.updateTable(.people).set(.{}).toSql(arena.allocator()));
}

test "snake_case: database names in SQL, keys in rows" {
    const sc: Client(Snake) = .{ .conn = undefined };
    try expectSql(sc.selectFrom(.people).select(.{ .id, .teamId }).where(.teamId, .eq, 2), "SELECT \"id\", \"team_id\" AS \"teamId\" FROM \"people\" WHERE \"team_id\" = $1", &.{"2"});
    try expectSql(sc.insertInto(.people).values(.{ .name = "A", .teamId = 1 }), "INSERT INTO \"people\" (\"name\", \"team_id\") VALUES ($1, $2)", &.{ "A", "1" });
}

test "sqlite: ?n placeholders, LIKE for ilike, 1/0 booleans, a missing cell takes the column's default" {
    const lc: Client(Lite) = .{ .conn = undefined };
    try expectSql(
        lc.selectFrom(.people).select(.{ .id, .name }).where(.role, .eq, .admin).where(.age, .gte, 18)
            .orderBy(.joined, .desc).limit(20).offset(40),
        "SELECT \"id\", \"name\" FROM \"people\" WHERE \"role\" = ?1 AND \"age\" >= ?2 ORDER BY \"joined\" DESC LIMIT ?3 OFFSET ?4",
        &.{ "admin", "18", "20", "40" },
    );
    // SQLite has no ILIKE; its LIKE ignores ASCII case.
    try expectSql(lc.selectFrom(.people).select(.{.id}).whereExpr(ilike(.name, "ad%")), "SELECT \"id\" FROM \"people\" WHERE \"name\" LIKE ?1", &.{"ad%"});
    try expectSql(lc.selectFrom(.people).select(.{.id}).where(.name, .ilike, "ad%"), "SELECT \"id\" FROM \"people\" WHERE \"name\" LIKE ?1", &.{"ad%"});
    try expectSql(lc.selectFrom(.people).select(.{.id}).whereExpr(not(lt(.joined, Timestamp{ .us = 1_500 }))), "SELECT \"id\" FROM \"people\" WHERE NOT (\"joined\" < ?1)", &.{"1970-01-01 00:00:00.001"});
    // No DEFAULT keyword in SQLite's VALUES: the column's default, or NULL.
    try expectSql(
        lc.insertInto(.people).valuesMany(&.{ .{ .name = "A", .role = .admin }, .{ .name = "B", .age = 3, .joined = Timestamp{ .us = 0 } } }),
        "INSERT INTO \"people\" (\"name\", \"role\", \"age\", \"joined\") VALUES (?1, ?2, NULL, (strftime('%Y-%m-%d %H:%M:%f', 'now'))), (?3, 'member', ?4, ?5)",
        &.{ "A", "admin", "B", "3", "1970-01-01 00:00:00.000" },
    );
}

test "sqlite: the builder against a Postgres pool, or the reverse, is refused" {
    var pool: dbm.Pool = .{ .io = testing.io, .gpa = testing.allocator, .driver = .{ .pg = undefined }, .arena = .init(testing.allocator), .permits = .{ .permits = 0 } };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const db: Client(Lite) = .init(.{ .pool = &pool });
    try testing.expectError(error.DialectMismatch, db.selectFrom(.teams).execute(arena.allocator()));
}

test "insertMany: rows split to fit max_params, in one transaction" {
    if (!@import("kzig_options").sqlite) return error.SkipZigTest;
    var pool: dbm.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    try setupLite(&pool);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db: Client(Lite) = .init(.{ .pool = &pool });
    const TeamInsert = Lite.Table(.teams).Insert;
    var rows: [250]TeamInsert = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .title = try std.fmt.allocPrint(a, "t{d}", .{i}) };
    try testing.expectEqual(250, try db.insertMany(a, .teams, &rows, .{ .max_params = 100 }));
    try testing.expectEqual(250, try db.selectFrom(.teams).count(a));
    // A failure in the last statement takes the first ones with it.
    var more: [150]TeamInsert = undefined;
    for (&more, 0..) |*r, i| r.* = .{ .title = try std.fmt.allocPrint(a, "u{d}", .{i}) };
    more[149] = .{ .title = "t0" }; // taken
    try testing.expectError(error.Conflict, db.insertMany(a, .teams, &more, .{ .max_params = 100 }));
    try testing.expectEqual(250, try db.selectFrom(.teams).count(a));
    const back = try db.insertManyReturning(a, .teams, more[0..120], .{ .max_params = 50 });
    try testing.expectEqual(120, back.len);
    try testing.expectEqualStrings("u119", back[119].title);
    try testing.expectError(error.MaxParamsTooSmall, db.insertMany(a, .people, &.{.{ .name = "a", .age = 1 }}, .{ .max_params = 1 }));
}

fn setupLite(pool: *dbm.Pool) !void {
    try pool.execScript(
        \\CREATE TABLE teams (id integer PRIMARY KEY, title text NOT NULL UNIQUE);
        \\CREATE TABLE people (id integer PRIMARY KEY, name text NOT NULL, email text UNIQUE,
        \\  role text NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')), age integer,
        \\  joined text NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now')),
        \\  "teamId" integer REFERENCES teams(id));
    );
}

test "runs on SQLite: insert, select, join, update, delete; upsert and findOrCreate" {
    if (!@import("kzig_options").sqlite) return error.SkipZigTest;
    {
        var pool: dbm.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
        defer pool.deinit();
        try setupLite(&pool);
        try insertSelectSuite(Lite, &pool);
    }
    var pool: dbm.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    try setupLite(&pool);
    try upsertSuite(Lite, &pool);
}

test "runs on libsql (LIBSQL_TEST_URL): insert, select, join, update, delete; upsert and findOrCreate" {
    var env: std.process.Environ.Map = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const url = env.get("LIBSQL_TEST_URL") orelse return error.SkipZigTest;
    var pool: dbm.Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 4 });
    defer pool.deinit();
    const drop = "DROP TABLE IF EXISTS people; DROP TABLE IF EXISTS teams;";
    try pool.execScript(drop);
    try setupLite(&pool);
    try insertSelectSuite(Lite, &pool);
    try pool.execScript(drop);
    try setupLite(&pool);
    defer pool.execScript(drop) catch {};
    try upsertSuite(Lite, &pool);
}

fn setupPeople(pool: *dbm.Pool) !void {
    try pool.execScript(
        \\DROP TABLE IF EXISTS people, teams; DROP TYPE IF EXISTS role;
        \\CREATE TYPE role AS ENUM ('admin', 'member');
        \\CREATE TABLE teams (id serial PRIMARY KEY, title text NOT NULL UNIQUE);
        \\CREATE TABLE people (id serial PRIMARY KEY, name text NOT NULL, email varchar(255) UNIQUE,
        \\  role role NOT NULL DEFAULT 'member', age smallint, joined timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  "teamId" integer REFERENCES teams(id));
    );
}

fn dropPeople(pool: *dbm.Pool) void {
    pool.execScript("DROP TABLE IF EXISTS people, teams; DROP TYPE IF EXISTS role;") catch {};
}

test "runs on Postgres: insert, select, join, update, delete" {
    var env: std.process.Environ.Map = undefined;
    const url = dbm.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: dbm.Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 2 });
    defer pool.deinit();
    try setupPeople(&pool);
    defer dropPeople(&pool);
    try insertSelectSuite(TestSchema, &pool);
}

fn insertSelectSuite(comptime S: type, pool: *dbm.Pool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db: Client(S) = .init(.{ .pool = pool });

    const team = try db.insertInto(.teams).values(.{ .title = "core" }).returningAll().executeTakeFirstOrThrow(a);
    const tricky = "O'Brien; DROP TABLE teams --";
    const ada = try db.insertInto(.people).values(.{ .name = tricky, .role = .admin, .teamId = team.id }).returningAll().executeTakeFirstOrThrow(a);
    try testing.expectEqualStrings(tricky, ada.name);
    try testing.expectEqual(Role.admin, ada.role);
    try testing.expectEqual(null, ada.email);
    try testing.expect(ada.joined.us > 0);
    try testing.expectEqual(2, try db.insertInto(.people).valuesMany(&.{ .{ .name = "B", .age = 30 }, .{ .name = "C" } }).execute(a));

    const admins = try db.selectFrom(.people).where(.role, .eq, .admin).execute(a);
    try testing.expectEqual(1, admins.len);
    const joined = try db.selectFrom(.people).leftJoin(.teams, eq(.@"teams.id", .@"people.teamId"))
        .select(.{ .name, "teams.title as teamTitle" }).orderBy(.@"people.id", .asc).execute(a);
    try testing.expectEqual(3, joined.len);
    try testing.expectEqualStrings("core", joined[0].teamTitle.?);
    try testing.expectEqual(null, joined[1].teamTitle);
    try testing.expectEqual(null, try db.selectFrom(.people).where(.name, .eq, "nobody").executeTakeFirst(a));
    try testing.expectError(error.NotFound, db.selectFrom(.people).where(.name, .eq, "nobody").executeTakeFirstOrThrow(a));
    try testing.expectEqual(2, try db.selectFrom(.people).where(.role, .eq, .member).count(a));
    try testing.expectEqual(2, try db.selectFrom(.people).select(.{.role}).distinct().count(a));
    try testing.expectEqual(2, try db.selectFrom(.people).select(.{.role}).groupBy(.{.role}).count(a));

    const renamed = try db.updateTable(.people).set(.{ .name = "Ada", .email = @as(?[]const u8, "ada@example.com") }).where(.id, .eq, ada.id).returning(.{ .name, .email }).executeTakeFirstOrThrow(a);
    try testing.expectEqualStrings("Ada", renamed.name);
    try testing.expectEqualStrings("ada@example.com", renamed.email.?);
    try testing.expectError(error.Conflict, db.insertInto(.people).values(.{ .name = "X", .email = "ada@example.com" }).execute(a));
    try testing.expectEqual(1, try db.deleteFrom(.people).where(.name, .eq, "C").execute(a));

    // A NULL into a non-optional field is a decode error, not a crash.
    const q = try db.selectFrom(.people).leftJoin(.teams, eq(.@"teams.id", .@"people.teamId"))
        .select(.{ .name, "teams.title as teamTitle" }).where(.@"people.name", .eq, "B").toSql(a);
    try testing.expectError(error.DbDecode, pool.queryParams(a, struct { teamTitle: []const u8 }, q.sql, q.params));
}

test "upsert and findOrCreate" {
    var env: std.process.Environ.Map = undefined;
    const url = dbm.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: dbm.Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 4 });
    defer pool.deinit();
    try setupPeople(&pool);
    defer dropPeople(&pool);
    try upsertSuite(TestSchema, &pool);
}

fn upsertSuite(comptime S: type, pool: *dbm.Pool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db: Client(S) = .init(.{ .pool = pool });

    const first = try db.upsert(a, .people, .{ .name = "A", .email = "a@x" }, .{ .target = .{.email} });
    const second = try db.upsert(a, .people, .{ .name = "A2", .email = "a@x", .age = 5 }, .{ .target = .{.email} });
    try testing.expectEqual(first.id, second.id);
    try testing.expectEqualStrings("A2", second.name);
    try testing.expectEqual(5, second.age.?);
    // update = .none: the stored row comes back as it was.
    const kept = try db.upsert(a, .people, .{ .name = "ignored", .email = "a@x" }, .{ .target = .{.email}, .update = .none });
    try testing.expectEqualStrings("A2", kept.name);
    // Only the named columns take the incoming value.
    const named = try db.upsert(a, .people, .{ .name = "A3", .email = "a@x", .age = 9 }, .{ .target = .{.email}, .update = .{.age} });
    try testing.expectEqualStrings("A2", named.name);
    try testing.expectEqual(9, named.age.?);

    // `create` wins over `where` for the new row, as kick/db spreads them.
    const odd = try db.findOrCreate(a, .people, .{ .name = "W" }, .{ .name = "C" });
    try testing.expectEqualStrings("C", odd.row.name);

    const made = try db.findOrCreate(a, .teams, .{ .title = "core" }, .{});
    try testing.expect(made.created);
    const found = try db.findOrCreate(a, .teams, .{ .title = "core" }, .{});
    try testing.expect(!found.created);
    try testing.expectEqual(made.row.id, found.row.id);

    // Racing creators: one creates, every one gets the same row.
    const Race = struct {
        fn run(d: Client(S), created: *std.atomic.Value(u32), failed: *std.atomic.Value(u32)) void {
            var ar: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ar.deinit();
            const r = d.findOrCreate(ar.allocator(), .teams, .{ .title = "race" }, .{}) catch {
                _ = failed.fetchAdd(1, .acq_rel);
                return;
            };
            if (r.created) _ = created.fetchAdd(1, .acq_rel);
        }
    };
    var created: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    for (0..4) |_| try group.concurrent(testing.io, Race.run, .{ db, &created, &failed });
    try group.await(testing.io);
    try testing.expectEqual(0, failed.load(.acquire));
    try testing.expectEqual(1, created.load(.acquire));

    // SQLite has one writer: no second transaction to race against.
    if (S.dialect == .sqlite) return;
    // Inside a transaction a lost race doesn't abort it (savepoint): another
    // transaction holds an uncommitted "taken", so our read misses, our
    // insert waits for it, and conflicts once it commits.
    var other = try pool.begin();
    defer other.deinit();
    _ = try other.exec("INSERT INTO teams (title) VALUES ('taken')", .{});
    const Commit = struct {
        fn run(t: *dbm.Tx) void {
            testing.io.sleep(.fromMilliseconds(200), .awake) catch {};
            t.commit() catch {};
        }
    };
    var later = try testing.io.concurrent(Commit.run, .{&other});
    var tx = try pool.begin();
    defer tx.deinit();
    const txdb: Client(S) = .init(.{ .tx = &tx });
    const taken = try txdb.findOrCreate(a, .teams, .{ .title = "taken" }, .{});
    later.await(testing.io);
    try testing.expect(!taken.created);
    _ = try txdb.insertInto(.teams).values(.{ .title = "after" }).execute(a);
    try tx.commit();
    try testing.expectEqual(1, try db.selectFrom(.teams).where(.title, .eq, "after").count(a));
}
