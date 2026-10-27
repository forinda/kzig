# kzig roadmap

kzig is [KickJS](https://github.com/forinda/kick-js) in Zig: the same modules, controllers,
services, middleware, context contributors, adapters, boot order and request pipeline, built on
`comptime` instead of decorators and runtime metadata. Requires **Zig 0.17.0**.

The bar for "done" is the [examples archive](https://github.com/forinda/kickjs-examples-archive):
its apps' behaviour and tests are ported, module by module, into one example app,
[`examples/task-api`](./examples/task-api), which grows with each milestone. Files keep KickJS's
layout (`hello.module.zig`, `hello.controller.zig`, …).

Engines: the standard library (`std.http.Server` on `std.Io`) is the default and the reference;
[http.zig](https://github.com/karlseguin/http.zig) is optional (`-Dhttpz`); anything else is decided
after M6.

## Principles

- **Same flow as KickJS.** Boot phases, hook names, middleware phases, contributor precedence
  (method > class > module > adapter > global), `/api/v1` mounting, RFC 9457 problem bodies.
  A KickJS user should recognise every file.
- **Compile errors over boot errors.** A missing service, an unknown handler, a contributor cycle
  or a handler reading a value no contributor on its route sets fails `zig build`, not the first
  request.
- **Explicit over global.** Modules are listed, not discovered by import side effects. No global
  container, no `Container.reset()`.
- **Engine-neutral.** User code talks to `Ctx`, never to the engine. Every runtime runs the same
  test suite.
- **Safe at the edge.** Body size, header size, timeouts, connection limits and path
  normalisation are framework defaults, not app code.

## Where KickJS and kzig differ on purpose

| KickJS | kzig | Why |
| --- | --- | --- |
| Decorators + `reflect-metadata` | `pub const routes = .{ … }` tuples, `@typeInfo` | Zig has no decorators; comptime does the same work earlier |
| Global container, import-time registration | Modules listed in `App(.{ .modules })`, wired at comptime | Removes "No provider for X" and test resets |
| DI cycles found at resolve time | Found at compile time | `container.bootstrap()` is a no-op in KickJS |
| `ctx.get('key')` untyped, fails open | `got: struct { tenant: Tenant }` handler parameter, checked against the route's contributors | A dropped contributor is a compile error |
| `dependsOn: ['user']` | read `user` in `resolve`'s `got` parameter | The dependency and its type are one declaration |
| `AsyncLocalStorage` request store | `*Ctx` passed explicitly, request arena | No hidden state |
| `throw new HttpException(422, details)` | `return ctx.fail(.unprocessable_entity, details)` | Zig errors carry no payload; details live on `ctx` |
| Adapter `shutdown` run concurrently | Run in reverse mount order | A DB adapter must outlive the adapters that use it |
| Services built lazily; adapters register them in `beforeMount` | Services (and their `init` hooks) are built before `beforeMount` | DI is resolved at comptime; a service owns its own setup |
| Request-scoped services, `@PreDestroy` | A contributor with `dispose(self, *V)` | The request scope is the contributor store; no ALS |
| Transient scope | Not ported | Construct a value |
| Plugins with `register`/`onReady` | Plugins are bundles; hooks live on their adapters | One lifecycle mechanism |
| `kick g module` folders not pluralized by default | `kzig g module task` writes `src/modules/tasks` | Matches the archive apps' layout; `rm module` finds either |
| Typegen, Vite HMR | None; `zig build --watch` | Zig types are already the source of truth |
| Swagger from zod schemas + decorators | OpenAPI from the Zig types, at comptime | The schema can't drift from the code |
| Swagger operations untagged without `@ApiTags` | Tagged with the module's name | Swagger UI groups by module |
| `@FileUpload({ maxSize: getEnv(…) })` | `kzig.Upload(.{ .max_size })` is comptime; a limit from env is checked in the handler | Route types are built at compile time |
| `..%2F` in a path reaches validation (422) | 400 at the router | Traversal never reaches a handler |
| `@WsController('/chat')`, `@OnMessage('event')`, `WsAdapter({ auth: { resolveUser } })` | A gateway struct in `.gateways` with `pub const events`; auth in `connect` (`ctx.close(4401, …)`) | One hook instead of an adapter option; nothing runs before `connect` |
| `ctx.data` untyped | The handler's `data` parameter is decoded (an `error` event lists the issues) | Same rules as request bodies |
| `WsAdapter({ heartbeatInterval })` from env | `.ws = .{ .heartbeat_ms }` in the App spec | The App spec is comptime |
| `@Cron(…, { enabled: () => … })` per job | `pub fn cronEnabled(self, name) bool` on the service | One hook sees the service's settings |
| `KickCronAdapter({ enabled })` | Built in; `CRON_ENABLED` | Jobs need no adapter to be found |
| `onError(err, { source: 'cron' })` | `onCronError(err, info)` | A job has no request; the info is typed |
| The serverless `/_kick/cron/:scheduleId` trigger | Not ported | kzig runs as a server |
| `S3Settings` requires `S3_BUCKET` | Every `S3_*` field optional; `S3.fromSettings` names the missing one when S3 is chosen | Settings are listed at comptime, and a disk app must boot without them |
| Streams, ranges, multipart uploads, upload forms, `compose`, tus, credential providers | Not ported: whole bodies, fixed keys | file-storage-api needs none of them |
| Disk `put` under a file (`a.txt/b`): ENOTDIR, a 500 | `error.InvalidKey` (400) | The key can't name a file there; a client can fix it |
| `kick db generate` loads the schema module | `kzig db generate` builds the app and runs it with `KZIG_DB_SNAPSHOT=<db>`; each database adapter brings its schema (`db_name`, `db_schema`) | Zig can't load source at run time; one app can hold several databases |
| Removing an enum value whose column defaults to it bare (`user`): no error, and `SET DEFAULT user::…` (CURRENT_USER) | `error.RemovedValueAsDefault`, and the restored default quoted | kick/db only reads quoted defaults; the schema writes bare ones |
| `-- Generated by @forinda/kickjs-db v…` | `-- Generated by kzig v…` | Same files otherwise; the banner says who wrote them |
| `relations(users, ({ many }) => …)` exports | `.relations = .{ .users = .{ .posts = .{ .many = .posts } } }` in `Schema`'s options | One declaration, checked at comptime |
| A malformed `:id` reaches Postgres (22P02, a 500) | 422 from the route's UUID check | The client can fix it; the database never sees it |
| `db.query.users.findMany({ where: (u, eb) => … })` | `client.query(.users).findMany(arena, .{ .where = db.eq(.id, x) })` | The builder's condition helpers |
| `uuid().primaryKey()` builder chains | `.{ .type = .uuid, .primary_key = true }` struct literals | Plain Zig; a misspelt option is a compile error |
| `references(() => t.id)` | `.references = .{ .to = "t.id" }`, checked when the schema is assembled | A Zig table can't name itself in its own initializer |
| `pgEnum('role', …)` | A Zig enum with `pub const pg_name` | The enum is the row field's type |
| `and()` / `or()` | `db.all` / `db.any`; `where(col, op, v)` and `whereExpr(e)` | Keywords; no overloading |
| `upsert` of many rows, `sql` updates, a partial-index `where` | One row; `.update` is `.all`, `.none` or columns | Not needed yet |
| An insert's `{ age: null }` writes NULL | A null field is left out (the column's default) | `Insert` fields are optionals; null can't mean both |
| `set({ x: null })` | `Update` fields are `??T`: null leaves a column, `@as(?T, null)` sets NULL | Same reason |
| `executeTakeFirstOrThrow` without a row: a 500 | `error.NotFound`, a 404 | The usual meaning of "no such row" in a handler |
| `pg` driver | A Postgres client in Zig, TLS from `std.crypto.tls` | No dependency |
| libpq sends a cleartext or MD5 password whenever the server asks | Only over verified TLS (`verify-ca`/`verify-full`), else `error.InsecureAuth`; `insecure_auth=true` for old servers | A man in the middle can ask for either |
| `verify-ca` against `sslrootcert=system` is refused by libpq | `verify-ca` without `sslrootcert` checks the host too (verify-full) | The system's CAs vouch for anyone's certificate |
| `sslmode=allow` tries plaintext first | Treated as `prefer` (TLS first) | Encrypt when possible |
| libpq links OpenSSL | std's TLS client, vendored with what Postgres needs | No C dependency |
| kysely's SQLite compiler writes `ILIKE` (a syntax error there) | `ilike` is `LIKE` on SQLite | SQLite's LIKE already ignores ASCII case |
| A cell missing from a multi-row insert is NULL on SQLite (kysely) | The column's default | SQLite has no `DEFAULT` in `VALUES`; NULL loses the default |
| Nested relation rows are JSON strings, re-parsed by a plugin | `json()` around them: real nested JSON | No guessing which strings were JSON |
| A table rebuild of a referenced table is out of scope | Migrations run with foreign keys off, checked before commit | SQLite's own ALTER TABLE procedure; the rebuild would cascade |
| A DB adapter always reports health | `onHealthCheck` may return null; no database configured, nothing on `/health/ready` | task-api runs without a database |

Kept for parity even where Zig would allow otherwise: route middleware runs **after** validation.

## Milestones

Each milestone ends with tests passing (`zig build test`, no leaks under
`std.testing.allocator`) and `zig fmt --check` clean.

### M0 — Foundation

- [x] Clean `build.zig`: the `kzig` module and `test` step
- [x] `CLAUDE.md`, `CONTRIBUTING.md`, this roadmap
- [x] CI: `zig build test` and `zig fmt --check` on Linux and macOS

### M1 — Core runtime on `std`

- [x] Engine-neutral `Request` / `Response` views; `Ctx` with `params`, `query`, `header`,
      `json`, `text`, `status`, `setHeader`, `noContent`, `created`
- [x] Return-value handlers: a value is 200 JSON, `void` is 204, a type with `sendResponse`
      sends itself
- [x] Router: `:params`, trailing `*`, percent-decoded and normalised paths, 404, 405 with `Allow`
- [x] Problem bodies (`application/problem+json`): error-set → status mapping, `ctx.fail`,
      request id on a 500, details hidden in release builds
- [x] `std` runtime: listener, one task per connection on `Io.Group` (`concurrent`, since
      `async` may run a connection inline and stall accepting), connection cap, keep-alive,
      one arena per connection reset per request
- [x] Limits: max body (413), max header bytes (431), head and body timeouts (per-connection
      watchdog), connection cap
- [x] `kzig.testing`: an in-process runtime that drives the full pipeline without a socket

Follow-ups:

- [ ] `Expect` other than `100-continue` answers 417 instead of closing
- [ ] A malformed chunked body answers 400 instead of closing silently
- [ ] Close the connection when the watchdog task can't be started
- [ ] Arena reset per request keeps at most a bounded capacity
- [ ] Absolute-form request targets (`GET http://host/x`)
- [ ] `Ctx.setHeader` rejects CR/LF and `:` instead of the runtime dropping them
- [ ] Testing runtime matches the server for HEAD and body limits
- [x] Null optional fields in user JSON are sent (KickJS `res.json`); framework bodies omit them

### M2 — Modules and comptime DI

- [x] `kzig.Module(.{ .name, .path, .version, .prefix, .controllers, .services })`; `.version`
      is a number or `false`, as in KickJS
- [x] `kzig.App(.{ .modules, .config, .api_prefix })` flattening modules into one route table
- [x] Singletons by `*Dep` field type; `init` hooks in dependency order; `deinit` in reverse;
      rollback when an `init` fails part way
- [x] Compile errors: missing service, unknown handler, duplicate route, dependency cycle
- [x] Test overrides (`app.initWith(io, gpa, env, .{FakeRepo{ … }})`), allowed only in test builds
- [x] Config: a struct with defaults, filled from env at boot, every bad key reported at once
- [x] Built-in health module (`/health/live`, `/health/ready`)
- [x] `examples` build step; example tests run under `zig build test`
- [x] **Acceptance:** `minimal-api` ported with its three tests (now the hello module of
      `examples/task-api`)

Follow-ups:

- [ ] Clear compile errors for `pub const init: S = .{}`, non-function handlers, handlers
      without `self`, and non-`pub` handlers
- [ ] `App.routes` usable outside `App.handle` (thunks assume `ctx.app`)
- [x] A `Config` override in tests skips reading env
- [x] Config parsing rejects `1_000`, `inf`, `nan`; bools case-insensitive
- [ ] Document: don't call `deinit` after a failed `init`

### M3 — Middleware and contributors

- [x] Middleware `fn (*Ctx, *Next) !void` with `next.run()`, so it can wrap the handler; a
      service struct with `handle` gets DI
- [x] Global (App), controller and route middleware; global runs for unmatched requests too
- [x] Contributors: `key`, `before_validation`, `optional`, DI deps; dependencies read through
      `got`; precedence (method > controller > module > global) and comptime topo sort
- [x] Typed contributor values per route via the handler's `got` parameter
- [x] Built-ins: `requestId`, `requestLogger`, `cors`, `helmet`
- [x] **Acceptance:** `multi-tenant-kickdb-api`'s auth → tenant →
      handler flow, in memory

Follow-ups:

- [ ] Contributor `skipWhen` / `onlyWhen` route flags and `onError` replacement values
- [ ] Contributor params (`LoadAuthUser({ on401: 'allow' })`)
- [ ] Clear compile errors for middleware with the wrong signature and a non-struct `got`
- [ ] `requestId` reuses an id set earlier in the chain; works without `ctx.io`
- [ ] Decide whether global contributors apply to `/health/*`

### M4 — Validation and bodies

- [x] Typed `body`, `query` and `params`, read through `got` and decoded with every field error
      (malformed JSON 400, the rest 422, KickJS's messages)
- [x] 422 problem body with `errors: [{field, message}]`; validators declared on the type
      (`pub fn validate(self, issues)`)
- [x] Query helpers: `kzig.ListQuery(.{ .filterable, .sortable, .searchable })` (filters, sort,
      search, pagination) and `paginate` → `{data, meta, links}`
- [x] Settings sections (`defineSettings`): `pub const prefix`, comma lists, `<KEY>_FILE`,
      dev-only defaults (fail closed), App and Module `.settings`, `kzig.ConfigReport` origins
- [x] **Acceptance:** `examples/task-api` passes the archive's `minimal-api`, `multi-tenant-kickdb-api`
      projects (incl. create and import) and `settings-api` features / config-report tests

Follow-ups:

- [x] Mail adapter sections (`MailSettings("TRANSACTIONAL_MAIL")`) with adapters (M5)
- [ ] A query string with bad escapes reads as absent in typed queries; answer 400 instead
- [ ] Form bodies (`application/x-www-form-urlencoded`) and 415 for unsupported body types;
      duplicate JSON keys use the last value instead of 400
- [ ] A JSON `1.0` decodes into integer fields (zod `.int()` accepts it)
- [ ] A `_FILE` that can't be read is reported once (not also as `required`)
- [ ] A misspelt `dev_defaults` field is a compile error
- [ ] Length checks count characters, not bytes (the example's 200-character title)

### M5 — Lifecycle

- [x] Adapter middleware phases in KickJS order: `before_global`, plugins, App, `after_global`
      (the default), `before_routes`; `after_routes` for unmatched requests only
- [x] Adapters: `beforeMount`, `middleware`, `contributors`, `settings`, `onRouteMount`,
      `beforeStart`, `afterStart`, `onError`, `onResponse`, `onHealthCheck`, `shutdown`;
      `depends_on` order (cycles and unknown dependencies are compile errors)
- [x] Plugins bundling modules, adapters, middleware, contributors and settings
- [x] Request scope: contributors' `dispose`, after the response, in reverse
- [x] Graceful shutdown: `runtime.std.serve` on SIGINT/SIGTERM — stop accepting, health says
      draining, in-flight requests finish (cut at `shutdown_timeout_ms`), idle connections close,
      then adapters `shutdown` in reverse and services `deinit`; a second signal exits
- [x] `/health/ready` aggregates adapters' `onHealthCheck` (503 degraded / draining)
- [x] Settings sections take `validate` like decoded types
- [x] **Acceptance:** shutdown drains an in-flight request; adapter hook order matches KickJS;
      task-api runs settings-api's two scoped `MailAdapter`s with its mail settings tests

Follow-ups:

- [ ] Adapter `when` (conditional adapters) and `introspect` / DevTools tabs
- [ ] The signal flag is polled every 100 ms; wake at once (self-pipe / signalfd)
- [ ] `Io.Threaded` has no connect timeout; the mail check races a sleep instead
- [ ] `preStopDelay`: keep accepting for a while after draining starts, so load balancers see
      `/health/ready` answer 503 `draining`
- [ ] Clear compile errors for adapter hooks with the wrong signature; accept `void` and `!void`
      for both `beforeMount` and `shutdown`
- [ ] Keep cancel protection through `lingerClose`
- [ ] Mail check: IPv6 literal hosts (parse an IP before `HostName`)
- [ ] A section `validate` error is passed through instead of reported as `OutOfMemory`
- [ ] `serve` restores the previous signal handlers; skip `afterStart` when already draining

### M6 — http.zig runtime

- [x] `kzig_httpz` (built with `-Dhttpz`; a lazy dependency) behind the same `Server` / `serve`
      surface, through http.zig's `handle` takeover
- [x] One conformance suite (`runtime/conformance.zig`) over a real socket, run by both runtimes;
      response rules shared in `runtime/wire.zig`; in-process tests (task-api included) are
      engine-free
- [x] Benchmark both runtimes against KickJS on Express (`benchmarks/`): 6–23× KickJS
- [x] **Acceptance:** conformance passes on both runtimes, with http.zig's differences declared

Follow-ups:

- [ ] http.zig keeps a reused connection open after `connection: close` (declared difference;
      report upstream)
- [ ] http.zig: pipelined requests in one packet are dropped after the first
- [ ] http.zig: requests in flight aren't cut at `shutdown_timeout_ms`
- [ ] http.zig: response headers past 64 are dropped silently
- [ ] Benchmark with a load generator that isn't the bottleneck (wrk/oha, separate machine), and
      against Fastify, before choosing a default between std and http.zig

### M7 — OpenAPI and Swagger UI

- [x] JSON Schema from Zig types at comptime (`kzig.openapi.schema`)
- [x] Every route's OpenAPI operation built at comptime from its path, `body` / `query` /
      `params` types and return type; `RouteInfo.doc` for adapters
- [x] Doc options as data — controller `pub const docs`, route `.docs` — for KickJS's
      `@ApiTags`, `@ApiOperation`, `@ApiResponse`, `@ApiBearerAuth`, `@ApiExclude`
- [x] `kzig.swagger.Plugin(.{ … })`: `/openapi.json`, `/docs` (Swagger UI), `/redoc`;
      `disable_in_prod`; servers from the listening port
- [x] **Acceptance:** task-api serves its spec; `openapi.test.zig` checks it on every run (paths,
      parameters, `$ref`s, unique operation ids, tags, statuses)

Follow-ups:

- [ ] Lint the spec in CI with an OpenAPI validator (Redocly)
- [ ] Named component schemas (`$ref`) instead of inline ones; recursive types
- [ ] `@ApiSecurity` / custom security schemes; a public flag
- [ ] Local Swagger UI assets (KickJS serves `swagger-ui-dist` when installed)
- [ ] A `params` field that isn't in the path is a compile error (it always fails at runtime)
- [ ] No `requestBody` on GET/HEAD when a controller-level contributor reads `body`
- [ ] Servers from the bound host, not always `localhost`
- [ ] Compile time of doc generation for very large apps (≈4.5 s per 100 routes); name the
      route when the eval quota runs out

### M8 — `kzig` CLI

- [x] `kzig new <name>`: an App with a hello module, tests, Swagger and a test helper; kzig fetched
      with `zig fetch` (or `--kzig <path>`); a valid `build.zig.zon` fingerprint
- [x] `kzig g module <name>`: KickJS's REST module (module, controller, service, in-memory
      repository, list query, tests) or `--minimal`; mounted via `// kzig:modules` /
      `// kzig:tests` markers
- [x] `kzig g controller|service|middleware|contributor|adapter`, `kzig rm module`
- [x] `scripts/scaffold-check.sh` (CI): new → test → each generator → test → rm → test; generated
      code is `zig fmt` clean
- [x] **Acceptance:** task-api's `tasks` module is generated by `kzig g module task`

Follow-ups:

- [x] `kzig dev`: rebuild and restart on change; a failed build keeps the running app
- [x] `kzig build` (ReleaseSafe) / `kzig start` (execs the app, `NODE_ENV=production`)
- [x] `kzig g dto|guard|test`; `kzig add swagger|httpz`
- [x] Prebuilt `kzig` binaries in releases (a `v*` tag; Linux and macOS)
- [x] Errors to stderr; `kzig --help` / `kzig help` exit 0
- [x] Generated list endpoint: 400 for filter operators it doesn't support
- [x] Plurals for irregular words (`person`, `data`, `quiz`) and acronyms (`HTTPClient`)
- [x] Generated tests: a search test with more than one row; 404 documented on `/:id` routes

### M9 — File uploads and WebSockets

- [x] `kzig.Upload(.{ .field, .max_size, .max_count, .allowed_types })` read as `got.upload`:
      multipart parsed from the body; 415 for a type not allowed, 413 over the size or count,
      400 malformed; server-side names never from the client; OpenAPI `multipart/form-data`
- [x] task-api `files` module (`file-storage-api`, disk storage): API key, signed download links
- [x] WebSocket gateways (`@forinda/kickjs-ws`): `.gateways` on modules, `{event, data}` frames,
      rooms, `connect`/`disconnect`/`draining`, heartbeat, close codes; on both runtimes
- [x] task-api `chat` module (`ws-chat`, without Redis): tokens, rooms, presence

### M10 — Scheduled jobs

- [x] Cron expressions (5 or 6 fields, names, ranges, steps, lists; dom/dow either-match);
      invalid ones fail the build
- [x] Timezones from zoneinfo, with the TZif footer's POSIX rule past its table
- [x] `pub const crons` on services; `kzig.cron.Jobs` (list, next run, run now); the scheduler
      from `started`: run on init, no overlap by default, `cronEnabled`, `CRON_ENABLED`;
      `onCronError` for adapters; shutdown waits for runs in flight
- [x] task-api `crons` module (`cron-jobs-api`): last runs, `GET /cron/jobs`, guarded manual run

### M11 — Route tree

- [x] Routes matched through a comptime segment tree (static children binary-searched, one
      `:param` child, `*` routes) instead of a scan of every route; precedence stays
      declaration order (the lowest-index match wins), checked against the old scan for every
      path over a trap-laden table
- [x] `zig build bench-router`: 500 routes, about 100 ns wherever the route sits (the scan:
      80–680 ns), a 404 in 300–400 ns (was 3.6–4 µs); the benchmark compiles in a third of the time

### M12 — Storage

- [x] `kzig.storage.Storage` (put, get, stat, exists, delete, list with a cursor, url) with
      memory, disk (written aside and renamed) and S3 drivers; one contract test for all three
- [x] S3: SigV4 checked against AWS's published signatures, presigned GET links, ListObjectsV2,
      path or virtual-host style; tested against a fake bucket that checks every signature and,
      in CI, a real S3 API (SeaweedFS)
- [x] task-api `files` on it: `STORAGE_DRIVER` (disk in development, S3 otherwise), presigned
      links on S3, `storage:<driver>` on `/health/ready`
- [x] HEAD answers carry the Content-Length a GET would send (found by the S3 driver's `stat`)
- [x] S3 timeouts, a size cap and `error.ServiceUnavailable` (503) for an unreachable or failing
      bucket; temporary credentials tested; disk paths walked without following links

Not covered: IPv6 literal S3 endpoints (std.http.Client takes host names; name the address in
`/etc/hosts`), and a timeout on connecting itself (Io.Threaded can't time out a connect yet).

### M13 — Database

- [x] `kzig.db`: a Postgres client in Zig (SCRAM-SHA-256, MD5, cleartext; extended protocol),
      a pool, transactions, arguments from Zig values and rows decoded into structs by column
      name; a unique violation is 409, a dead connection 503
- [x] `kzig.db.migrate`: kick/db's migration folders and `kick_migrations` bookkeeping (hashes,
      batches, a lock), `latest`, `rollback`, `status`; applied on boot in development and test,
      a pending one stops the boot elsewhere
- [x] `kzig db new|migrate|rollback|status`; CI runs the database tests against Postgres 17
- [x] task-api `users` on it (task-kickdb-api): `postgres` on `/health/ready`, the routes 503
      without `DATABASE_URL`

Not covered: TLS, binary result format, `LISTEN`/`NOTIFY`, `COPY`.

### M14 — Schema and query builder

- [x] `kzig.db.table` / `kzig.db.Schema`: kick/db's Postgres column types, defaults, unique,
      indexes (unique, partial, `using`), foreign keys with actions, checks, pg enums,
      `snake_case` casing and kick/db's derived constraint names; `Row`/`Insert`/`Update` types
- [x] `kzig.db.Client`: `selectFrom` (select, where, joins, order, group, limit, offset, count),
      `insertInto` (one or many rows, `DEFAULT` cells, `onConflict`), `updateTable`,
      `deleteFrom`, `returning`; condition helpers; checked at comptime
- [x] `upsert` and race-safe `findOrCreate` (savepoint inside a transaction)
- [x] `kzig.db.Timestamp`; request bodies, rows and OpenAPI read it
- [x] task-api: task-kickdb-api's 16 tables in Zig, checked against its init `snapshot.json`;
      its init migration as is; users on the builder

### M15 — Generated migrations

- [x] Snapshots from the schema, byte for byte as kick/db writes them (task-api's matches
      task-kickdb-api's init snapshot); kick/db's parts kzig lacks are refused, not dropped
- [x] kick/db's diff engine, invert and Postgres emitter for tables, columns, indexes, keys,
      checks, primary keys and enums (added values in place, removed by recreate); task-api's
      schema generates task-kickdb-api's `up.sql` and `down.sql` byte for byte
- [x] `kzig db generate` (renames by prompt or `--rename-table`/`--rename-column`, `--empty`,
      meta.json, `_journal.json`) and `kzig db check`; schemas come from database adapters
      (`--db` picks one), and an app that doesn't answer in 60 s doesn't hang the CLI

Not covered: CONCURRENTLY indexes, views, RLS and policies, roles, comments, identity and
generated columns, named schemas; a snapshot holding any of them is refused.

### M16 — Relations

- [x] Relations on the schema (`one`, `many`, `many` through a junction, `relation_name`),
      resolved at comptime with kick/db's rules; written to `snapshot.json`'s sidecar (task-api's
      snapshot is now task-kickdb-api's byte for byte, relations included)
- [x] `client.query(.t).findMany/findFirst/findUnique`: `columns` (pick or leave out),
      `where`, `orderBy`, `limit`, `offset`, nested `with`; one statement, rows typed
- [x] task-api `workspaces` (task-kickdb-api): `/:id/full` and `/owned-by/:userId`
- [x] WebSocket shutdown: a socket still in `connect` when draining starts is drained too

Not covered: `morphOne`/`morphMany`/`morphTo`, cursor pagination of nested rows, table names
over 61 bytes in nested reads (their aliases truncate alike, as in kick/db). The sidecar orders
tables by name; kick/db orders them by export name, which agrees for snake_case tables named
after their exports.

### M17 — Postgres TLS

- [x] `sslmode` (disable, prefer by default, require, verify-ca, verify-full) and `sslrootcert`,
      or the system's CAs; close_notify on close
- [x] SCRAM sign-in must end with a verified server signature (and server-final after
      server-first); cleartext and MD5 passwords only over verified TLS
- [x] libpq's rules for `require` + `sslrootcert`; SNI in every mode (not for IP addresses); bytes
      sent with the SSL answer refused (CVE-2021-23222); a pinned `sslrootcert` never falls back to
      the OS store
- [x] CI runs every database test over TLS (a throwaway CA) and checks verify-full, a wrong host
      and a wrong CA

### M18 — Postgres TLS: direct, channel binding, client certificates

- [x] `src/db/tls/Client.zig`: std's TLS client, vendored with ALPN, the server certificate's
      hash, client authentication, SNI without host verification and no OS-store fallback
- [x] `sslnegotiation=direct` (Postgres 17, ALPN `postgresql`)
- [x] SCRAM-SHA-256-PLUS (`tls-server-end-point`); `channel_binding=disable|prefer|require`
- [x] `sslcert`/`sslkey`: EC P-256/P-384 and RSA (RSA-PSS) keys in SEC1, PKCS#8 or PKCS#1 PEM;
      an empty Certificate when asked and none is configured
- [x] CI: a `cert` pg_hba user signs in with EC and RSA certificates, refused without one

- [x] Encrypted keys and `sslpassword`: PKCS#8 PBES2 (PBKDF2-HMAC-SHA1/256/384/512, AES-128/256-CBC)
      and OpenSSL's traditional `DEK-Info` PEM (AES-128/256-CBC)
- [x] Client certificates on TLS 1.2 (RSA-PSS or PKCS#1 v1.5, ECDSA), and an empty Certificate when
      a TLS 1.2 server asks and none is configured; CI runs a TLS 1.2-only server for it

- [x] Ed25519 client keys (TLS 1.3); keys encrypted with scrypt or 3DES; `sslkey` checked against
      `sslcert`; RSA signatures blinded; channel binding to SHA-224-signed server certificates
- [x] `sslcrl`: CRLs verified against their CA, every server certificate checked (one whose issuer
      has no CRL is refused, as libpq); CI revokes the test server's certificate

Still to do:

- [ ] Ed25519 client keys on TLS 1.2 (they sign the handshake itself, not a hash)
- [ ] CRLs issued by an intermediate CA the server presents (today only CAs in `sslrootcert`
      sign CRLs; an intermediate there ends the chain, so it isn't checked against its root's CRL)
- [ ] Issuer names compared canonically (OpenSSL's `X509_NAME_cmp`), not byte for byte
- [ ] A CRL's signer must have `cRLSign` in its key usage
- [ ] Delta and indirect CRLs (refused today), and fetching CRL distribution points
- [ ] Malformed certificates (`sslrootcert`, the server's) are errors, not a panic in std's
      `Certificate.parse`: guard it or fix it upstream

Not planned: channel binding to Ed25519-signed server certificates (no hash defined; Postgres can't
bind them either).

### M19 — SQLite

- [x] `-Dsqlite`: SQLite's amalgamation as a lazy dependency; the default build has no C
- [x] `sqlite:path` / `sqlite::memory:` pools: one handle, a busy timeout, WAL for files, `?n`
      parameters (a canonical integer binds as INTEGER)
- [x] `Schema(…, .{ .dialect = .sqlite })`: the builder, upsert/findOrCreate and relational
      queries (`json_group_array`/`json_object`) on SQLite; a schema run on the other kind of
      database is `error.DialectMismatch`
- [x] `kzig db generate` / `migrate` on SQLite: kick/db's emitter and table rebuilds; foreign keys
      off while a migration runs and checked before it commits
- [x] task-api: tenants and projects on SQLite from multi-tenant-kickdb-api (its latest snapshot
      byte for byte; tenancy done by hand in the repository)

### M20 — Turso and Cloudflare D1

- [ ] `libsql://` over HTTP (Hrana v2 pipeline), batches and baton transactions
- [ ] `d1://` over Cloudflare's REST API; 100 parameters per statement, no transactions
- [ ] Migrations on both as one batch

### Later

SSE, a WebSocket broker (Redis), serverless cron triggers,
queues, a third engine (`io_uring`, edge).

## Open questions

Settled in the milestone that first needs them:

- Cancelling the accept loop and signal handling under `std.Io` (M5)
- How a route's context type is spelled in handler signatures (M3)
