# Migrations

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
