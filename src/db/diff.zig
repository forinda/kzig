//! kick/db's diff engine for the core schema: what changed between two
//! snapshots, in the order the DDL must run, and its inverse for down.sql.
const std = @import("std");
const snap = @import("snapshot.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Snapshot = snap.Snapshot;
const Table = snap.Table;
const Column = snap.Column;

pub const Index = snap.Index;
pub const ForeignKey = snap.ForeignKey;
pub const Check = snap.Check;
pub const Enum = snap.Enum;

/// A table's primary key as a change sees it; no columns = no key.
pub const KeyShape = struct { name: ?[]const u8 = null, columns: []const []const u8 = &.{} };

pub const Affected = struct { table: []const u8, column: []const u8, default: ?[]const u8 };

pub const Change = union(enum) {
    create_table: Table,
    drop_table: Table,
    rename_table: struct { from: []const u8, to: []const u8 },
    add_column: struct { table: []const u8, column: Column },
    drop_column: struct { table: []const u8, column: Column },
    rename_column: struct { table: []const u8, from: []const u8, to: []const u8 },
    alter_column: struct { table: []const u8, column: []const u8, before: Column, after: Column },
    add_index: struct { table: []const u8, index: Index },
    drop_index: struct { table: []const u8, index: Index },
    add_foreign_key: struct { table: []const u8, fk: ForeignKey },
    drop_foreign_key: struct { table: []const u8, fk: ForeignKey },
    create_enum: Enum,
    drop_enum: Enum,
    /// `ALTER TYPE … ADD VALUE`, `BEFORE` an existing value to keep the order.
    add_enum_value: struct { @"enum": []const u8, value: []const u8, before: ?[]const u8 = null },
    /// Postgres can't drop a value: the type is renamed and recreated.
    remove_enum_value: struct { @"enum": []const u8, removed: []const []const u8, values: []const []const u8, affected: []const Affected },
    alter_primary_key: struct { table: []const u8, before: KeyShape, after: KeyShape },
    add_check: struct { table: []const u8, check: Check },
    drop_check: struct { table: []const u8, check: Check },
};

/// Renames to apply instead of a drop and an add (`--rename-table`,
/// `--rename-column`, or the prompt's answers).
pub const Hints = struct {
    /// Old table → new table.
    tables: []const [2][]const u8 = &.{},
    /// `<new table>.<old column>` → new column.
    columns: []const [2][]const u8 = &.{},
    /// Only these pair a drop with an add: no guessing.
    explicit: bool = false,
};

fn findTable(s: Snapshot, name: []const u8) ?Table {
    for (s.tables) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn findColumn(t: Table, name: []const u8) ?Column {
    for (t.columns) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

fn findEnum(s: Snapshot, name: []const u8) ?Enum {
    for (s.enums orelse &.{}) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

const Pairs = []const [2][]const u8;

fn lookup(pairs: Pairs, from: []const u8) ?[]const u8 {
    for (pairs) |p| if (std.mem.eql(u8, p[0], from)) return p[1];
    return null;
}

fn isTarget(pairs: Pairs, to: []const u8) bool {
    for (pairs) |p| if (std.mem.eql(u8, p[1], to)) return true;
    return false;
}

const Renamed = struct {
    tables: Pairs,
    /// Per table (new name): old column → new column.
    columns: []const struct { table: []const u8, pairs: Pairs },

    fn of(r: Renamed, table: []const u8) Pairs {
        for (r.columns) |c| if (std.mem.eql(u8, c.table, table)) return c.pairs;
        return &.{};
    }
};

/// The changes that turn `prev` into `next`, in the order kick/db's engine
/// emits them: enums created, foreign keys into dropped tables and dropped
/// tables (children first), new tables then their indexes then their keys,
/// each kept table's changes, enums dropped.
pub fn diff(a: Allocator, prev_in: Snapshot, next: Snapshot, hints: Hints) ![]Change {
    var changes: std.ArrayList(Change) = .empty;
    var prev = prev_in;
    if (hints.tables.len > 0) prev = try applyTableRenames(a, prev, next, hints.tables, &changes);

    try enumsCreatePhase(a, prev, next, &changes);

    var dropped: std.ArrayList([]const u8) = .empty;
    for (prev.tables) |t| if (findTable(next, t.name) == null) try dropped.append(a, t.name);
    for (prev.tables) |t| {
        if (contains(dropped.items, t.name)) continue;
        for (t.foreign_keys) |f| if (contains(dropped.items, f.ref_table)) try changes.append(a, .{ .drop_foreign_key = .{ .table = t.name, .fk = f } });
    }
    for (try childrenFirst(a, dropped.items, prev)) |name| try changes.append(a, .{ .drop_table = findTable(prev, name).? });

    var created: std.ArrayList(Table) = .empty;
    for (next.tables) |t| if (findTable(prev, t.name) == null) try created.append(a, t);
    for (created.items) |t| try changes.append(a, .{ .create_table = t });
    for (created.items) |t| for (t.indexes) |i| try changes.append(a, .{ .add_index = .{ .table = t.name, .index = i } });
    for (created.items) |t| for (t.foreign_keys) |f| try changes.append(a, .{ .add_foreign_key = .{ .table = t.name, .fk = f } });

    // Every column rename first, so a key into a renamed column of another
    // table compares as the same key.
    var per_table: std.ArrayList(@typeInfo(@FieldType(Renamed, "columns")).pointer.child) = .empty;
    for (next.tables) |t| if (findTable(prev, t.name)) |p| {
        try per_table.append(a, .{ .table = t.name, .pairs = try columnRenames(a, p, t, hints) });
    };
    const renamed: Renamed = .{ .tables = hints.tables, .columns = per_table.items };
    for (next.tables) |t| if (findTable(prev, t.name)) |p| try diffTable(a, p, t, &changes, renamed, dropped.items);

    for (prev.enums orelse &.{}) |e| if (findEnum(next, e.name) == null) try changes.append(a, .{ .drop_enum = e });
    return changes.items;
}

fn applyTableRenames(a: Allocator, prev: Snapshot, next: Snapshot, renames: Pairs, changes: *std.ArrayList(Change)) !Snapshot {
    var tables = try a.dupe(Table, prev.tables);
    for (renames) |r| {
        const at = for (tables, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, r[0])) break i;
        } else return badRename();
        if (findTable(next, r[0]) != null or findTable(next, r[1]) == null) return badRename();
        for (tables) |t| if (std.mem.eql(u8, t.name, r[1])) return badRename();
        try changes.append(a, .{ .rename_table = .{ .from = r[0], .to = r[1] } });
        tables[at].name = r[1];
    }
    var out = prev;
    out.tables = tables;
    return out;
}

fn badRename() error{BadRename} {
    if (!@import("builtin").is_test) std.log.err("a rename needs the schema to have lost the old name and gained the new one", .{});
    return error.BadRename;
}

fn enumsCreatePhase(a: Allocator, prev: Snapshot, next: Snapshot, changes: *std.ArrayList(Change)) !void {
    for (next.enums orelse &.{}) |e| if (findEnum(prev, e.name) == null) try changes.append(a, .{ .create_enum = e });
    for (next.enums orelse &.{}) |e| {
        const prior = findEnum(prev, e.name) orelse continue;
        for (e.values, 0..) |v, i| {
            if (contains(prior.values, v)) continue;
            const before = if (i + 1 < e.values.len and contains(prior.values, e.values[i + 1])) e.values[i + 1] else null;
            try changes.append(a, .{ .add_enum_value = .{ .@"enum" = e.name, .value = v, .before = before } });
        }
        var removed: std.ArrayList([]const u8) = .empty;
        for (prior.values) |v| if (!contains(e.values, v)) try removed.append(a, v);
        if (removed.items.len == 0) continue;
        var affected: std.ArrayList(Affected) = .empty;
        for (next.tables) |t| for (t.columns) |c| if (std.mem.eql(u8, c.sql_type, e.name)) {
            // The default the column had before: restored after the swap.
            const default = if (findTable(prev, t.name)) |pt| (if (findColumn(pt, c.name)) |pc| pc.default else null) else null;
            if (default) |d| if (literalOf(d)) |lit| if (contains(removed.items, lit)) {
                if (!@import("builtin").is_test) std.log.err("{s}.{s}: its default '{s}' is a value removed from {s}; change the default first", .{ t.name, c.name, lit, e.name });
                return error.RemovedValueAsDefault;
            };
            try affected.append(a, .{ .table = t.name, .column = c.name, .default = default });
        };
        try changes.append(a, .{ .remove_enum_value = .{ .@"enum" = e.name, .removed = removed.items, .values = e.values, .affected = affected.items } });
    }
}

/// `'x'` or `'x'::"type"` → `x`; null for anything else.
fn literalOf(expr: []const u8) ?[]const u8 {
    var e = std.mem.trim(u8, expr, " ");
    if (std.mem.findLast(u8, e, "::")) |i| {
        const cast = std.mem.trim(u8, std.mem.trim(u8, e[i + 2 ..], " "), "\"");
        const ident = cast.len > 0 and (std.ascii.isAlphabetic(cast[0]) or cast[0] == '_') and for (cast) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break false;
        } else true;
        if (ident) e = std.mem.trim(u8, e[0..i], " ");
    }
    if (e.len < 2 or e[0] != '\'' or e[e.len - 1] != '\'') return null;
    const body = e[1 .. e.len - 1];
    // A lone quote inside would end the literal; '' is an escaped one.
    var i: usize = 0;
    while (i < body.len) : (i += 1) if (body[i] == '\'') {
        if (i + 1 < body.len and body[i + 1] == '\'') i += 1 else return null;
    };
    if (std.mem.find(u8, body, "''") != null) return null; // ponytail: escaped quotes in enum values aren't compared
    return body;
}

/// Dropped tables ordered so a table goes before any table it references.
fn childrenFirst(a: Allocator, dropped: []const []const u8, prev: Snapshot) ![]const []const u8 {
    var left: std.ArrayList([]const u8) = .empty;
    try left.appendSlice(a, dropped);
    var out: std.ArrayList([]const u8) = .empty;
    while (left.items.len > 0) {
        const i = for (left.items, 0..) |t, k| {
            const referenced = refs: for (left.items) |o| {
                if (std.mem.eql(u8, o, t)) continue;
                for (findTable(prev, o).?.foreign_keys) |f| if (std.mem.eql(u8, f.ref_table, t)) break :refs true;
            } else false;
            if (!referenced) break k;
        } else 0; // a cycle keeps declaration order
        try out.append(a, left.orderedRemove(i));
    }
    return out.items;
}

fn columnRenames(a: Allocator, prev: Table, next: Table, hints: Hints) !Pairs {
    var drops: std.ArrayList([]const u8) = .empty;
    var adds: std.ArrayList([]const u8) = .empty;
    for (prev.columns) |c| if (findColumn(next, c.name) == null) try drops.append(a, c.name);
    for (next.columns) |c| if (findColumn(prev, c.name) == null) try adds.append(a, c.name);
    var out: std.ArrayList([2][]const u8) = .empty;
    for (hints.columns) |h| {
        const dot = std.mem.findScalarLast(u8, h[0], '.') orelse return badRename();
        if (!std.mem.eql(u8, h[0][0..dot], next.name)) continue;
        const from = h[0][dot + 1 ..];
        if (!contains(drops.items, from) or !contains(adds.items, h[1])) return badRename();
        try out.append(a, .{ from, h[1] });
    }
    if (!hints.explicit) {
        // `project_id` → `projectId` (casing turned off or on), nothing else changed.
        for (drops.items) |from| {
            if (lookup(out.items, from) != null) continue;
            for (adds.items) |to| {
                if (isTarget(out.items, to) or std.mem.eql(u8, to, from)) continue;
                if (!(snakeEq(to, from) or snakeEq(from, to))) continue;
                if (!attrsEqual(findColumn(prev, from).?, findColumn(next, to).?)) continue;
                try out.append(a, .{ from, to });
                break;
            }
        }
        if (out.items.len == 0) {
            var left_drop: ?[]const u8 = null;
            var n_drops: usize = 0;
            for (drops.items) |d| if (lookup(out.items, d) == null) {
                n_drops += 1;
                left_drop = d;
            };
            var left_add: ?[]const u8 = null;
            var n_adds: usize = 0;
            for (adds.items) |x| if (!isTarget(out.items, x)) {
                n_adds += 1;
                left_add = x;
            };
            if (n_drops == 1 and n_adds == 1 and attrsEqual(findColumn(prev, left_drop.?).?, findColumn(next, left_add.?).?))
                try out.append(a, .{ left_drop.?, left_add.? });
        }
    }
    return out.items;
}

/// `snake == snakeCase(camel)`, at run time.
fn snakeEq(camel: []const u8, snake: []const u8) bool {
    var i: usize = 0;
    for (camel, 0..) |c, k| {
        if (std.ascii.isUpper(c)) {
            if (k > 0 and !std.ascii.isUpper(camel[k - 1])) {
                if (i >= snake.len or snake[i] != '_') return false;
                i += 1;
            }
            if (i >= snake.len or snake[i] != std.ascii.toLower(c)) return false;
        } else if (i >= snake.len or snake[i] != c) return false;
        i += 1;
    }
    return i == snake.len;
}

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

fn listEql(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The primary key is left to alter_primary_key.
fn columnsEqual(x: Column, y: Column) bool {
    return std.mem.eql(u8, x.sql_type, y.sql_type) and x.nullable == y.nullable and optEql(x.default, y.default) and x.default_sql == y.default_sql;
}

fn attrsEqual(x: Column, y: Column) bool {
    return columnsEqual(x, y) and x.primary_key == y.primary_key;
}

fn fkEql(x: ForeignKey, y: ForeignKey) bool {
    return listEql(x.columns, y.columns) and std.mem.eql(u8, x.ref_table, y.ref_table) and listEql(x.ref_columns, y.ref_columns) and x.on_delete == y.on_delete and x.on_update == y.on_update;
}

/// btree is the default, so naming it changes nothing.
fn usingOf(i: Index) ?[]const u8 {
    const u = i.using orelse return null;
    return if (std.ascii.eqlIgnoreCase(u, "btree")) null else u;
}

fn indexEql(x: Index, y: Index) bool {
    const ux = usingOf(x);
    const uy = usingOf(y);
    const using_same = if (ux == null or uy == null) ux == null and uy == null else std.ascii.eqlIgnoreCase(ux.?, uy.?);
    return listEql(x.columns, y.columns) and x.unique == y.unique and optEql(x.where, y.where) and using_same;
}

fn mapCols(a: Allocator, cols: []const []const u8, pairs: Pairs) ![]const []const u8 {
    const out = try a.alloc([]const u8, cols.len);
    for (cols, out) |c, *o| o.* = lookup(pairs, c) orelse c;
    return out;
}

/// A key as it reads after this diff's renames.
fn renamedFk(a: Allocator, f: ForeignKey, table: []const u8, renamed: Renamed) !ForeignKey {
    var out = f;
    out.columns = try mapCols(a, f.columns, renamed.of(table));
    out.ref_table = lookup(renamed.tables, f.ref_table) orelse f.ref_table;
    out.ref_columns = try mapCols(a, f.ref_columns, renamed.of(out.ref_table));
    return out;
}

fn keyOf(a: Allocator, t: Table) !KeyShape {
    if (t.primary_key) |pk| return .{ .name = pk.name orelse try std.fmt.allocPrint(a, "{s}_pkey", .{t.name}), .columns = pk.columns };
    var cols: std.ArrayList([]const u8) = .empty;
    for (t.columns) |c| if (c.primary_key) try cols.append(a, c.name);
    if (cols.items.len == 0) return .{};
    return .{ .name = try std.fmt.allocPrint(a, "{s}_pkey", .{t.name}), .columns = cols.items };
}

fn diffTable(a: Allocator, prev: Table, next: Table, changes: *std.ArrayList(Change), renamed: Renamed, dropped: []const []const u8) !void {
    const t = next.name;
    const renames = renamed.of(t);
    // The old column compared as the new one: a rename that changes the type
    // too is a rename plus an alter.
    var prev_cols: std.ArrayList(Column) = .empty;
    for (prev.columns) |c| {
        var x = c;
        if (lookup(renames, c.name)) |to| x.name = to;
        try prev_cols.append(a, x);
    }
    const before_t: Table = blk: {
        var x = prev;
        x.columns = prev_cols.items;
        break :blk x;
    };

    // Keys, indexes and checks that change or go are dropped before any column.
    for (prev.foreign_keys) |f| {
        if (contains(dropped, f.ref_table)) continue;
        const after = for (next.foreign_keys) |n| {
            if (std.mem.eql(u8, n.name, f.name)) break n;
        } else null;
        if (after == null or !fkEql(after.?, try renamedFk(a, f, t, renamed))) try changes.append(a, .{ .drop_foreign_key = .{ .table = t, .fk = f } });
    }
    for (prev.indexes) |i| {
        const after = for (next.indexes) |n| {
            if (std.mem.eql(u8, n.name, i.name)) break n;
        } else null;
        var was = i;
        was.columns = try mapCols(a, i.columns, renames);
        if (after == null or !indexEql(after.?, was)) try changes.append(a, .{ .drop_index = .{ .table = t, .index = i } });
    }
    for (prev.checks) |c| {
        const after = for (next.checks) |n| {
            if (std.mem.eql(u8, n.name, c.name)) break n;
        } else null;
        if (after == null or !std.mem.eql(u8, after.?.expression, c.expression)) try changes.append(a, .{ .drop_check = .{ .table = t, .check = c } });
    }

    for (renames) |r| try changes.append(a, .{ .rename_column = .{ .table = t, .from = r[0], .to = r[1] } });

    const kb = try keyOf(a, before_t);
    const ka = try keyOf(a, next);
    const key_changed = !optEql(kb.name, ka.name) or !listEql(kb.columns, ka.columns);
    if (key_changed and kb.columns.len > 0) try changes.append(a, .{ .alter_primary_key = .{ .table = t, .before = kb, .after = .{} } });

    for (prev.columns) |c| if (findColumn(next, c.name) == null and lookup(renames, c.name) == null)
        try changes.append(a, .{ .drop_column = .{ .table = t, .column = c } });
    for (next.columns) |c| if (findColumn(prev, c.name) == null and !isTarget(renames, c.name))
        try changes.append(a, .{ .add_column = .{ .table = t, .column = c } });
    for (next.columns) |c| {
        const before = for (prev_cols.items) |p| {
            if (std.mem.eql(u8, p.name, c.name)) break p;
        } else continue;
        if (!columnsEqual(before, c)) try changes.append(a, .{ .alter_column = .{ .table = t, .column = c.name, .before = before, .after = c } });
    }

    if (key_changed and ka.columns.len > 0) try changes.append(a, .{ .alter_primary_key = .{ .table = t, .before = .{}, .after = ka } });

    for (next.checks) |c| {
        const before = for (prev.checks) |p| {
            if (std.mem.eql(u8, p.name, c.name)) break p;
        } else null;
        if (before == null or !std.mem.eql(u8, before.?.expression, c.expression)) try changes.append(a, .{ .add_check = .{ .table = t, .check = c } });
    }
    for (next.indexes) |i| {
        const before = for (prev.indexes) |p| {
            if (std.mem.eql(u8, p.name, i.name)) break p;
        } else null;
        var same = false;
        if (before) |b| {
            var was = b;
            was.columns = try mapCols(a, b.columns, renames);
            same = indexEql(was, i);
        }
        if (!same) try changes.append(a, .{ .add_index = .{ .table = t, .index = i } });
    }
    for (next.foreign_keys) |f| {
        const before = for (prev.foreign_keys) |p| {
            if (std.mem.eql(u8, p.name, f.name)) break p;
        } else null;
        if (before == null or !fkEql(try renamedFk(a, before.?, t, renamed), f)) try changes.append(a, .{ .add_foreign_key = .{ .table = t, .fk = f } });
    }
}

/// The changes that undo `forward`, for down.sql.
pub fn invert(a: Allocator, forward: []const Change) ![]Change {
    var ordered: std.ArrayList(Change) = .empty;
    var i = forward.len;
    while (i > 0) {
        i -= 1;
        try ordered.append(a, switch (forward[i]) {
            .create_table => |t| .{ .drop_table = t },
            .drop_table => |t| .{ .create_table = t },
            .rename_table => |r| .{ .rename_table = .{ .from = r.to, .to = r.from } },
            .add_column => |c| .{ .drop_column = .{ .table = c.table, .column = c.column } },
            .drop_column => |c| .{ .add_column = .{ .table = c.table, .column = c.column } },
            .rename_column => |r| .{ .rename_column = .{ .table = r.table, .from = r.to, .to = r.from } },
            .alter_column => |c| .{ .alter_column = .{ .table = c.table, .column = c.column, .before = c.after, .after = c.before } },
            .add_index => |x| .{ .drop_index = .{ .table = x.table, .index = x.index } },
            .drop_index => |x| .{ .add_index = .{ .table = x.table, .index = x.index } },
            .add_foreign_key => |x| .{ .drop_foreign_key = .{ .table = x.table, .fk = x.fk } },
            .drop_foreign_key => |x| .{ .add_foreign_key = .{ .table = x.table, .fk = x.fk } },
            .create_enum => |e| .{ .drop_enum = e },
            .drop_enum => |e| .{ .create_enum = e },
            // No DROP VALUE: the down draft carries the forward change.
            .add_enum_value, .remove_enum_value => forward[i],
            .alter_primary_key => |k| .{ .alter_primary_key = .{ .table = k.table, .before = k.after, .after = k.before } },
            .add_check => |c| .{ .drop_check = .{ .table = c.table, .check = c.check } },
            .drop_check => |c| .{ .add_check = .{ .table = c.table, .check = c.check } },
        });
    }
    // DROP TABLE takes its keys, indexes and checks along; a recreated table
    // gets its keys back last, after every table exists.
    var dropped: std.ArrayList([]const u8) = .empty;
    for (ordered.items) |c| if (c == .drop_table) try dropped.append(a, c.drop_table.name);
    var out: std.ArrayList(Change) = .empty;
    for (ordered.items) |c| {
        const table = switch (c) {
            .drop_foreign_key => |x| x.table,
            .drop_index => |x| x.table,
            .drop_check => |x| x.table,
            else => null,
        };
        if (table) |tn| if (contains(dropped.items, tn)) continue;
        try out.append(a, c);
    }
    for (ordered.items) |c| if (c == .create_table) for (c.create_table.foreign_keys) |f|
        try out.append(a, .{ .add_foreign_key = .{ .table = c.create_table.name, .fk = f } });
    return out.items;
}

/// down.sql is a draft when it drops or alters what it can't fully restore.
pub fn hasAmbiguousReverse(forward: []const Change) bool {
    for (forward) |c| switch (c) {
        .drop_table, .drop_column, .alter_column, .add_enum_value, .remove_enum_value => return true,
        else => {},
    };
    return false;
}

pub const Candidates = struct {
    tables: []const struct { from: []const u8, to: []const []const u8 },
    columns: []const struct { table: []const u8, from: []const u8, to: []const []const u8 },
};

/// Drops that might be renames, each with what it could have become.
pub fn findRenameCandidates(a: Allocator, prev: Snapshot, next: Snapshot) !Candidates {
    var created: std.ArrayList([]const u8) = .empty;
    for (next.tables) |t| if (findTable(prev, t.name) == null) try created.append(a, t.name);
    var tables: std.ArrayList(@typeInfo(@FieldType(Candidates, "tables")).pointer.child) = .empty;
    if (created.items.len > 0) for (prev.tables) |t| if (findTable(next, t.name) == null)
        try tables.append(a, .{ .from = t.name, .to = created.items });
    var columns: std.ArrayList(@typeInfo(@FieldType(Candidates, "columns")).pointer.child) = .empty;
    for (next.tables) |after| {
        const before = findTable(prev, after.name) orelse continue;
        var added: std.ArrayList([]const u8) = .empty;
        for (after.columns) |c| if (findColumn(before, c.name) == null) try added.append(a, c.name);
        if (added.items.len == 0) continue;
        for (before.columns) |c| if (findColumn(after, c.name) == null)
            try columns.append(a, .{ .table = after.name, .from = c.name, .to = added.items });
    }
    return .{ .tables = tables.items, .columns = columns.items };
}

const testing = std.testing;

fn col(name: []const u8, sql_type: []const u8, nullable: bool, default: ?[]const u8) Column {
    return .{ .key = name, .name = name, .sql_type = sql_type, .nullable = nullable, .default = default, .default_sql = false, .primary_key = false };
}
const id_col: Column = .{ .key = "id", .name = "id", .sql_type = "serial", .nullable = false, .default = null, .default_sql = false, .primary_key = true };

fn tbl(name: []const u8, columns: []const Column) Table {
    return .{ .name = name, .columns = columns, .indexes = &.{}, .foreign_keys = &.{}, .checks = &.{}, .primary_key = null };
}

fn kinds(changes: []const Change) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (changes, 0..) |c, i| {
        if (i > 0) try buf.appendSlice(testing.allocator, " ");
        try buf.appendSlice(testing.allocator, @tagName(c));
    }
    return buf.toOwnedSlice(testing.allocator);
}

fn expectKinds(want: []const u8, changes: []const Change) !void {
    const got = try kinds(changes);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const users = tbl("users", &.{ id_col, col("email", "varchar(255)", false, null) });

test "diff: create and drop tables; same snapshot twice is no change" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one: Snapshot = .{ .tables = &.{users} };
    try testing.expectEqual(0, (try diff(a, .{}, .{}, .{})).len);
    try expectKinds("create_table", try diff(a, .{}, one, .{}));
    try expectKinds("drop_table", try diff(a, one, .{}, .{}));
    try testing.expectEqual(0, (try diff(a, one, one, .{})).len);
}

test "diff: columns added, dropped and altered; a lone drop+add of the same shape is a rename" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prev: Snapshot = .{ .tables = &.{users} };
    const added: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("email", "varchar(255)", false, null), col("age", "integer", true, null) })} };
    try expectKinds("add_column", try diff(a, prev, added, .{}));
    try expectKinds("drop_column", try diff(a, added, prev, .{}));
    const typed: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("email", "text", false, null) })} };
    const alter = try diff(a, prev, typed, .{});
    try expectKinds("alter_column", alter);
    try testing.expectEqualStrings("text", alter[0].alter_column.after.sql_type);
    const nullable: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("email", "varchar(255)", true, null) })} };
    try expectKinds("alter_column", try diff(a, prev, nullable, .{}));
    const defaulted: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("email", "varchar(255)", false, "x") })} };
    try expectKinds("alter_column", try diff(a, prev, defaulted, .{}));
    // One drop, one add, same attributes: a rename.
    const renamed: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("mail", "varchar(255)", false, null) })} };
    const r = try diff(a, prev, renamed, .{});
    try expectKinds("rename_column", r);
    try testing.expectEqualStrings("mail", r[0].rename_column.to);
    // Different types: drop + add.
    const other: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("mail", "text", false, null) })} };
    try expectKinds("drop_column add_column", try diff(a, prev, other, .{}));
    // Ambiguous (two adds): no guess.
    const two: Snapshot = .{ .tables = &.{tbl("users", &.{ id_col, col("a", "varchar(255)", false, null), col("b", "varchar(255)", false, null) })} };
    try expectKinds("drop_column add_column add_column", try diff(a, prev, two, .{}));
    // Told: a rename even when nothing would guess it; explicit turns guessing off.
    try expectKinds("rename_column alter_column", try diff(a, prev, other, .{ .columns = &.{.{ "users.email", "mail" }} }));
    try expectKinds("drop_column add_column", try diff(a, prev, renamed, .{ .explicit = true }));
    try testing.expectError(error.BadRename, diff(a, prev, renamed, .{ .columns = &.{.{ "users.nope", "mail" }} }));
}

test "diff: indexes and foreign keys; tables renamed by hint" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = tbl("posts", &.{ id_col, col("userId", "integer", false, null) });
    var with = posts;
    with.indexes = &.{.{ .name = "posts_user_idx", .columns = &.{"userId"}, .unique = false }};
    with.foreign_keys = &.{.{ .name = "posts_userId_fk", .columns = &.{"userId"}, .ref_table = "users", .ref_columns = &.{"id"}, .on_delete = .cascade, .on_update = .no_action }};
    const before: Snapshot = .{ .tables = &.{ users, posts } };
    const after: Snapshot = .{ .tables = &.{ users, with } };
    try expectKinds("add_index add_foreign_key", try diff(a, before, after, .{}));
    try expectKinds("drop_foreign_key drop_index", try diff(a, after, before, .{}));
    // A changed action drops and adds the key again.
    var cascade_less = with;
    cascade_less.foreign_keys = &.{.{ .name = "posts_userId_fk", .columns = &.{"userId"}, .ref_table = "users", .ref_columns = &.{"id"}, .on_delete = .no_action, .on_update = .no_action }};
    try expectKinds("drop_foreign_key add_foreign_key", try diff(a, after, .{ .tables = &.{ users, cascade_less } }, .{}));
    // New tables: every CREATE TABLE, then indexes, then keys.
    try expectKinds("create_table create_table add_index add_foreign_key", try diff(a, .{}, after, .{}));
    // Dropping a referenced table: children first.
    try expectKinds("drop_table drop_table", try diff(a, after, .{}, .{}));
    try testing.expectEqualStrings("posts", (try diff(a, after, .{}, .{}))[0].drop_table.name);
    // Renamed table by hint: a rename and only what else changed.
    var people = users;
    people.name = "people";
    try expectKinds("rename_table", try diff(a, .{ .tables = &.{users} }, .{ .tables = &.{people} }, .{ .tables = &.{.{ "users", "people" }} }));
    try expectKinds("drop_table create_table", try diff(a, .{ .tables = &.{users} }, .{ .tables = &.{people} }, .{}));
}

test "diff: enums created first, values added in place, removed by recreate, dropped last" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = tbl("t", &.{ id_col, col("role", "role", false, "'b'") });
    const v1: Snapshot = .{ .tables = &.{t}, .enums = &.{.{ .name = "role", .values = &.{ "a", "b" } }} };
    try expectKinds("create_enum create_table", try diff(a, .{}, v1, .{}));
    try expectKinds("drop_table drop_enum", try diff(a, v1, .{}, .{}));
    const v2: Snapshot = .{ .tables = &.{t}, .enums = &.{.{ .name = "role", .values = &.{ "z", "a", "m", "b" } }} };
    const added = try diff(a, v1, v2, .{});
    try expectKinds("add_enum_value add_enum_value", added);
    try testing.expectEqualStrings("a", added[0].add_enum_value.before.?);
    try testing.expectEqualStrings("b", added[1].add_enum_value.before.?);
    const v3: Snapshot = .{ .tables = &.{t}, .enums = &.{.{ .name = "role", .values = &.{"b"} }} };
    const removed = try diff(a, v1, v3, .{});
    try expectKinds("remove_enum_value", removed);
    try testing.expectEqualStrings("'b'", removed[0].remove_enum_value.affected[0].default.?);
    // The default can't point at a removed value.
    const v4: Snapshot = .{ .tables = &.{t}, .enums = &.{.{ .name = "role", .values = &.{"a"} }} };
    try testing.expectError(error.RemovedValueAsDefault, diff(a, v1, v4, .{}));
}

test "invert: each change reversed, in reverse order; drops inside dropped tables pruned; keys re-added last" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var posts = tbl("posts", &.{ id_col, col("userId", "integer", false, null) });
    posts.indexes = &.{.{ .name = "posts_user_idx", .columns = &.{"userId"}, .unique = false }};
    posts.foreign_keys = &.{.{ .name = "posts_userId_fk", .columns = &.{"userId"}, .ref_table = "users", .ref_columns = &.{"id"}, .on_delete = .cascade, .on_update = .no_action }};
    const s: Snapshot = .{ .tables = &.{ users, posts } };
    const up = try diff(a, .{}, s, .{});
    try expectKinds("drop_table drop_table", try invert(a, up));
    const down = try invert(a, try diff(a, s, .{}, .{}));
    try expectKinds("create_table create_table add_foreign_key", down);
    try testing.expectEqualStrings("users", down[0].create_table.name);
    const altered = try invert(a, try diff(a, .{ .tables = &.{users} }, .{ .tables = &.{tbl("users", &.{ id_col, col("email", "text", false, null) })} }, .{}));
    try testing.expectEqualStrings("varchar(255)", altered[0].alter_column.after.sql_type);
    try testing.expect(hasAmbiguousReverse(try diff(a, s, .{}, .{})));
    try testing.expect(!hasAmbiguousReverse(up));
}

test "rename candidates: dropped tables and columns something new could replace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var people = users;
    people.name = "people";
    const c = try findRenameCandidates(a, .{ .tables = &.{users} }, .{ .tables = &.{people} });
    try testing.expectEqualStrings("users", c.tables[0].from);
    try testing.expectEqualStrings("people", c.tables[0].to[0]);
    const cc = try findRenameCandidates(a, .{ .tables = &.{users} }, .{ .tables = &.{tbl("users", &.{ id_col, col("a", "text", true, null), col("b", "text", true, null) })} });
    try testing.expectEqualStrings("email", cc.columns[0].from);
    try testing.expectEqual(2, cc.columns[0].to.len);
}
