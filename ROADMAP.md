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

### Later

SSE, S3 storage, a WebSocket broker (Redis), serverless cron triggers,
queues, database layer, a third engine (`io_uring`, edge).

## Open questions

Settled in the milestone that first needs them:

- Cancelling the accept loop and signal handling under `std.Io` (M5)
- How a route's context type is spelled in handler signatures (M3)
