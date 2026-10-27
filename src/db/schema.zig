//! kick/db's code-first schema, as Zig struct literals: `db.table` turns
//! columns into row types, `db.Schema` resolves names and checks references.
const std = @import("std");
const Timestamp = @import("timestamp.zig").Timestamp;

pub const Action = enum { cascade, restrict, set_null, set_default, no_action };

/// A column's SQL type. `.@"enum"` takes a Zig enum with `pub const pg_name`.
pub const Type = union(enum) {
    uuid,
    text,
    varchar: u32,
    char: u32,
    integer,
    smallint,
    bigint,
    serial,
    bigserial,
    boolean,
    real,
    double_precision,
    numeric: struct { precision: ?u16 = null, scale: ?u16 = null },
    timestamp,
    timestamptz,
    date,
    json,
    jsonb,
    @"enum": type,
};

pub const Default = union(enum) {
    none,
    /// kick/db's `.default(value)`: quoted or not by the column's type when emitted.
    value: []const u8,
    /// `.defaultSql(sql)`: SQL evaluated by the database.
    sql: []const u8,
    /// `.defaultNow()`: `CURRENT_TIMESTAMP`.
    now,
    /// `.defaultRandom()`: `gen_random_uuid()`.
    random,
};

pub const Reference = struct {
    /// `"table.column"`: the table's SQL name and the column's key.
    to: []const u8,
    on_delete: Action = .no_action,
    on_update: Action = .no_action,
    /// The constraint's name; derived (`<table>_<column>_fk`) when null.
    name: ?[]const u8 = null,
};

pub const Column = struct {
    type: Type,
    not_null: bool = false,
    primary_key: bool = false,
    unique: bool = false,
    default: Default = .none,
    references: ?Reference = null,
};

pub const Index = struct {
    name: []const u8,
    on: []const []const u8,
    unique: bool = false,
    where: ?[]const u8 = null,
    using: ?[]const u8 = null,
};

/// The resolved schema, in kick/db's snapshot terms.
pub const ColumnInfo = struct {
    key: []const u8,
    name: []const u8,
    sql_type: []const u8,
    nullable: bool,
    default: ?[]const u8,
    default_sql: bool,
    primary_key: bool,
};
pub const IndexInfo = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool,
    where: ?[]const u8 = null,
    using: ?[]const u8 = null,
};
pub const ForeignKeyInfo = struct {
    name: []const u8,
    columns: []const []const u8,
    ref_table: []const u8,
    ref_columns: []const []const u8,
    on_delete: Action,
    on_update: Action,
};
pub const CheckInfo = struct { name: []const u8, expression: []const u8 };
pub const PrimaryKeyInfo = struct { name: ?[]const u8, columns: []const []const u8 };
pub const TableInfo = struct {
    name: []const u8,
    columns: []const ColumnInfo,
    indexes: []const IndexInfo,
    foreign_keys: []const ForeignKeyInfo,
    checks: []const CheckInfo,
    /// Only when declared on the table (kick/db's `primaryKey(name?).on(…)`).
    primary_key: ?PrimaryKeyInfo,
};
pub const EnumInfo = struct { name: []const u8, values: []const []const u8 };

pub const SchemaOptions = struct {
    /// kick/db's `casing: 'snake_case'`: keys stay camelCase, the database's
    /// names are snake_case.
    casing: ?enum { snake_case } = null,
    /// The SQL the schema's database speaks.
    dialect: @import("db.zig").Dialect = .postgres,
};

/// `Schema`'s options as given: `.casing` and `.relations`.
fn optionsOf(comptime o: anytype) SchemaOptions {
    for (@typeInfo(@TypeOf(o)).@"struct".field_names) |f| if (!std.mem.eql(u8, f, "casing") and !std.mem.eql(u8, f, "relations") and !std.mem.eql(u8, f, "dialect"))
        @compileError("Schema: no option ." ++ f ++ " (casing, dialect, relations)");
    return .{
        .casing = if (@hasField(@TypeOf(o), "casing")) o.casing else null,
        .dialect = if (@hasField(@TypeOf(o), "dialect")) o.dialect else .postgres,
    };
}

pub const RelationKind = enum { one, many };

/// A relation resolved as kick/db's `extract-relations.ts` does; column
/// names are keys, the target is its declared table name.
pub const RelationInfo = struct {
    name: []const u8,
    kind: RelationKind,
    target_tag: []const u8,
    target: []const u8,
    source_columns: []const []const u8,
    target_columns: []const []const u8,
    relation_name: ?[]const u8 = null,
    through: ?Through = null,

    pub const Through = struct {
        table_tag: []const u8,
        table: []const u8,
        source_columns: []const []const u8,
        target_columns: []const []const u8,
    };
};

/// A table from a struct literal of columns (each a `Column`) and, optionally,
/// `.indexes`, `.checks` and `.primary_key`.
pub fn table(comptime name: []const u8, comptime columns: anytype, comptime constraints: anytype) type {
    comptime {
        const C = @TypeOf(columns);
        const keys = @typeInfo(C).@"struct".field_names;
        var cols: [keys.len]Column = undefined;
        for (keys, &cols) |k, *c| c.* = coerce(Column, @field(columns, k), name ++ "." ++ k);
        const cols_final = cols;
        for (keys, cols_final) |k, c| if (c.type == .@"enum") {
            const E = c.type.@"enum";
            if (!@hasDecl(E, "pg_name")) @compileError(name ++ "." ++ k ++ ": an enum column's type needs `pub const pg_name`");
            if (c.default == .value and !@hasField(E, c.default.value))
                @compileError(name ++ "." ++ k ++ ": default \"" ++ c.default.value ++ "\" is not a value of " ++ E.pg_name);
        };

        const Cs = @TypeOf(constraints);
        for (@typeInfo(Cs).@"struct".field_names) |f| if (!has(&.{ "indexes", "checks", "primary_key" }, f))
            @compileError(name ++ ": no constraint kind ." ++ f ++ " (indexes, checks, primary_key)");
        if (@hasField(Cs, "checks")) for (@typeInfo(@TypeOf(constraints.checks)).@"struct".field_names) |ck|
            for (@typeInfo(@TypeOf(@field(constraints.checks, ck))).@"struct".field_names) |f| if (!has(&.{ "name", "sql" }, f))
                @compileError(name ++ ".checks." ++ ck ++ ": no option ." ++ f);
        const indexes = if (@hasField(Cs, "indexes")) constraints.indexes else .{};
        for (@typeInfo(@TypeOf(indexes)).@"struct".field_names) |ik| {
            for (@typeInfo(@TypeOf(@field(indexes, ik))).@"struct".field_names) |f| if (!has(&.{ "name", "on", "unique", "where", "using" }, f))
                @compileError(name ++ ".indexes." ++ ik ++ ": no option ." ++ f);
            for (@field(indexes, ik).on) |col|
                if (!has(keys, @tagName(col))) @compileError(name ++ ".indexes." ++ ik ++ ": no column " ++ @tagName(col));
        }
        if (@hasField(Cs, "primary_key")) for (constraints.primary_key.on) |col|
            if (!has(keys, @tagName(col))) @compileError(name ++ ".primary_key: no column " ++ @tagName(col));

        var row_types: [keys.len]type = undefined;
        var ins_types: [keys.len]type = undefined;
        var up_types: [keys.len]type = undefined;
        var row_attrs: [keys.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        var ins_attrs: [keys.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        var up_attrs: [keys.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (keys, cols_final, 0..) |k, c, i| {
            const pk = c.primary_key or (@hasField(Cs, "primary_key") and hasLit(constraints.primary_key.on, k));
            const Z = ZigType(c.type);
            const nullable = !(c.not_null or pk or isSerial(c.type));
            row_types[i] = if (nullable) ?Z else Z;
            row_attrs[i] = .{};
            const required = !nullable and c.default == .none and !isSerial(c.type);
            if (required) {
                ins_types[i] = Z;
                ins_attrs[i] = .{};
            } else {
                ins_types[i] = ?Z;
                ins_attrs[i] = .{ .default_value_ptr = &@as(?Z, null) };
            }
            up_types[i] = ?row_types[i];
            up_attrs[i] = .{ .default_value_ptr = &@as(?row_types[i], null) };
        }
        const row_t = row_types;
        const ins_t = ins_types;
        const up_t = up_types;
        const row_a = row_attrs;
        const ins_a = ins_attrs;
        const up_a = up_attrs;
        return struct {
            pub const name_ = name;
            pub const column_keys = keys;
            pub const column_defs: []const Column = &cols_final;
            pub const table_constraints = constraints;
            /// A row as read: nullable columns are optional.
            pub const Row = @Struct(.auto, null, keys, &row_t, &row_a);
            /// A row to insert: columns with a default, serial or nullable may be left null (omitted).
            pub const Insert = @Struct(.auto, null, keys, &ins_t, &ins_a);
            /// Columns to set; null leaves one as it is (`@as(?T, null)` sets a nullable column to NULL).
            pub const Update = @Struct(.auto, null, keys, &up_t, &up_a);
            pub const Col = std.meta.FieldEnum(Row);
        };
    }
}

/// A struct literal's value as `T`. Literals declared apart from their use
/// have their own types, which don't coerce to `Column` on their own.
fn coerce(comptime T: type, comptime v: anytype, comptime at: []const u8) T {
    const V = @TypeOf(v);
    if (V == T) return v;
    switch (@typeInfo(T)) {
        .optional => |o| return if (V == @TypeOf(null)) null else coerce(o.child, v, at),
        .@"struct" => |info| {
            if (@typeInfo(V) != .@"struct") @compileError(at ++ ": expected a struct literal for " ++ @typeName(T));
            for (@typeInfo(V).@"struct".field_names) |f| if (!@hasField(T, f)) @compileError(at ++ ": no option ." ++ f);
            var out: T = undefined;
            for (info.field_names, info.field_types, info.field_attrs) |f, F, attrs| {
                @field(out, f) = if (@hasField(V, f)) coerce(F, @field(v, f), at ++ "." ++ f) else attrs.defaultValue(F) orelse @compileError(at ++ ": ." ++ f ++ " is required");
            }
            return out;
        },
        .@"union" => {
            if (@typeInfo(V) == .enum_literal) return @field(T, @tagName(v));
            const fs = @typeInfo(V).@"struct".field_names;
            if (fs.len != 1) @compileError(at ++ ": expected one of " ++ @typeName(T) ++ "'s tags");
            return @unionInit(T, fs[0], coerce(@FieldType(T, fs[0]), @field(v, fs[0]), at));
        },
        else => return v,
    }
}

fn has(keys: []const []const u8, k: []const u8) bool {
    for (keys) |x| if (std.mem.eql(u8, x, k)) return true;
    return false;
}

fn hasLit(lits: anytype, k: []const u8) bool {
    for (lits) |l| if (std.mem.eql(u8, @tagName(l), k)) return true;
    return false;
}

fn isSerial(t: Type) bool {
    return t == .serial or t == .bigserial;
}

/// The Zig type a column's value reads into.
pub fn ZigType(comptime t: Type) type {
    return switch (t) {
        .uuid, .text, .varchar, .char, .numeric => []const u8,
        .smallint => i16,
        .integer, .serial => i32,
        .bigint, .bigserial => i64,
        .boolean => bool,
        .real => f32,
        .double_precision => f64,
        .timestamp, .timestamptz, .date => Timestamp,
        .json, .jsonb => std.json.Value,
        .@"enum" => |E| E,
    };
}

/// kick/db's snapshot spelling of a type.
pub fn sqlType(comptime t: Type) []const u8 {
    return switch (t) {
        .varchar => |n| std.fmt.comptimePrint("varchar({d})", .{n}),
        .char => |n| std.fmt.comptimePrint("char({d})", .{n}),
        .double_precision => "double precision",
        .numeric => |n| if (n.precision) |p|
            (if (n.scale) |s| std.fmt.comptimePrint("numeric({d}, {d})", .{ p, s }) else std.fmt.comptimePrint("numeric({d})", .{p}))
        else
            "numeric",
        .@"enum" => |E| E.pg_name,
        else => @tagName(t),
    };
}

/// The tables in `tables` (a struct literal of `table` types), resolved:
/// database names, derived constraint names, enums, checked references.
pub fn Schema(comptime tables: anytype, comptime given: anytype) type {
    comptime {
        const options = optionsOf(given);
        const decls = if (@hasField(@TypeOf(given), "relations")) given.relations else .{};
        @setEvalBranchQuota(200_000);
        const tags = @typeInfo(@TypeOf(tables)).@"struct".field_names;
        var infos: [tags.len]TableInfo = undefined;
        var enum_list: []const EnumInfo = &.{};
        for (tags, &infos) |tag, *info| {
            const T = @field(tables, tag);
            info.* = resolve(T, tables, options);
            for (T.column_defs) |c| if (c.type == .@"enum") {
                const E = c.type.@"enum";
                if (!hasEnum(enum_list, E.pg_name)) enum_list = enum_list ++ [_]EnumInfo{.{ .name = E.pg_name, .values = @typeInfo(E).@"enum".field_names }};
            };
        }
        const infos_final = infos;
        const enums_final = sortEnums(enum_list);
        for (@typeInfo(@TypeOf(decls)).@"struct".field_names) |t| if (!@hasField(@TypeOf(tables), t))
            @compileError("relations." ++ t ++ ": no table " ++ t);
        var rels: [tags.len][]const RelationInfo = undefined;
        for (tags, &rels) |tag, *r| r.* = resolveRelations(tables, decls, tag);
        const rels_final = rels;
        return struct {
            pub const Tag = std.meta.FieldEnum(@TypeOf(tables));
            pub const tables_info: []const TableInfo = &infos_final;
            /// pg enums used by the columns, sorted by name.
            pub const enums: []const EnumInfo = enums_final;
            pub const casing = options.casing;
            pub const dialect = options.dialect;

            pub fn Table(comptime t: Tag) type {
                return @field(tables, @tagName(t));
            }

            pub fn info(comptime t: Tag) TableInfo {
                return infos_final[@backingInt(t)];
            }

            /// The table's relations, in declaration order.
            pub fn relationsOf(comptime t: Tag) []const RelationInfo {
                return rels_final[@backingInt(t)];
            }

            pub const relations_info: []const []const RelationInfo = &rels_final;
            /// Tables given a relations entry (kick/db writes those, even empty).
            pub const relation_tables: []const []const u8 = @typeInfo(@TypeOf(decls)).@"struct".field_names;
        };
    }
}

fn declOf(comptime decls: anytype, comptime tag: []const u8) type {
    return @TypeOf(if (@hasField(@TypeOf(decls), tag)) @field(decls, tag) else .{});
}

fn tableByTag(comptime tables: anytype, comptime tag: []const u8, comptime at: []const u8) type {
    if (!@hasField(@TypeOf(tables), tag)) @compileError(at ++ ": no table " ++ tag);
    return @field(tables, tag);
}

fn keyList(comptime T: type, comptime lits: anytype, comptime at: []const u8) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (lits) |l| {
        if (!has(T.column_keys, @tagName(l))) @compileError(at ++ ": no column " ++ @tagName(l) ++ " in " ++ T.name_);
        out = out ++ [_][]const u8{@tagName(l)};
    }
    return out;
}

const ForeignKeyRef = struct { columns: []const []const u8, ref_columns: []const []const u8 };

/// `T`'s single-column keys to the table declared `ref_table`.
fn keysTo(comptime T: type, comptime ref_table: []const u8) []const ForeignKeyRef {
    var out: []const ForeignKeyRef = &.{};
    for (T.column_keys, T.column_defs) |k, c| if (c.references) |r| {
        const dot = std.mem.findScalar(u8, r.to, '.').?;
        if (std.mem.eql(u8, r.to[0..dot], ref_table)) out = out ++ [_]ForeignKeyRef{.{ .columns = &.{k}, .ref_columns = &.{r.to[dot + 1 ..]} }};
    };
    return out;
}

fn optStr(comptime R: type, comptime r: R, comptime f: []const u8) ?[]const u8 {
    return if (@hasField(R, f)) @field(r, f) else null;
}

fn resolveRelations(comptime tables: anytype, comptime decls: anytype, comptime tag: []const u8) []const RelationInfo {
    const T = @field(tables, tag);
    const D = declOf(decls, tag);
    const decl: D = if (@hasField(@TypeOf(decls), tag)) @field(decls, tag) else .{};
    var out: []const RelationInfo = &.{};
    for (@typeInfo(D).@"struct".field_names) |rk| {
        const at = T.name_ ++ "." ++ rk;
        const R = @TypeOf(@field(decl, rk));
        const r = @field(decl, rk);
        for (@typeInfo(R).@"struct".field_names) |f| if (!has(&.{ "one", "many", "fields", "references", "relation_name", "through" }, f))
            @compileError(at ++ ": no option ." ++ f);
        if (has(T.column_keys, rk)) @compileError(at ++ ": a relation can't share a column's name");
        if (@hasField(R, "one") == @hasField(R, "many")) @compileError(at ++ ": give .one or .many the target table");
        const rel_name = optStr(R, r, "relation_name");
        if (@hasField(R, "one")) {
            const target_tag = @tagName(r.one);
            const Target = tableByTag(tables, target_tag, at);
            if (!@hasField(R, "fields") or !@hasField(R, "references")) @compileError(at ++ ": a one needs .fields and .references");
            if (r.fields.len != r.references.len) @compileError(at ++ ": .fields and .references must be as long");
            out = out ++ [_]RelationInfo{.{ .name = rk, .kind = .one, .target_tag = target_tag, .target = Target.name_, .source_columns = keyList(T, r.fields, at), .target_columns = keyList(Target, r.references, at), .relation_name = rel_name }};
            continue;
        }
        const target_tag = @tagName(r.many);
        const Target = tableByTag(tables, target_tag, at);
        if (@hasField(R, "fields") or @hasField(R, "references")) @compileError(at ++ ": a many takes no .fields or .references");
        if (@hasField(R, "through")) {
            const Th = @TypeOf(r.through);
            const j_tag = if (Th == @TypeOf(.x)) @tagName(r.through) else @tagName(r.through.table);
            const J = tableByTag(tables, j_tag, at);
            const explicit = Th != @TypeOf(.x);
            if (explicit and (r.through.from.len != 1 or r.through.to.len != 1)) @compileError(at ++ ": through .from and .to take one column each");
            if (!explicit and std.mem.eql(u8, tag, target_tag)) @compileError(at ++ ": a through joining a table to itself needs .from and .to");
            const to_source = pickKey(J, T.name_, if (explicit) keyList(J, r.through.from, at) else null, at ++ " (to the source)");
            const to_target = pickKey(J, Target.name_, if (explicit) keyList(J, r.through.to, at) else null, at ++ " (to the target)");
            out = out ++ [_]RelationInfo{.{ .name = rk, .kind = .many, .target_tag = target_tag, .target = Target.name_, .source_columns = to_source.ref_columns, .target_columns = to_target.ref_columns, .relation_name = rel_name, .through = .{ .table_tag = j_tag, .table = J.name_, .source_columns = to_source.columns, .target_columns = to_target.columns } }};
            continue;
        }
        // kick/db: the inverse with the same relation name, else the one
        // untagged `one` back, else the target's one foreign key to us.
        const TD = declOf(decls, target_tag);
        const tdecl: TD = if (@hasField(@TypeOf(decls), target_tag)) @field(decls, target_tag) else .{};
        var tagged: ?[2][]const []const u8 = null;
        var tagged_n: usize = 0;
        var untagged: ?[2][]const []const u8 = null;
        var untagged_n: usize = 0;
        for (@typeInfo(TD).@"struct".field_names) |ik| {
            const IR = @TypeOf(@field(tdecl, ik));
            const ir = @field(tdecl, ik);
            if (!@hasField(IR, "one") or !std.mem.eql(u8, @tagName(ir.one), tag) or !@hasField(IR, "fields")) continue;
            const pair = [2][]const []const u8{ keyList(T, ir.references, at), keyList(Target, ir.fields, at) };
            const irn = optStr(IR, ir, "relation_name");
            if (rel_name != null and irn != null and std.mem.eql(u8, irn.?, rel_name.?)) {
                tagged = pair;
                tagged_n += 1;
            } else if (irn == null) {
                untagged = pair;
                untagged_n += 1;
            }
        }
        if (tagged_n > 1) @compileError(at ++ ": more than one one on " ++ Target.name_ ++ " has relation_name \"" ++ rel_name.? ++ "\"");
        const pair = if (tagged_n == 1) tagged.? else if (untagged_n == 1) untagged.? else blk: {
            const keys = keysTo(Target, T.name_);
            if (keys.len != 1) @compileError(at ++ ": no one back from " ++ Target.name_ ++ " and no single foreign key to " ++ T.name_);
            break :blk [2][]const []const u8{ keys[0].ref_columns, keys[0].columns };
        };
        out = out ++ [_]RelationInfo{.{ .name = rk, .kind = .many, .target_tag = target_tag, .target = Target.name_, .source_columns = pair[0], .target_columns = pair[1], .relation_name = rel_name }};
    }
    return out;
}

/// The junction's key to `ref_table`: the one there is, or the one on `columns`.
fn pickKey(comptime J: type, comptime ref_table: []const u8, comptime columns: ?[]const []const u8, comptime at: []const u8) ForeignKeyRef {
    var found: ?ForeignKeyRef = null;
    var n: usize = 0;
    for (keysTo(J, ref_table)) |k| {
        if (columns) |cs| if (!std.mem.eql(u8, k.columns[0], cs[0])) continue;
        found = k;
        n += 1;
    }
    if (n != 1) @compileError(at ++ ": " ++ J.name_ ++ " needs exactly one foreign key to " ++ ref_table);
    return found.?;
}

fn hasEnum(list: []const EnumInfo, name: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

fn sortEnums(comptime list: []const EnumInfo) []const EnumInfo {
    var arr: [list.len]EnumInfo = list[0..list.len].*;
    std.mem.sort(EnumInfo, &arr, {}, struct {
        fn lt(_: void, a: EnumInfo, b: EnumInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    const out = arr;
    return &out;
}

fn dbName(comptime options: SchemaOptions, comptime key: []const u8) []const u8 {
    return if (options.casing == .snake_case) snakeCase(key) else key;
}

fn resolve(comptime T: type, comptime tables: anytype, comptime options: SchemaOptions) TableInfo {
    const name = dbName(options, T.name_);
    const keys = T.column_keys;
    const Cs = @TypeOf(T.table_constraints);
    var columns: [keys.len]ColumnInfo = undefined;
    var indexes: []const IndexInfo = &.{};
    var fks: []const ForeignKeyInfo = &.{};
    var pk: ?PrimaryKeyInfo = null;
    if (@hasField(Cs, "primary_key")) {
        const p = T.table_constraints.primary_key;
        pk = .{ .name = if (@hasField(@TypeOf(p), "name")) p.name else null, .columns = litNames(options, p.on) };
    }
    if (@hasField(Cs, "indexes")) {
        const ix = T.table_constraints.indexes;
        for (@typeInfo(@TypeOf(ix)).@"struct".field_names) |ik| {
            const i: Index = .{
                .name = @field(ix, ik).name,
                .on = &.{},
                .unique = if (@hasField(@TypeOf(@field(ix, ik)), "unique")) @field(ix, ik).unique else false,
                .where = if (@hasField(@TypeOf(@field(ix, ik)), "where")) @field(ix, ik).where else null,
                .using = if (@hasField(@TypeOf(@field(ix, ik)), "using")) @field(ix, ik).using else null,
            };
            indexes = indexes ++ [_]IndexInfo{.{ .name = i.name, .columns = litNames(options, @field(ix, ik).on), .unique = i.unique, .where = i.where, .using = i.using }};
        }
    }
    for (keys, T.column_defs, &columns) |k, c, *out| {
        const db = dbName(options, k);
        const in_pk = c.primary_key or (pk != null and has(pk.?.columns, db));
        out.* = .{
            .key = k,
            .name = db,
            .sql_type = sqlType(c.type),
            .nullable = !(c.not_null or in_pk or isSerial(c.type)),
            .default = switch (c.default) {
                .none => null,
                .value, .sql => |v| v,
                .now => "CURRENT_TIMESTAMP",
                .random => "gen_random_uuid()",
            },
            .default_sql = c.default == .sql,
            .primary_key = in_pk,
        };
        if (c.unique) indexes = indexes ++ [_]IndexInfo{.{ .name = fitIdentifier(name ++ "_" ++ db ++ "_unique"), .columns = &.{db}, .unique = true }};
        if (c.references) |r| {
            const dot = std.mem.findScalar(u8, r.to, '.') orelse @compileError(name ++ "." ++ k ++ ": references.to must be \"table.column\", not \"" ++ r.to ++ "\"");
            const ref_table = r.to[0..dot];
            const ref_col = r.to[dot + 1 ..];
            const Ref = for (@typeInfo(@TypeOf(tables)).@"struct".field_names) |tag| {
                if (std.mem.eql(u8, @field(tables, tag).name_, ref_table)) break @field(tables, tag);
            } else @compileError(name ++ "." ++ k ++ ": no table " ++ ref_table);
            if (!has(Ref.column_keys, ref_col)) @compileError(name ++ "." ++ k ++ ": no column " ++ ref_col ++ " in " ++ ref_table);
            fks = fks ++ [_]ForeignKeyInfo{.{
                .name = r.name orelse fitIdentifier(name ++ "_" ++ db ++ "_fk"),
                .columns = &.{db},
                .ref_table = dbName(options, ref_table),
                .ref_columns = &.{dbName(options, ref_col)},
                .on_delete = r.on_delete,
                .on_update = r.on_update,
            }};
        }
    }
    var checks: []const CheckInfo = &.{};
    if (@hasField(Cs, "checks")) {
        const ch = T.table_constraints.checks;
        for (@typeInfo(@TypeOf(ch)).@"struct".field_names) |ck| checks = checks ++ [_]CheckInfo{.{ .name = @field(ch, ck).name, .expression = @field(ch, ck).sql }};
    }
    const cols_final = columns;
    return .{ .name = name, .columns = &cols_final, .indexes = indexes, .foreign_keys = fks, .checks = checks, .primary_key = pk };
}

fn litNames(comptime options: SchemaOptions, comptime lits: anytype) []const []const u8 {
    var out: [lits.len][]const u8 = undefined;
    for (lits, &out) |l, *o| o.* = dbName(options, @tagName(l));
    const final = out;
    return &final;
}

/// Kysely's snake_case mapper, as kick/db's `casing: 'snake_case'` uses it:
/// an underscore before an upper-case letter unless the one before is too.
pub fn snakeCase(comptime s: []const u8) []const u8 {
    comptime {
        if (s.len == 0) return s;
        var out: []const u8 = &.{std.ascii.toLower(s[0])};
        for (s[1..], 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                out = out ++ (if (std.ascii.isUpper(s[i])) "" else "_") ++ &[_]u8{std.ascii.toLower(c)};
            } else out = out ++ &[_]u8{c};
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

/// kick/db's `fitIdentifier`: a name over Postgres's 63 bytes keeps its head,
/// a hash of the whole name and its `_kind` suffix.
pub fn fitIdentifier(comptime n: []const u8) []const u8 {
    comptime {
        if (n.len <= 63) return n;
        @setEvalBranchQuota(1_000_000);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(n, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const us = std.mem.findScalarLast(u8, n, '_');
        const kind = if (us) |i| (if (i + 1 < n.len and allLower(n[i + 1 ..])) n[i + 1 ..] else "") else "";
        const tail = if (kind.len > 0) "_" ++ hex[0..6] ++ "_" ++ kind else "_" ++ hex[0..6];
        const head = if (kind.len > 0) n[0 .. n.len - kind.len - 1] else n;
        const out = head[0..@min(head.len, 63 - tail.len)] ++ tail;
        const final = out[0..out.len].*;
        return &final;
    }
}

fn allLower(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isLower(c)) return false;
    return true;
}

const testing = std.testing;

const GlobalRole = enum {
    superadmin,
    user,
    pub const pg_name = "global_role";
};

const users = table("users", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .email = .{ .type = .{ .varchar = 255 }, .not_null = true, .unique = true },
    .passwordHash = .{ .type = .{ .varchar = 255 }, .not_null = true },
    .firstName = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .lastName = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .avatarUrl = .{ .type = .text },
    .globalRole = .{ .type = .{ .@"enum" = GlobalRole }, .not_null = true, .default = .{ .value = "user" } },
    .isActive = .{ .type = .boolean, .not_null = true, .default = .{ .value = "true" } },
    .lastLoginAt = .{ .type = .timestamp },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .nameIdx = .{ .name = "users_name_idx", .on = .{ .firstName, .lastName } } },
});

const projects = table("projects", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .budget = .{ .type = .{ .numeric = .{ .precision = 10, .scale = 2 } } },
}, .{});

const tasks = table("tasks", .{
    .id = .{ .type = .serial, .primary_key = true },
    .projectId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "projects.id", .on_delete = .cascade } },
    .parentTaskId = .{ .type = .integer, .references = .{ .to = "tasks.id", .on_delete = .set_null } },
    .meta = .{ .type = .jsonb },
    .points = .{ .type = .smallint, .not_null = true, .default = .{ .value = "0" } },
}, .{
    .checks = .{ .points = .{ .name = "tasks_points_check", .sql = "\"points\" >= 0" } },
});

test "row, insert and update types follow the columns" {
    try testing.expect(@FieldType(users.Row, "id") == []const u8);
    try testing.expect(@FieldType(users.Row, "avatarUrl") == ?[]const u8);
    try testing.expect(@FieldType(users.Row, "globalRole") == GlobalRole);
    try testing.expect(@FieldType(users.Row, "lastLoginAt") == ?Timestamp);
    try testing.expect(@FieldType(tasks.Row, "id") == i32);
    try testing.expect(@FieldType(tasks.Row, "points") == i16);
    try testing.expect(@FieldType(tasks.Row, "meta") == ?std.json.Value);
    // Insert: only not-null columns without a default are required.
    const in: users.Insert = .{ .email = "a@b.c", .passwordHash = "h", .firstName = "A", .lastName = "B" };
    try testing.expectEqual(null, in.id);
    try testing.expectEqual(null, in.avatarUrl);
    const t: tasks.Insert = .{ .projectId = "p" };
    try testing.expectEqual(null, t.id);
    // Update: everything optional; a nullable column can be set to NULL.
    const up: users.Update = .{ .avatarUrl = @as(?[]const u8, null) };
    try testing.expectEqual(null, up.email);
    try testing.expect(up.avatarUrl != null and up.avatarUrl.? == null);
}

test "the schema resolves names, types, defaults and constraints as kick/db's snapshot has them" {
    const S = Schema(.{ .users = users, .projects = projects, .tasks = tasks }, .{});
    try testing.expect(S.Table(.users) == users);
    const u = S.info(.users);
    try testing.expectEqualStrings("users", u.name);
    try testing.expectEqualStrings("varchar(255)", u.columns[1].sql_type);
    try testing.expectEqualStrings("global_role", u.columns[6].sql_type);
    try testing.expectEqualStrings("user", u.columns[6].default.?);
    try testing.expectEqualStrings("gen_random_uuid()", u.columns[0].default.?);
    try testing.expectEqualStrings("CURRENT_TIMESTAMP", u.columns[9].default.?);
    try testing.expect(!u.columns[0].nullable and u.columns[0].primary_key);
    try testing.expect(u.columns[5].nullable);
    // Declared indexes first, then the columns' unique ones (kick/db's extract order).
    try testing.expectEqualStrings("users_name_idx", u.indexes[0].name);
    try testing.expectEqualStrings("lastName", u.indexes[0].columns[1]);
    try testing.expectEqualStrings("users_email_unique", u.indexes[1].name);
    try testing.expect(u.indexes[1].unique);
    try testing.expectEqualStrings("numeric(10, 2)", S.info(.projects).columns[1].sql_type);
    const t = S.info(.tasks);
    try testing.expectEqualStrings("serial", t.columns[0].sql_type);
    try testing.expectEqual(null, t.columns[0].default);
    try testing.expectEqualStrings("tasks_projectId_fk", t.foreign_keys[0].name);
    try testing.expectEqualStrings("projects", t.foreign_keys[0].ref_table);
    try testing.expectEqual(Action.cascade, t.foreign_keys[0].on_delete);
    try testing.expectEqualStrings("tasks", t.foreign_keys[1].ref_table);
    try testing.expectEqualStrings("tasks_points_check", t.checks[0].name);
    try testing.expectEqual(1, S.enums.len);
    try testing.expectEqualStrings("global_role", S.enums[0].name);
    try testing.expectEqualStrings("user", S.enums[0].values[1]);
}

test "snake_case: keys stay, database names change" {
    const S = Schema(.{ .users = users }, .{ .casing = .snake_case });
    const u = S.info(.users);
    try testing.expectEqualStrings("firstName", u.columns[3].key);
    try testing.expectEqualStrings("first_name", u.columns[3].name);
    try testing.expectEqualStrings("first_name", u.indexes[0].columns[0]);
    try testing.expectEqualStrings("user_id", comptime snakeCase("userID"));
    try testing.expectEqualStrings("http_code", comptime snakeCase("httpCode"));
}

test "snake_case renames tables too, and names derived from them" {
    const teamMembers = table("teamMembers", .{
        .id = .{ .type = .serial, .primary_key = true },
        .userId = .{ .type = .uuid, .unique = true, .references = .{ .to = "users.id" } },
    }, .{});
    const S = Schema(.{ .users = users, .members = teamMembers }, .{ .casing = .snake_case });
    const m = S.info(.members);
    try testing.expectEqualStrings("team_members", m.name);
    try testing.expectEqualStrings("team_members_user_id_unique", m.indexes[0].name);
    try testing.expectEqualStrings("team_members_user_id_fk", m.foreign_keys[0].name);
    try testing.expectEqualStrings("users", m.foreign_keys[0].ref_table);
}

test "long constraint names are shortened as kick/db shortens them" {
    try testing.expectEqualStrings("a_very_long_table_name_for_testing_identifier_lim_aed105_unique", comptime fitIdentifier("a_very_long_table_name_for_testing_identifier_limits_in_postgres_col_unique"));
    try testing.expectEqualStrings("short_fk", comptime fitIdentifier("short_fk"));
}

const r_users = table("users", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
const r_posts = table("posts", .{
    .id = .{ .type = .serial, .primary_key = true },
    .authorId = .{ .type = .integer, .not_null = true, .references = .{ .to = "users.id" } },
    .editorId = .{ .type = .integer, .references = .{ .to = "users.id" } },
    .parentId = .{ .type = .integer, .references = .{ .to = "posts.id" } },
}, .{});
const r_tags = table("tags", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
const r_post_tags = table("post_tags", .{
    .postId = .{ .type = .integer, .not_null = true, .references = .{ .to = "posts.id" } },
    .tagId = .{ .type = .integer, .not_null = true, .references = .{ .to = "tags.id" } },
}, .{});

test "relations resolve as kick/db's: one as declared, many by its inverse or relation name, through by the junction's keys" {
    const S = Schema(.{ .users = r_users, .posts = r_posts, .tags = r_tags, .post_tags = r_post_tags }, .{ .relations = .{
        .users = .{
            .posts = .{ .many = .posts, .relation_name = "author" },
            .edited = .{ .many = .posts, .relation_name = "editor" },
        },
        .posts = .{
            .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id}, .relation_name = "author" },
            .editor = .{ .one = .users, .fields = .{.editorId}, .references = .{.id}, .relation_name = "editor" },
            .parent = .{ .one = .posts, .fields = .{.parentId}, .references = .{.id} },
            .children = .{ .many = .posts },
            .tags = .{ .many = .tags, .through = .post_tags },
        },
        .tags = .{ .posts = .{ .many = .posts, .through = .post_tags } },
    } });
    const u = S.relationsOf(.users);
    try testing.expectEqualStrings("posts", u[0].name);
    try testing.expectEqualStrings("id", u[0].source_columns[0]);
    try testing.expectEqualStrings("authorId", u[0].target_columns[0]);
    try testing.expectEqualStrings("editorId", u[1].target_columns[0]);
    const p = S.relationsOf(.posts);
    try testing.expectEqual(.one, p[0].kind);
    try testing.expectEqualStrings("users", p[0].target);
    // The untagged one back to posts: parentId.
    try testing.expectEqualStrings("parentId", p[3].target_columns[0]);
    try testing.expectEqualStrings("post_tags", p[4].through.?.table);
    try testing.expectEqualStrings("postId", p[4].through.?.source_columns[0]);
    try testing.expectEqualStrings("tagId", p[4].through.?.target_columns[0]);
    try testing.expectEqualStrings("id", p[4].target_columns[0]);
    try testing.expectEqual(0, S.relationsOf(.post_tags).len);
}

test "a many with no one back falls back to the target's single foreign key" {
    const S = Schema(.{ .users = r_users, .tags = r_tags, .post_tags = r_post_tags, .posts = r_posts }, .{ .relations = .{
        .tags = .{ .links = .{ .many = .post_tags } },
    } });
    try testing.expectEqualStrings("tagId", S.relationsOf(.tags)[0].target_columns[0]);
}
