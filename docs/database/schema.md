# Schema and queries

kick/db's code-first layer: tables are Zig struct literals, queries keep kick/db's shape, and a
wrong column, a value of the wrong type or a reference to a missing table is a compile error.

```zig
pub const GlobalRole = enum { superadmin, user, pub const pg_name = "global_role"; };

pub const users = kzig.db.table("users", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .email = .{ .type = .{ .varchar = 255 }, .not_null = true, .unique = true },
    .globalRole = .{ .type = .{ .@"enum" = GlobalRole }, .not_null = true, .default = .{ .value = "user" } },
    .teamId = .{ .type = .uuid, .references = .{ .to = "teams.id", .on_delete = .cascade } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{ .indexes = .{ .emailIdx = .{ .name = "users_email_idx", .on = .{.email} } } });

pub const Schema = kzig.db.Schema(.{ .users = users, .teams = teams }, .{});

const db: kzig.db.Client(Schema) = .init(.{ .pool = &pool }); // or .{ .tx = &tx }
const admins = try db.selectFrom(.users).select(.{ .id, .email })
    .where(.globalRole, .eq, .superadmin).orderBy(.createdAt, .desc).limit(20).execute(arena);
const user = try db.insertInto(.users).values(.{ .email = "a@b.c" }).returningAll().executeTakeFirstOrThrow(arena);
_ = try db.updateTable(.users).set(.{ .email = "b@b.c" }).where(.id, .eq, user.id).execute(arena);
const found = try db.selectFrom(.users).whereExpr(kzig.db.any(.{ kzig.db.isNull(.teamId), kzig.db.eq(.teamId, team_id) })).execute(arena);
const row = try db.upsert(arena, .users, .{ .email = "a@b.c" }, .{ .target = .{.email} });
const team = try db.findOrCreate(arena, .teams, .{ .name = "core" }, .{ .color = "red" }); // .row, .created
```

Each table has `Row`, `Insert` (defaulted and nullable columns optional) and `Update` types.
Timestamps read into `kzig.db.Timestamp` (ISO 8601 in JSON), json columns into `std.json.Value`,
enums into the Zig enum. Joins (`innerJoin`, `leftJoin`; left-joined columns are optional),
`count`, `inArray`, `between`, `like` with `escapeLike`, `exists` and `db.sql(…)` are there too;
`executeTakeFirstOrThrow` with no row is a 404. `and`/`or` are Zig keywords, so kick/db's helpers
are `db.all` and `db.any`.
