//! kick/db's query builder: `selectFrom`, `insertInto`, `updateTable`,
//! `deleteFrom`, checked against a `db.Schema` at comptime. Builders are
//! values; SQL is written when a query runs, with every value a parameter.
const std = @import("std");
const schema = @import("schema.zig");
const Timestamp = @import("timestamp.zig").Timestamp;
const pg = @import("pg.zig");
const dbm = @import("db.zig");

const Allocator = std.mem.Allocator;
const EnumLiteral = @TypeOf(.enum_literal);

/// A query as written: SQL with `$n` placeholders and their values as text.
pub const Sql = struct { sql: []const u8, params: []const ?[]const u8 };

/// Where queries run: the pool, or a transaction.
pub const Conn = union(enum) { pool: *dbm.Pool, tx: *dbm.Tx };

/// kick/db's client over a schema: `selectFrom(.users)`, `insertInto`,
/// `updateTable`, `deleteFrom`.
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

        pub fn insertInto(self: Self, comptime t: S.Tag) Insert(S, @tagName(t), null) {
            return .{ .conn = self.conn };
        }

        pub fn updateTable(self: Self, comptime t: S.Tag) Update(S, @tagName(t), void, null) {
            return .{ .conn = self.conn, .wheres = {} };
        }

        pub fn deleteFrom(self: Self, comptime t: S.Tag) Delete(S, @tagName(t), void, null) {
            return .{ .conn = self.conn, .wheres = {} };
        }
    };
}

// ---- writing SQL

const Writer = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    params: std.ArrayList(?[]const u8) = .empty,

    fn raw(w: *Writer, s: []const u8) !void {
        try w.buf.appendSlice(w.a, s);
    }

    fn ident(w: *Writer, s: []const u8) !void {
        try w.buf.append(w.a, '"');
        for (s) |ch| {
            if (ch == '"') try w.buf.append(w.a, '"');
            try w.buf.append(w.a, ch);
        }
        try w.buf.append(w.a, '"');
    }

    fn param(w: *Writer, v: anytype) !void {
        try w.params.append(w.a, try pg.encodeValue(w.a, v));
        try w.buf.print(w.a, "${d}", .{w.params.items.len});
    }

    fn done(w: *Writer) Sql {
        return .{ .sql = w.buf.items, .params = w.params.items };
    }
};

/// What unqualified column names mean while rendering.
const Scope = struct { S: type, from: []const u8, qualify: bool };

const ColRef = struct {
    table: []const u8,
    key: []const u8,
    name: []const u8,
    Z: type,
    nullable: bool,
    qualified: bool,
};

fn tableTag(comptime S: type, comptime sql_name: []const u8) ?[]const u8 {
    for (@typeInfo(S.Tag).@"enum".field_names) |tag| {
        if (std.mem.eql(u8, S.info(@field(S.Tag, tag)).name, sql_name)) return tag;
    }
    return null;
}

/// `.email` (the scope's table) or `.@"tasks.id"` (any table, by SQL name).
fn resolveCol(comptime sc: Scope, comptime ref: []const u8) ColRef {
    comptime {
        const S = sc.S;
        const dot = std.mem.findScalar(u8, ref, '.');
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
        };
        @compileError(info.name ++ ": no column " ++ key);
    }
}

fn writeCol(w: *Writer, comptime r: ColRef) !void {
    if (r.qualified) {
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
            try w.raw(" " ++ op ++ " ");
            if (lit) |name| {
                // An enum's value, or another column (`.@"teams.id"`).
                if (comptime @typeInfo(l.Z) == .@"enum" and @hasField(l.Z, name)) return w.param(@as([]const u8, name));
                const r = comptime resolveCol(sc, name);
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

    pub fn render(self: Raw, comptime _: Scope, w: *Writer) !void {
        try w.raw(self.text);
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

        pub fn toSql(self: Self, a: Allocator) !Sql {
            var w: Writer = .{ .a = a };
            try self.renderInto(&w);
            return w.done();
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

pub fn Insert(comptime S: type, comptime tag: []const u8, comptime ret: ?[]const Item) type {
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

        pub fn returning(self: Self, comptime cols: anytype) Insert(S, tag, parseItems(cols)) {
            return retype(Insert(S, tag, parseItems(cols)), self);
        }

        pub fn returningAll(self: Self) Insert(S, tag, allItems(S, tag)) {
            return retype(Insert(S, tag, allItems(S, tag)), self);
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
            var w: Writer = .{ .a = a };
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
                            if (v) |x| try w.param(x) else try w.raw("DEFAULT");
                        } else try w.param(v);
                    };
                    try w.raw(")");
                }
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

        pub fn toSql(self: Self, a: Allocator) !Sql {
            const info = S.info(@field(S.Tag, tag));
            var w: Writer = .{ .a = a };
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

        pub fn toSql(self: Self, a: Allocator) !Sql {
            var w: Writer = .{ .a = a };
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

fn expectSql(q: anytype, text: []const u8, params: []const ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try q.toSql(arena.allocator());
    try testing.expectEqualStrings(text, got.sql);
    try testing.expectEqual(params.len, got.params.len);
    for (params, got.params) |want, have| {
        if (want) |w| try testing.expectEqualStrings(w, have.?) else try testing.expectEqual(null, have);
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
    try expectSql(c.selectFrom(.people).select(.{.id}).whereExpr(sql("lower(\"name\") = 'ada'")), "SELECT \"id\" FROM \"people\" WHERE lower(\"name\") = 'ada'", &.{});
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
