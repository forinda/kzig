//! kick/db's relational reads, `db.query.users.findMany({ with })`: a table
//! and its relations in one statement, nested rows as JSON (Postgres
//! `json_agg` / `to_json` over correlated subqueries), decoded into structs.
const std = @import("std");
const schema = @import("schema.zig");
const query = @import("query.zig");
const Timestamp = @import("timestamp.zig").Timestamp;

const Allocator = std.mem.Allocator;
const Writer = query.Writer;
const EnumLiteral = @TypeOf(.enum_literal);

pub fn Relational(comptime S: type, comptime tag: []const u8) type {
    return struct {
        conn: query.Conn,

        const Self = @This();

        /// What `findMany(…, opts)` returns a slice of.
        pub fn Row(comptime opts: anytype) type {
            return RowOf(S, tag, @TypeOf(opts));
        }

        pub fn findMany(self: Self, a: Allocator, opts: anytype) ![]RowOf(S, tag, @TypeOf(opts)) {
            return query.runRows(self.conn, a, RowOf(S, tag, @TypeOf(opts)), try self.toSql(a, opts, false));
        }

        pub fn findFirst(self: Self, a: Allocator, opts: anytype) !?RowOf(S, tag, @TypeOf(opts)) {
            const rows = try query.runRows(self.conn, a, RowOf(S, tag, @TypeOf(opts)), try self.toSql(a, opts, true));
            return if (rows.len > 0) rows[0] else null;
        }

        /// kick/db's `findUnique`: `findFirst` by a unique key.
        pub fn findUnique(self: Self, a: Allocator, opts: anytype) !?RowOf(S, tag, @TypeOf(opts)) {
            return self.findFirst(a, opts);
        }

        pub fn toSql(_: Self, a: Allocator, opts: anytype, comptime first: bool) !query.Sql {
            var w: Writer = .{ .a = a, .dialect = S.dialect };
            const alias = comptime aliasOf(S, tag, 0);
            try renderSelect(S, tag, 0, opts, &w);
            if (@hasField(@TypeOf(opts), "where")) {
                try w.raw(" WHERE ");
                try opts.where.render(scopeOf(S, tag, alias), &w);
            }
            try renderTail(S, tag, alias, opts, &w, if (first) 1 else null, false);
            return w.done();
        }
    };
}

fn aliasOf(comptime S: type, comptime tag: []const u8, comptime depth: usize) []const u8 {
    return std.fmt.comptimePrint("{s}_{d}", .{ S.info(@field(S.Tag, tag)).name, depth });
}

fn scopeOf(comptime S: type, comptime tag: []const u8, comptime alias: []const u8) query.Scope {
    return .{ .S = S, .from = tag, .qualify = true, .alias = alias };
}

/// A comptime field's value (struct literal fields with comptime values).
fn valueOf(comptime T: type, comptime field: []const u8) @FieldType(T, field) {
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_attrs) |n, attrs| if (std.mem.eql(u8, n, field))
        return attrs.defaultValue(@FieldType(T, field)) orelse @compileError("db: ." ++ field ++ " must be known at compile time");
    unreachable;
}

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// `.columns = .{ .id, .email }` picks; `.columns = .{ .secret = false }`
/// leaves out (kick/db: any `true` picks only those).
fn columnKeys(comptime S: type, comptime tag: []const u8, comptime Opts: type) []const []const u8 {
    comptime {
        const T = S.Table(@field(S.Tag, tag));
        const all = T.column_keys;
        if (!@hasField(Opts, "columns")) return all;
        const C = @FieldType(Opts, "columns");
        const names = @typeInfo(C).@"struct".field_names;
        var out: []const []const u8 = &.{};
        if (names.len > 0 and std.mem.eql(u8, names[0], "0")) {
            for (names) |n| {
                const k = @tagName(valueOf(C, n));
                if (!has(all, k)) @compileError(T.name_ ++ ": no column " ++ k);
                out = out ++ [_][]const u8{k};
            }
            return out;
        }
        var any_true = false;
        var any_false = false;
        for (names) |n| {
            if (!has(all, n)) @compileError(T.name_ ++ ": no column " ++ n);
            if (valueOf(C, n)) any_true = true else any_false = true;
        }
        if (any_true and any_false) @compileError(T.name_ ++ ": columns mixes true and false");
        for (all) |k| {
            const listed = has(names, k);
            const keep = if (any_true) listed and valueOf(C, k) else !(listed and !valueOf(C, k));
            if (keep) out = out ++ [_][]const u8{k};
        }
        if (out.len == 0) @compileError(T.name_ ++ ": columns leaves out every column");
        return out;
    }
}

fn relationOf(comptime S: type, comptime tag: []const u8, comptime name: []const u8) schema.RelationInfo {
    for (S.relationsOf(@field(S.Tag, tag))) |r| if (std.mem.eql(u8, r.name, name)) return r;
    @compileError(S.Table(@field(S.Tag, tag)).name_ ++ ": no relation " ++ name);
}

/// A relation's options: `true` is all columns, no nesting.
fn SubOpts(comptime W: type, comptime name: []const u8) type {
    const F = @FieldType(W, name);
    return if (F == bool) @TypeOf(.{}) else F;
}

/// Only `columns` and `with` shape a row: the same shape with or without
/// `where` is the same type.
fn RowOf(comptime S: type, comptime tag: []const u8, comptime Opts: type) type {
    return Shape(S, tag, if (@hasField(Opts, "columns")) @FieldType(Opts, "columns") else void, if (@hasField(Opts, "with")) @FieldType(Opts, "with") else void);
}

fn ShapeOpts(comptime C: type, comptime W: type) type {
    if (C == void and W == void) return @TypeOf(.{});
    if (C == void) return struct { with: W };
    if (W == void) return struct { columns: C };
    return struct { columns: C, with: W };
}

fn Shape(comptime S: type, comptime tag: []const u8, comptime C: type, comptime W0: type) type {
    const Opts = ShapeOpts(C, W0);
    comptime {
        const T = S.Table(@field(S.Tag, tag));
        const keys = columnKeys(S, tag, Opts);
        const W = if (@hasField(Opts, "with")) @FieldType(Opts, "with") else @TypeOf(.{});
        const rels = @typeInfo(W).@"struct".field_names;
        var names: [keys.len + rels.len][]const u8 = undefined;
        var types: [keys.len + rels.len]type = undefined;
        var attrs: [keys.len + rels.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (keys, 0..) |k, i| {
            names[i] = k;
            types[i] = @FieldType(T.Row, k);
            attrs[i] = .{};
        }
        for (rels, keys.len..) |rk, i| {
            const r = relationOf(S, tag, rk);
            const Child = RowOf(S, r.target_tag, SubOpts(W, rk));
            names[i] = rk;
            types[i] = if (r.kind == .one) ?Child else []const Child;
            attrs[i] = .{};
        }
        const n = names;
        const t = types;
        const at = attrs;
        return @Struct(.auto, null, &n, &t, &at);
    }
}

fn colName(comptime S: type, comptime tag: []const u8, comptime key: []const u8) []const u8 {
    for (S.info(@field(S.Tag, tag)).columns) |c| if (std.mem.eql(u8, c.key, key)) return c.name;
    @compileError(S.Table(@field(S.Tag, tag)).name_ ++ ": no column " ++ key);
}

const query_options: []const []const u8 = &.{ "columns", "where", "orderBy", "limit", "offset", "with" };

/// A misspelt option would read every row; it's a compile error instead.
fn checkOpts(comptime S: type, comptime tag: []const u8, comptime Opts: type) void {
    for (@typeInfo(Opts).@"struct".field_names) |f| if (!has(query_options, f))
        @compileError(S.Table(@field(S.Tag, tag)).name_ ++ ": no query option ." ++ f ++ " (columns, where, orderBy, limit, offset, with)");
}

/// `SELECT cols, (relations) FROM "table" AS "alias"`.
fn renderSelect(comptime S: type, comptime tag: []const u8, comptime depth: usize, opts: anytype, w: *Writer) !void {
    const Opts = @TypeOf(opts);
    comptime checkOpts(S, tag, Opts);
    const alias = comptime aliasOf(S, tag, depth);
    const keys = comptime columnKeys(S, tag, Opts);
    try w.raw("SELECT ");
    inline for (keys, 0..) |k, i| {
        if (i > 0) try w.raw(", ");
        try w.ident(alias);
        try w.raw(".");
        const name = comptime colName(S, tag, k);
        try w.ident(name);
        if (comptime !std.mem.eql(u8, name, k)) {
            try w.raw(" AS ");
            try w.ident(k);
        }
    }
    if (@hasField(Opts, "with")) {
        const W = @FieldType(Opts, "with");
        inline for (@typeInfo(W).@"struct".field_names) |rk| {
            const r = comptime relationOf(S, tag, rk);
            const sub = @field(opts.with, rk);
            try w.raw(", (");
            try renderRelation(S, tag, r, depth + 1, alias, if (@TypeOf(sub) == bool) .{} else sub, w);
            try w.raw(") AS ");
            try w.ident(rk);
        }
    }
    try w.raw(" FROM ");
    try w.ident(S.info(@field(S.Tag, tag)).name);
    try w.raw(" AS ");
    try w.ident(alias);
}

/// kysely's postgres `jsonArrayFrom` / `jsonObjectFrom`, correlated on the
/// relation's columns (through the junction for a many-through).
fn renderRelation(comptime S: type, comptime src_tag: []const u8, comptime r: schema.RelationInfo, comptime depth: usize, comptime parent: []const u8, opts: anytype, w: *Writer) !void {
    const child = comptime aliasOf(S, r.target_tag, depth);
    if (S.dialect == .sqlite) {
        // kysely's sqlite helpers, with nested relations wrapped in json() so
        // they stay JSON instead of becoming strings inside the object.
        const Opts = @TypeOf(opts);
        const t = if (r.kind == .many) "\"agg\"" else "\"obj\"";
        try w.raw(if (r.kind == .many) "SELECT coalesce(json_group_array(json_object(" else "SELECT json_object(");
        inline for (comptime columnKeys(S, r.target_tag, Opts), 0..) |k, i| {
            if (i > 0) try w.raw(", ");
            try w.raw("'" ++ k ++ "', " ++ t ++ ".");
            try w.ident(k);
        }
        if (@hasField(Opts, "with")) inline for (@typeInfo(@FieldType(Opts, "with")).@"struct".field_names) |rk| {
            try w.raw(", '" ++ rk ++ "', json(" ++ t ++ ".");
            try w.ident(rk);
            try w.raw(")");
        };
        try w.raw(if (r.kind == .many) ")), '[]') FROM (" else ") FROM (");
    } else try w.raw(if (r.kind == .many) "SELECT coalesce(json_agg(agg), '[]') FROM (" else "SELECT to_json(obj) FROM (");
    try renderSelect(S, r.target_tag, depth, opts, w);
    if (r.through) |th| {
        // kick/db: EXISTS, so a pair in the junction twice is one row.
        const j = child ++ "_j";
        try w.raw(" WHERE EXISTS (SELECT 1 FROM ");
        try w.ident(S.info(@field(S.Tag, th.table_tag)).name);
        try w.raw(" AS ");
        try w.ident(j);
        try w.raw(" WHERE ");
        inline for (th.target_columns, r.target_columns, 0..) |jc, tc, i| {
            if (i > 0) try w.raw(" AND ");
            try qcol(w, j, comptime colName(S, th.table_tag, jc));
            try w.raw(" = ");
            try qcol(w, child, comptime colName(S, r.target_tag, tc));
        }
        inline for (th.source_columns, r.source_columns) |jc, sc| {
            try w.raw(" AND ");
            try qcol(w, j, comptime colName(S, th.table_tag, jc));
            try w.raw(" = ");
            try qcol(w, parent, comptime colName(S, src_tag, sc));
        }
        try w.raw(")");
    } else {
        try w.raw(" WHERE ");
        inline for (r.target_columns, r.source_columns, 0..) |tc, sc, i| {
            if (i > 0) try w.raw(" AND ");
            try qcol(w, child, comptime colName(S, r.target_tag, tc));
            try w.raw(" = ");
            try qcol(w, parent, comptime colName(S, src_tag, sc));
        }
    }
    if (@hasField(@TypeOf(opts), "where")) {
        try w.raw(" AND ");
        try opts.where.render(scopeOf(S, r.target_tag, child), w);
    }
    // A one is one row, whatever limit it's given (kick/db's limit(1)).
    try renderTail(S, r.target_tag, child, opts, w, null, r.kind == .one);
    if (r.kind == .one) try w.raw(" LIMIT 1");
    if (S.dialect == .sqlite)
        try w.raw(if (r.kind == .many) ") AS \"agg\"" else ") AS \"obj\"")
    else
        try w.raw(if (r.kind == .many) ") AS agg" else ") AS obj");
}

fn qcol(w: *Writer, alias: []const u8, name: []const u8) !void {
    try w.ident(alias);
    try w.raw(".");
    try w.ident(name);
}

/// ORDER BY, LIMIT, OFFSET; `forced` (findFirst's 1) wins over the caller's `limit`.
fn renderTail(comptime S: type, comptime tag: []const u8, comptime alias: []const u8, opts: anytype, w: *Writer, forced: ?u64, comptime no_limit: bool) !void {
    const Opts = @TypeOf(opts);
    if (@hasField(Opts, "orderBy")) {
        const O = @FieldType(Opts, "orderBy");
        try w.raw(" ORDER BY ");
        if (O == EnumLiteral) {
            try qcol(w, alias, comptime colName(S, tag, @tagName(valueOf(Opts, "orderBy"))));
            try w.raw(" ASC");
        } else inline for (@typeInfo(O).@"struct".field_names, 0..) |f, i| {
            if (i > 0) try w.raw(", ");
            const item = comptime valueOf(O, f);
            try qcol(w, alias, comptime colName(S, tag, @tagName(item[0])));
            const desc = comptime item.len > 1 and blk: {
                const dir = @tagName(item[1]);
                if (!std.mem.eql(u8, dir, "asc") and !std.mem.eql(u8, dir, "desc"))
                    @compileError(S.Table(@field(S.Tag, tag)).name_ ++ ": orderBy direction is .asc or .desc, not ." ++ dir);
                break :blk std.mem.eql(u8, dir, "desc");
            };
            try w.raw(if (desc) " DESC" else " ASC");
        }
    }
    if (no_limit) {} else if (forced) |n| {
        try w.raw(" LIMIT ");
        try w.param(n);
    } else if (@hasField(Opts, "limit")) {
        try w.raw(" LIMIT ");
        try w.param(@as(u64, opts.limit));
    }
    if (@hasField(Opts, "offset")) {
        try w.raw(" OFFSET ");
        try w.param(@as(u64, opts.offset));
    }
}

const testing = std.testing;

const Role = enum {
    admin,
    member,
    pub const pg_name = "rq_role";
};
const users = schema.table("rq_users", .{
    .id = .{ .type = .serial, .primary_key = true },
    .name = .{ .type = .text, .not_null = true },
    .secret = .{ .type = .text },
    .role = .{ .type = .{ .@"enum" = Role }, .not_null = true, .default = .{ .value = "member" } },
    .joined = .{ .type = .timestamp, .not_null = true, .default = .now },
    .active = .{ .type = .boolean, .not_null = true, .default = .{ .value = "true" } },
}, .{});
const posts = schema.table("rq_posts", .{
    .id = .{ .type = .serial, .primary_key = true },
    .authorId = .{ .type = .integer, .not_null = true, .references = .{ .to = "rq_users.id" } },
    .parentId = .{ .type = .integer, .references = .{ .to = "rq_posts.id" } },
    .title = .{ .type = .text, .not_null = true },
}, .{});
const tags = schema.table("rq_tags", .{
    .id = .{ .type = .serial, .primary_key = true },
    .name = .{ .type = .text, .not_null = true },
}, .{});
const post_tags = schema.table("rq_post_tags", .{
    .postId = .{ .type = .integer, .not_null = true, .references = .{ .to = "rq_posts.id" } },
    .tagId = .{ .type = .integer, .not_null = true, .references = .{ .to = "rq_tags.id" } },
}, .{});
const test_relations = .{
    .users = .{ .posts = .{ .many = .posts } },
    .posts = .{
        .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id} },
        .parent = .{ .one = .posts, .fields = .{.parentId}, .references = .{.id} },
        .replies = .{ .many = .posts },
        .tags = .{ .many = .tags, .through = .post_tags },
    },
};
const test_tables = .{ .users = users, .posts = posts, .tags = tags, .post_tags = post_tags };
const TestSchema = schema.Schema(test_tables, .{ .relations = test_relations });
const LiteSchema = schema.Schema(test_tables, .{ .relations = test_relations, .dialect = .sqlite });

fn expectSql(q: anytype, opts: anytype, comptime first: bool, want: []const u8, params: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try q.toSql(arena.allocator(), opts, first);
    try testing.expectEqualStrings(want, got.sql);
    try testing.expectEqual(params.len, got.params.len);
    for (params, got.params) |p, g| try testing.expectEqualStrings(p, g.?);
}

const test_client: query.Client(TestSchema) = .{ .conn = undefined };

test "relational SQL: columns, nested many/one/through, correlation, where/order/limit, parameters in order" {
    try expectSql(test_client.query(.users), .{ .columns = .{.name}, .with = .{ .posts = .{ .columns = .{.title}, .orderBy = .id } } }, false,
        \\SELECT "rq_users_0"."name", (SELECT coalesce(json_agg(agg), '[]') FROM (SELECT "rq_posts_1"."title" FROM "rq_posts" AS "rq_posts_1" WHERE "rq_posts_1"."authorId" = "rq_users_0"."id" ORDER BY "rq_posts_1"."id" ASC) AS agg) AS "posts" FROM "rq_users" AS "rq_users_0"
    , &.{});
    try expectSql(test_client.query(.posts), .{
        .columns = .{.title},
        .where = query.eq(.title, "x"),
        .with = .{
            .author = .{ .columns = .{ .secret = false, .joined = false } },
            .tags = .{ .columns = .{.name}, .where = query.ne(.name, "y"), .limit = 2 },
            .parent = .{ .columns = .{.title}, .with = .{ .parent = .{ .columns = .{.id} } } },
        },
        .orderBy = .{.{ .id, .desc }},
        .limit = 10,
    }, true,
        \\SELECT "rq_posts_0"."title", (SELECT to_json(obj) FROM (SELECT "rq_users_1"."id", "rq_users_1"."name", "rq_users_1"."role", "rq_users_1"."active" FROM "rq_users" AS "rq_users_1" WHERE "rq_users_1"."id" = "rq_posts_0"."authorId" LIMIT 1) AS obj) AS "author", (SELECT coalesce(json_agg(agg), '[]') FROM (SELECT "rq_tags_1"."name" FROM "rq_tags" AS "rq_tags_1" WHERE EXISTS (SELECT 1 FROM "rq_post_tags" AS "rq_tags_1_j" WHERE "rq_tags_1_j"."tagId" = "rq_tags_1"."id" AND "rq_tags_1_j"."postId" = "rq_posts_0"."id") AND "rq_tags_1"."name" <> $1 LIMIT $2) AS agg) AS "tags", (SELECT to_json(obj) FROM (SELECT "rq_posts_1"."title", (SELECT to_json(obj) FROM (SELECT "rq_posts_2"."id" FROM "rq_posts" AS "rq_posts_2" WHERE "rq_posts_2"."id" = "rq_posts_1"."parentId" LIMIT 1) AS obj) AS "parent" FROM "rq_posts" AS "rq_posts_1" WHERE "rq_posts_1"."id" = "rq_posts_0"."parentId" LIMIT 1) AS obj) AS "parent" FROM "rq_posts" AS "rq_posts_0" WHERE "rq_posts_0"."title" = $3 ORDER BY "rq_posts_0"."id" DESC LIMIT $4
    , &.{ "y", "2", "x", "1" });
    // A one reads one row whatever limit it's given.
    try expectSql(test_client.query(.posts), .{ .columns = .{.id}, .with = .{ .author = .{ .columns = .{.id}, .limit = 5 } } }, false,
        \\SELECT "rq_posts_0"."id", (SELECT to_json(obj) FROM (SELECT "rq_users_1"."id" FROM "rq_users" AS "rq_users_1" WHERE "rq_users_1"."id" = "rq_posts_0"."authorId" LIMIT 1) AS obj) AS "author" FROM "rq_posts" AS "rq_posts_0"
    , &.{});
    // Row types: one is optional, many a slice; excluded columns are gone.
    const R = @TypeOf(test_client.query(.posts)).Row(.{ .columns = .{.title}, .with = .{ .author = .{ .columns = .{ .secret = false } }, .tags = true } });
    try testing.expect(@FieldType(R, "title") == []const u8);
    try testing.expect(!@hasField(@typeInfo(@FieldType(R, "author")).optional.child, "secret"));
    try testing.expect(@FieldType(@typeInfo(@FieldType(R, "author")).optional.child, "role") == Role);
    try testing.expect(@FieldType(R, "tags") == []const @TypeOf(test_client.query(.tags)).Row(.{}));
}

test "relational reads on Postgres: nested rows, null one, empty many, timestamps and enums inside" {
    var env: std.process.Environ.Map = undefined;
    const url = @import("db.zig").testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    const db_mod = @import("db.zig");
    var pool: db_mod.Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 1 });
    defer pool.deinit();
    try pool.execScript(
        \\DROP TABLE IF EXISTS rq_post_tags, rq_tags, rq_posts, rq_users; DROP TYPE IF EXISTS rq_role;
        \\CREATE TYPE rq_role AS ENUM ('admin', 'member');
        \\CREATE TABLE rq_users (id serial PRIMARY KEY, name text NOT NULL, secret text, role rq_role NOT NULL DEFAULT 'member', joined timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, active boolean NOT NULL DEFAULT true);
        \\CREATE TABLE rq_posts (id serial PRIMARY KEY, "authorId" integer NOT NULL REFERENCES rq_users(id), "parentId" integer REFERENCES rq_posts(id), title text NOT NULL);
        \\CREATE TABLE rq_tags (id serial PRIMARY KEY, name text NOT NULL);
        \\CREATE TABLE rq_post_tags ("postId" integer NOT NULL REFERENCES rq_posts(id), "tagId" integer NOT NULL REFERENCES rq_tags(id));
        \\INSERT INTO rq_users (name, secret, role, joined, active) VALUES ('Ada', 's1', 'admin', '2026-10-27 12:00:00.5', false), ('Linus', NULL, 'member', '2026-10-27 13:00:00', true);
        \\INSERT INTO rq_posts ("authorId", "parentId", title) VALUES (1, NULL, 'Hello'), (1, 1, 'Re: Hello');
        \\INSERT INTO rq_tags (name) VALUES ('intro'), ('sql');
        \\INSERT INTO rq_post_tags VALUES (1, 1), (1, 2), (1, 2);
    );
    defer pool.execScript("DROP TABLE IF EXISTS rq_post_tags, rq_tags, rq_posts, rq_users; DROP TYPE IF EXISTS rq_role;") catch {};
    try relationalSuite(TestSchema, &pool);
}

fn relationalSuite(comptime S: type, pool: *@import("db.zig").Pool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db: query.Client(S) = .init(.{ .pool = pool });

    const people = try db.query(.users).findMany(a, .{ .columns = .{ .secret = false }, .orderBy = .id, .with = .{ .posts = .{ .orderBy = .id, .with = .{ .tags = .{ .orderBy = .id } } } } });
    try testing.expectEqual(2, people.len);
    try testing.expectEqualStrings("Ada", people[0].name);
    try testing.expectEqual(Role.admin, people[0].role);
    try testing.expectEqual((try Timestamp.parse("2026-10-27 12:00:00.5")).us, people[0].joined.us);
    try testing.expectEqual(2, people[0].posts.len);
    try testing.expectEqualStrings("Hello", people[0].posts[0].title);
    try testing.expectEqualStrings("sql", people[0].posts[0].tags[1].name);
    try testing.expectEqual(0, people[0].posts[1].tags.len);
    try testing.expectEqual(0, people[1].posts.len);

    const reply = (try db.query(.posts).findFirst(a, .{ .where = query.eq(.title, "Re: Hello"), .with = .{ .parent = .{ .with = .{ .author = true } }, .author = .{ .columns = .{.name} } } })).?;
    try testing.expectEqualStrings("Hello", reply.parent.?.title);
    try testing.expectEqualStrings("Ada", reply.parent.?.author.?.name);
    // Timestamps, enums and booleans inside nested rows read as at the top.
    try testing.expectEqual((try Timestamp.parse("2026-10-27 12:00:00.5")).us, reply.parent.?.author.?.joined.us);
    try testing.expectEqual(Role.admin, reply.parent.?.author.?.role);
    try testing.expect(!reply.parent.?.author.?.active);
    try testing.expectEqual(null, reply.parent.?.parentId);
    const root = (try db.query(.posts).findFirst(a, .{ .where = query.eq(.id, 1), .with = .{ .parent = true, .replies = .{ .columns = .{.title} } } })).?;
    try testing.expectEqual(null, root.parent);
    try testing.expectEqualStrings("Re: Hello", root.replies[0].title);
    try testing.expectEqual(null, try db.query(.posts).findUnique(a, .{ .where = query.eq(.id, 99) }));
}

test "relational SQL on SQLite: json_group_array / json_object, nested JSON kept as JSON, ?n parameters" {
    const lite: query.Client(LiteSchema) = .{ .conn = undefined };
    try expectSql(lite.query(.users), .{ .columns = .{.name}, .with = .{ .posts = .{ .columns = .{.title}, .where = query.ne(.title, "x"), .with = .{ .author = .{ .columns = .{.id} } } } } }, true,
        \\SELECT "rq_users_0"."name", (SELECT coalesce(json_group_array(json_object('title', "agg"."title", 'author', json("agg"."author"))), '[]') FROM (SELECT "rq_posts_1"."title", (SELECT json_object('id', "obj"."id") FROM (SELECT "rq_users_2"."id" FROM "rq_users" AS "rq_users_2" WHERE "rq_users_2"."id" = "rq_posts_1"."authorId" LIMIT 1) AS "obj") AS "author" FROM "rq_posts" AS "rq_posts_1" WHERE "rq_posts_1"."authorId" = "rq_users_0"."id" AND "rq_posts_1"."title" <> ?1) AS "agg") AS "posts" FROM "rq_users" AS "rq_users_0" LIMIT ?2
    , &.{ "x", "1" });
}

test "relational reads on SQLite" {
    if (!@import("kzig_options").sqlite) return error.SkipZigTest;
    var pool: @import("db.zig").Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    try pool.execScript(
        \\CREATE TABLE rq_users (id integer PRIMARY KEY, name text NOT NULL, secret text, role text NOT NULL DEFAULT 'member', joined text NOT NULL, active integer NOT NULL DEFAULT 1);
        \\CREATE TABLE rq_posts (id integer PRIMARY KEY, "authorId" integer NOT NULL REFERENCES rq_users(id), "parentId" integer REFERENCES rq_posts(id), title text NOT NULL);
        \\CREATE TABLE rq_tags (id integer PRIMARY KEY, name text NOT NULL);
        \\CREATE TABLE rq_post_tags ("postId" integer NOT NULL REFERENCES rq_posts(id), "tagId" integer NOT NULL REFERENCES rq_tags(id));
        \\INSERT INTO rq_users (name, secret, role, joined, active) VALUES ('Ada', 's1', 'admin', '2026-10-27 12:00:00.500', 0), ('Linus', NULL, 'member', '2026-10-27 13:00:00.000', 1);
        \\INSERT INTO rq_posts ("authorId", "parentId", title) VALUES (1, NULL, 'Hello'), (1, 1, 'Re: Hello');
        \\INSERT INTO rq_tags (name) VALUES ('intro'), ('sql');
        \\INSERT INTO rq_post_tags VALUES (1, 1), (1, 2), (1, 2);
    );
    try relationalSuite(LiteSchema, &pool);
}
