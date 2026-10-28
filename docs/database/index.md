# Database: Postgres

kick/db on Postgres: `kzig.db.Pool` speaks the Postgres protocol itself (no libpq), with
SCRAM-SHA-256 auth, parameters and rows decoded into structs by column name.

```zig
var pool: kzig.db.Pool = try .init(io, gpa, .{ .url = "postgres://app:secret@localhost/app" });
defer pool.deinit();
const users = try pool.query(arena, User, "SELECT id, email FROM users WHERE active = $1", .{true});
const one = try pool.queryOne(arena, User, "SELECT id, email FROM users WHERE id = $1", .{id}); // ?User
var tx = try pool.begin();
defer tx.deinit(); // rolls back unless committed
_ = try tx.exec("UPDATE users SET active = false WHERE id = $1", .{id});
try tx.commit();
```

Arguments are ints, floats, bools, strings, enums (by name) and optionals (NULL). A unique
violation is `error.Conflict` (409); a server that can't be reached is `error.ServiceUnavailable`
(503).

TLS follows libpq's `sslmode` in the URL: `prefer` (the default) encrypts when the server
offers it, `require` insists, `verify-ca` also checks the certificate chain and `verify-full` the
host name too, against `sslrootcert=/path/ca.pem` or the system's CAs; `disable` stays in the
clear. As in libpq, `require` with an `sslrootcert` checks the chain; unlike it, `verify-ca`
against the system's CAs checks the host name too, since any public certificate would pass
otherwise. SNI names the host in every mode.

More of libpq's options:

- `sslnegotiation=direct` (Postgres 17): TLS from the first byte, without the SSLRequest round
  trip; needs `sslmode=require` or stronger.
- `channel_binding=prefer` (default) signs in with SCRAM-SHA-256-PLUS over TLS when the server
  offers it, tying the sign-in to the server's certificate; `require` refuses anything else,
  `disable` turns it off.
- `sslcert=client.pem&sslkey=client.key`: a client certificate for a server that authenticates
  by certificate (pg_hba `cert`), over TLS 1.3 or 1.2. Keys: EC P-256/P-384 (SEC1 or PKCS#8), RSA
  (PKCS#1 or PKCS#8; RSA-PSS, or PKCS#1 v1.5 for a TLS 1.2 server without PSS; blinded) or Ed25519
  (PKCS#8, TLS 1.3). An encrypted key (PKCS#8 PBES2 with PBKDF2 or scrypt, or OpenSSL's `DEK-Info`
  PEM; AES or 3DES) takes `sslpassword=`. A key that isn't the certificate's is refused before
  connecting.
- `sslcrl=crl.pem`: revocation lists (PEM or DER), each verified against its CA in
  `sslrootcert`; a server certificate they list is refused, and so is one whose issuer has no CRL
  there (as libpq). A lapsed, not-yet-valid or unverifiable CRL, or one with a critical extension
  (indirect, delta), is a configuration error.

Passwords: SCRAM (Postgres's default) never sends one. A server asking for a cleartext or MD5
password gets one only over verified TLS (`verify-ca`/`verify-full`); for an old server on a
trusted network, `insecure_auth=true` allows it.

```text
postgres://app:secret@db.example.com/app?sslmode=verify-full&sslrootcert=/etc/ssl/db-ca.pem
```

### Schema and queries

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

### Relations

Relations shape reads only (they emit no DDL): declare them with the schema, and
`client.query(.t)` reads a table and its relations in one statement.

```zig
pub const Schema = kzig.db.Schema(.{ .users = users, .posts = posts, .tags = tags, .post_tags = post_tags }, .{ .relations = .{
    .users = .{ .posts = .{ .many = .posts } }, // joined by the one back, or posts' key to users
    .posts = .{
        .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id} },
        .tags = .{ .many = .tags, .through = .post_tags },
    },
} });

const user = try db.query(.users).findFirst(arena, .{
    .where = kzig.db.eq(.id, id),
    .columns = .{ .passwordHash = false },
    .with = .{ .posts = .{ .orderBy = .{ .{ .createdAt, .desc } }, .limit = 10, .with = .{ .tags = true } } },
});
// user.?.posts[0].tags[0].name — a `one` reads as `?T`, a `many` as `[]const T`
```

`many` finds its join as kick/db does: the `one` back with the same `relation_name`, else the
only untagged one back, else the target's single foreign key; two keys to the same table need a
`relation_name` on each side. A wrong relation name or column is a compile error. The relations
go into `snapshot.json` as kick/db's sidecar. task-api's `workspaces` module reads a workspace
with its owner, members (with their users) and projects this way.

Migrations use kick/db's layout — `db/migrations/<YYYYMMDD_HHMMSS>_<name>/` with `up.sql`,
`down.sql`, `snapshot.json` and `meta.json`, plus `_journal.json` — and its `kick_migrations`
table, so a kick/db app and a kzig app can share a folder and a database.
`kzig db generate` writes them from a schema. The schema belongs to the database's adapter, so
an app with two databases (Postgres and an analytics Postgres, or Postgres beside Mongo, which
has none) keeps them apart:

```zig
pub const DbAdapter = struct {
    pub const db_name = "postgres";
    pub const db_schema = @import("../db/schema.zig").Schema;
    // beforeStart, onHealthCheck, … as usual
};
```

It diffs that schema against the latest `snapshot.json` (written byte for byte as kick/db
writes it); with more than one database, name it with `--db`.

```console
$ kzig db generate add_avatar   # builds the app, diffs, writes up/down SQL and the snapshot
$ kzig db generate rename --rename-column users.email=mail --rename-table teams=groups
$ kzig db generate seed --empty # SQL to write by hand; the snapshot carries over
$ kzig db check                 # CI: fails when the schema has changes no migration holds
$ kzig db generate add_events --db analytics --dir db/analytics
$ kzig db migrate               # DATABASE_URL; also: rollback (last batch), status
$ kzig db new backfill          # an empty up/down pair, without a snapshot
```

A dropped column or table that something new could replace is asked about at a terminal
(Enter keeps it a drop); without one, the output says which `--rename-…` flag would keep it.
A down.sql that drops or alters what it can't restore starts with a `-- DRAFT` line.
`kzig.db.migrate.onBoot` applies pending migrations (or, with `.fail_if_pending`, refuses to
start).

task-api's `users` module and `DbAdapter` show the whole setup: migrations on boot in
development, `postgres` on `/health/ready`, and 503s when `DATABASE_URL` isn't set.

### SQLite

The same schema, builder, relations and migrations on SQLite: give the schema
`.dialect = .sqlite` and the pool a `sqlite:` URL. Local files need SQLite's C library, which
kzig fetches and builds only with `-Dsqlite` (the default build stays C-free).

```zig
pub const Schema = kzig.db.Schema(.{ .projects = projects, .tenants = tenants }, .{ .dialect = .sqlite });
var pool: kzig.db.Pool = try .init(io, gpa, .{ .url = "sqlite:data/app.db" }); // or sqlite::memory:
```

```console
$ zig build test -Dsqlite
```

Values are stored as kick/db stores them there: timestamps as `YYYY-MM-DD HH:MM:SS.SSS` UTC
text, booleans as 1/0, enums as text; `ilike` is SQLite's `LIKE` (case-insensitive for ASCII).
`kzig db generate` writes kick/db's SQLite DDL, with its table rebuild for changes SQLite can't
`ALTER`; `kzig db migrate` runs each migration with foreign keys off and checks them before it
commits, so rebuilding a table others reference keeps their rows. A file has one connection;
writers wait for each other (5 s busy timeout) instead of failing.

task-api's `projects` module and `TenantDbAdapter` run on SQLite with multi-tenant-kickdb-api's
schema and migrations, beside the Postgres `DbAdapter`.

Hosted SQLite needs no C: the pool speaks HTTP.

```text
libsql://my-db-me.turso.io?authToken=…            Turso (Hrana over HTTP); http://127.0.0.1:8080 for a local sqld
d1://<account id>/<database id>?token=…           Cloudflare D1 (its REST API, an API token with D1 Edit)
```

On Turso a transaction is one Hrana stream, so `begin`/`commit` and migrations work as on a
file. D1 has no interactive transactions: `begin` is `error.TransactionsUnsupported`,
`pool.batch(&.{ … })` runs statements as one, and each migration goes as one batch (its
statements, its record, a foreign-key check). D1 keeps foreign keys on, so a migration that
rebuilds or drops a table others reference is refused before it runs (`error.RebuildOfReferencedTable`).
D1 binds at most 100 parameters per statement (`error.TooManyParameters`); `db.insertMany(a,
.items, rows, .{})` splits rows to fit (on any database: Postgres 65,535, SQLite 32,766) and runs
the statements as one transaction, or one batch on D1. Turso and D1 requests time out after
`request_timeout_ms` (30 s) of silence.
