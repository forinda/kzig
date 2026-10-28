# 7. Production

```console
$ kzig build                 # zig build -Doptimize=ReleaseSafe
Built zig-out/bin/. Run it with `kzig start`.
$ API_KEY=… MIGRATE_ON_BOOT=true kzig start
info: migration 20261028_024358_init applied
info: listening on http://127.0.0.1:3000
```

`kzig start` runs the built binary with `NODE_ENV=production` and replaces itself with it, so a
supervisor's signals reach the app. The binary is all you deploy, with `db/migrations` beside it.

## Settings

| Variable | Default | |
| --- | --- | --- |
| `PORT` | `3000` | |
| `HOST` | `127.0.0.1` | `0.0.0.0` to accept connections from other machines (chapter 8 adds it) |
| `NODE_ENV` | `development` | `production` turns off development defaults |
| `API_KEY` | none in production | at least 32 characters |
| `DB_FILE` | `data/bookmarks.db` | its folder is created |
| `MIGRATIONS_DIR` | `db/migrations` | |
| `MIGRATE_ON_BOOT` | `false` | `true` applies pending migrations at start; otherwise a pending one stops the boot |
| `API_KEY_FILE`, … | | any setting can be read from a file instead (`<NAME>_FILE`), for secrets |

A missing or invalid setting stops the boot with every problem listed, not the first request.

## Stopping

On `SIGTERM` or `SIGINT` the app stops accepting connections, lets requests in flight finish
(up to 30 s), closes idle connections, then runs each adapter's `shutdown` and each service's
`deinit` in reverse order. `/health/ready` answers `draining` meanwhile, so a load balancer
stops sending traffic.

Next, [Docker](docker.md).
