# SQLite, Turso and D1

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
