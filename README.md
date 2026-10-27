# kzig

[KickJS](https://github.com/forinda/kick-js) for Zig: modules, controllers, services,
middleware, context contributors and adapters, with KickJS's boot order and request pipeline —
built on `comptime` instead of decorators, so a missing service or an unknown handler fails
`zig build`, not the first request.

> **Status: pre-alpha.** Modules, compile-time DI, config and settings sections, middleware,
> context contributors, typed and validated request bodies, list queries, adapters, plugins,
> health checks, graceful shutdown, OpenAPI with Swagger UI, file uploads, WebSockets, scheduled
> jobs, file storage (disk, S3), two HTTP runtimes (`std.http`, and http.zig opt-in), an
> in-process test runtime and a `kzig` CLI work (M1–M12). APIs will change. See the [roadmap](./ROADMAP.md).

Requires **Zig 0.17.0**. No dependencies (the optional http.zig runtime fetches http.zig).

## Example

[`examples/task-api`](./examples/task-api) is one app that grows with each milestone. Its modules
port the [KickJS example apps](https://github.com/forinda/kickjs-examples-archive) with their tests:
`hello` (minimal-api), `projects` (multi-tenant-kickdb-api, in memory), `features`,
`config-reports` and two scoped `MailAdapter`s (settings-api).

```zig
// modules/hello/hello.service.zig
pub const HelloService = struct {
    process: *const kzig.Process, // injected by type

    pub fn greet(self: *HelloService, arena: std.mem.Allocator, name: []const u8) !Greeting { … }
};

// modules/hello/hello.controller.zig
pub const HelloController = struct {
    hello: *HelloService, // a missing service is a compile error

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
        .{ .method = .GET, .path = "/health", .handler = "health" },
    };

    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !HelloService.Greeting {
        return self.hello.greet(ctx.arena, "World"); // sent as 200 JSON
    }
    …
};

// modules/hello/hello.module.zig
pub const HelloModule = kzig.Module(.{
    .name = "HelloModule",
    .path = "/hello",
    .controllers = &.{HelloController},
    .services = &.{HelloService},
});

// main.zig
pub const App = kzig.App(.{
    .modules = &.{ HelloModule, ProjectModule, FeaturesModule, ConfigReportModule },
    .config = Config, // PORT, NODE_ENV, LOG_LEVEL
    .settings = &.{AppSettings}, // APP_NAME, APP_PUBLIC_URL
    .adapters = &.{ MailAdapter("transactional", TransactionalMail), MailAdapter("marketing", MarketingMail) },
    .middleware = .{ kzig.middleware.requestId(), kzig.middleware.requestLogger(.{}), kzig.middleware.helmet(.{}) },
});

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map); // adapters' beforeMount … beforeStart
    defer app.deinit(); // adapters' shutdown (reverse), then services' deinit

    // Until SIGINT/SIGTERM, then drains: in-flight requests finish, idle connections close.
    try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .port = app.get(Config).port });
}
```

```console
$ zig build examples && NODE_ENV=development ./zig-out/bin/task-api
$ curl localhost:3000/api/v1/hello
{"message":"Hello World from kzig!","timestamp":"2026-10-27T05:22:26.756Z"}
$ curl -H 'authorization: Bearer token-all' -H 'x-tenant: acme' -H 'content-type: application/json' \
    -d '{"title":""}' localhost:3000/api/v1/projects
{"type":"about:blank","title":"Unprocessable Entity","status":422,"detail":"must be 1 to 200 characters","errors":[{"field":"title","message":"must be 1 to 200 characters"}]}
$ NODE_ENV=production ./zig-out/bin/task-api
error: Settings 'APP' are invalid:
error:   APP_PUBLIC_URL: required
```

Routes mount at `/api/v{version}{module.path}{route.path}`; a module takes `.version = 2` or
`.version = false`, and `.prefix = false` drops `/api`. `/health/live` and `/health/ready` are
built in. A handler's return value is the response: a struct is 200 JSON, `void` is 204, a
string is text, a type with `sendResponse` sends itself. Return `error.NotFound`,
`error.Conflict`, … for an RFC 9457 problem body, or `ctx.fail(.unprocessable_entity, "detail")`
to add details.

These fail `zig build`, not the first request: a service field pointing at an unlisted service, a
dependency cycle, a route naming a missing handler, two routes with the same method and path,
a misspelt `Module`/`App` option, a handler reading a value no contributor on its route provides.

## Middleware and contributors

From the `projects` module:

```zig
/// A context contributor: a service with a `key` and a `resolve`.
pub const LoadTenant = struct {
    pub const key = "tenant";
    repo: *TenantRepository,

    // Reading `user` makes LoadAuthUser run first; no `dependsOn` list.
    pub fn resolve(self: *LoadTenant, ctx: *kzig.Ctx, got: struct { user: AuthUser }) !Tenant { … }
};

pub const ProjectController = struct {
    projects: *ProjectRepository,
    pub const contributors = .{ LoadTenant, LoadAuthUser };
    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list" },
        .{ .method = .POST, .path = "/", .handler = "create" },
    };

    // `got.tenant` is typed; drop LoadTenant above and this doesn't compile.
    pub fn list(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: Tenant }) !Projects { … }

    // `body` is decoded from JSON and validated before the handler runs.
    pub fn create(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: Tenant, body: CreateProject }) !void { … }
};
```

Middleware is `fn (ctx: *kzig.Ctx, next: *kzig.Next) !void` (or a service struct with that
`handle`), registered on the App, a controller (`pub const middleware`) or a route
(`.middleware`). Code after `next.run()` sees the final response, errors included. Contributors
register on the App, a module, a controller or a route; the more specific one wins for a key.
On a matched route the order is: `before_validation` contributors, request decoding, then
controller and route middleware around the other contributors and the handler. A contributor or
middleware that answers (or sets a status and returns) ends the request there.

Services, middleware and contributors are app-wide singletons shared by concurrent requests:
keep per-request data on `ctx`, and guard shared state with atomics or a lock.

## Validation, list queries and settings

The schema is the type. `body`, `query` and `params` in a `got` struct are decoded from the
request; every problem is reported with its path, as a 422 problem body:

```zig
pub const CreateProject = struct {
    title: []const u8,
    description: ?[]const u8 = null,

    pub fn validate(self: *const CreateProject, issues: *kzig.Issues) !void {
        if (self.title.len < 1 or self.title.len > 200) try issues.add("title", "must be 1 to 200 characters");
    }
};

// A list endpoint (sketch; tasks arrive in a later milestone):
pub fn list(self: *TaskController, ctx: *kzig.Ctx, got: struct {
    query: kzig.ListQuery(.{ .filterable = &.{"status"}, .sortable = &.{"created"} }),
}) !kzig.Paginated(Task) {
    // ?filter=status:eq:open&sort=-created&page=2&limit=20
    const rows = try self.tasks.find(ctx.arena, got.query);
    return got.query.paginate(ctx, Task, rows.items, rows.total);
}
```

Settings sections are structs with a prefix, read and validated at boot when the module that
declares them is mounted:

```zig
pub const FeatureSettings = struct {
    pub const prefix = "FEATURES";
    signups: bool = true, // FEATURES_SIGNUPS
    beta_testers: []const []const u8 = &.{}, // FEATURES_BETA_TESTERS=a@x.io,b@x.io
};

pub const AppSettings = struct {
    pub const prefix = "APP";
    pub const dev_defaults = .{ .public_url = "http://localhost:3000" }; // only when NODE_ENV is development/test
    public_url: []const u8, // APP_PUBLIC_URL, or APP_PUBLIC_URL_FILE=/run/secrets/…
};
```

## Adapters, plugins and shutdown

An adapter is a service with optional KickJS hooks — `beforeMount`, `onRouteMount`,
`beforeStart`, `afterStart`, `onError`, `onResponse`, `onHealthCheck`, `shutdown` — plus
`depends_on`, phased `middleware`, `contributors` and `settings`:

```zig
pub fn MailAdapter(comptime name: []const u8, comptime Settings: type) type {
    return struct {
        pub const settings = &.{Settings}; // read and validated because this adapter is mounted
        mail: *const Settings,
        process: *const kzig.Process,

        /// Part of /health/ready: 503 "degraded" when any check is down.
        pub fn onHealthCheck(self: *@This()) kzig.HealthCheck {
            return .{ .name = "MailAdapter:" ++ name, .status = if (self.reachable()) .up else .down };
        }
        …
    };
}
```

```console
$ curl -i localhost:3000/health/ready
HTTP/1.1 503 Service Unavailable
{"status":"degraded","checks":[{"name":"MailAdapter:transactional","status":"down"},{"name":"MailAdapter:marketing","status":"down"}]}
```

`kzig.Plugin(.{ .modules, .adapters, .middleware, .contributors, .settings })` bundles them.
On SIGINT/SIGTERM `serve` stops accepting new connections, requests in flight finish (their
sockets are cut after `shutdown_timeout_ms`, 30 s; a handler still running a second later makes
the process exit with status 1 rather than free services under it) and idle connections close;
then `app.deinit()` runs adapters' `shutdown` in reverse dependency order. `/health/*` answer
`draining` from the moment shutdown begins, to requests already in flight. `/health/ready` runs
every adapter's check at once, counts one slower than 2 s as down, and shares a run between
probes within a second. A contributor's `dispose(self, *V)` runs when its handler returns,
before the response is written — a response body must not borrow memory `dispose` frees.

## File uploads

KickJS's `@FileUpload`: read `upload` in `got`, and the multipart body is parsed for you.

```zig
const Avatar = kzig.Upload(.{ .field = "file", .max_size = 2 * 1024 * 1024, .allowed_types = &.{ "png", "jpg" } });

pub fn upload(self: *FilesController, ctx: *kzig.Ctx, got: struct { upload: Avatar }) !void {
    const file = got.upload.file() orelse return ctx.fail(.bad_request, "Send the file in the `file` form field");
    // file.filename is a UUID plus the extension of its type, never the client's name.
    try ctx.created(try self.files.save(ctx.arena, file.filename, file.data));
}
```

A type outside `allowed_types` (extensions, MIME types, `image/*`) is 415, a file over
`max_size` or more than `max_count` files is 413, a broken body 400; text fields are in
`upload.fields`. The whole request is still bounded by the server's `max_body_bytes`. Send
bytes back with `ctx.bytes(content_type, data)`. task-api's `files` module is
[file-storage-api](https://github.com/forinda/kickjs-examples-archive) on disk: API key, signed
download links.

## Storage

KickJS's `@forinda/kickjs-storage`: one `kzig.storage.Storage` over memory, a disk folder or an S3
bucket (AWS, R2, MinIO, SeaweedFS).

```zig
var s3: kzig.storage.S3 = try .fromSettings(io, gpa, settings); // S3_BUCKET, S3_ENDPOINT, …
defer s3.deinit();
const files = s3.storage();
try files.put("files/a.png", bytes, .{ .content_type = "image/png" });
const page = try files.list(arena, .{ .prefix = "files/", .limit = 100 });
const link = try files.url(arena, "files/a.png", .{ .expires_in = 300 }); // presigned GET
```

`get` and `stat` answer null for a missing file, `delete` of one is fine, and `list` pages with a
cursor. Requests are signed with SigV4 by kzig itself (no SDK). A bucket that can't be reached,
answers 5xx or takes longer than `timeout_ms` (30 s) is `error.ServiceUnavailable`, a 503; an
object over `max_object_bytes` (256 MiB) isn't read. The disk driver refuses keys that pass
through a symbolic link. task-api's `files` module picks
the driver from `STORAGE_DRIVER`.

## Database

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
(503). No TLS yet: `sslmode=require` is refused.

Migrations use kick/db's layout — `db/migrations/<YYYYMMDD_HHMMSS>_<name>/up.sql` and
`down.sql` — and its `kick_migrations` table, so the two can share a database.
`kzig.db.migrate.onBoot` applies pending ones (or, with `.fail_if_pending`, refuses to start);
the CLI runs them by hand:

```console
$ kzig db new create_users   # db/migrations/20261027_120000_create_users/{up,down}.sql
$ kzig db migrate            # DATABASE_URL; also: rollback (last batch), status
```

task-api's `users` module and `DbAdapter` show the whole setup: migrations on boot in
development, `postgres` on `/health/ready`, and 503s when `DATABASE_URL` isn't set.

## WebSockets

KickJS's `@forinda/kickjs-ws`: a gateway in a module's `.gateways`, at `/ws` + its `path`.
Frames are JSON `{ "event": …, "data": … }`; a handler's `data` is decoded like a request body.

```zig
pub const ChatGateway = struct {
    presence: *Presence, // injected like any service

    pub const path = "/chat"; // ws://host/ws/chat
    pub const State = struct { name: []const u8 = "" }; // per socket
    const Ctx = kzig.ws.Ctx(State);
    pub const events = .{
        .{ .event = "message:send", .handler = "send" },
        .{ .event = "*", .handler = "unknown" },
    };

    pub fn connect(self: *ChatGateway, ctx: *Ctx) !void {
        const user = try self.verify(try ctx.query("token")) orelse return ctx.close(4401, "Unauthorized");
        ctx.state.name = try ctx.conn_arena.dupe(u8, user.name);
    }

    pub fn send(_: *ChatGateway, ctx: *Ctx, data: struct { room: []const u8, text: []const u8 }) !void {
        if (!ctx.inRoom(data.room)) return ctx.send("error", .{ .message = "join it first" });
        try ctx.to(data.room).send("message", .{ .from = ctx.state.name, .text = data.text });
    }
};
```

`ws.Ctx` has `send`, `close`, `join`, `leave`, `rooms`, `to(room).send`, `broadcast`,
`broadcastAll`, and the upgrade request's `header` and `query`. Optional hooks: `connect`,
`disconnect`, `draining` (on shutdown, before every socket closes with 1001). The App's
`.ws = .{ .path, .heartbeat_ms, .max_payload, .write_timeout_ms }` sets the mount, the ping
interval (a socket that misses a pong is dropped), the message limit (1009 over it) and how long
a write may wait on a client that stopped reading before its socket is cut. Both runtimes serve
gateways with the same loop (http.zig hands the socket over after the handshake).
task-api's `chat` module is the archive's ws-chat without Redis.

## Scheduled jobs

KickJS's `@Cron`: any service lists its jobs, and the App schedules them once it is listening.

```zig
pub const MaintenanceJobs = struct {
    reports: *ReportService,

    pub const crons = .{
        .{ .expression = "*/5 * * * *", .handler = "purge", .name = "purge-sessions" },
        .{ .expression = "0 2 * * *", .handler = "nightly", .timezone = "Africa/Nairobi" },
        .{ .expression = "0 * * * *", .handler = "warm", .run_on_init = true },
    };

    /// Asked on every tick and manual run.
    pub fn cronEnabled(self: *MaintenanceJobs, name: []const u8) bool { … }

    pub fn nightly(self: *MaintenanceJobs, run: kzig.cron.Run) !void {
        try self.reports.generate(run.arena);
    }
};
```

Expressions have 5 fields or 6 (seconds first), with names, ranges, steps and lists; a bad one
fails `zig build`. Timezones come from the system's zoneinfo (`CRON_ZONEINFO`). A run while the
previous is still going is skipped unless `.overlap = true`. Across a daylight-saving change, a
local time that doesn't exist is skipped, and in a repeated hour only jobs with `*` hours run
again. `CRON_ENABLED=false` schedules
nothing (one replica of several, say). Inject `*kzig.cron.Jobs` to list jobs, get their next run
or run one now; a failure reaches adapters' `onCronError(err, info)`. Shutdown stops the
schedule and waits for runs in flight. task-api's `crons` module is the archive's
cron-jobs-api.

## CLI

Prebuilt `kzig` binaries for Linux and macOS are attached to each
[release](https://github.com/forinda/kzig/releases) (on macOS, a browser download needs
`xattr -d com.apple.quarantine kzig`); or build it:

```console
$ zig build                  # builds zig-out/bin/kzig
$ kzig new my-api            # an App with a hello module, tests and Swagger; fetches kzig
$ cd my-api && zig build test
$ kzig dev                   # zig build + run; rebuilds and restarts on change
$ kzig g module task         # src/modules/tasks: REST CRUD with an in-memory repository and tests
$ kzig g middleware audit    # also: controller, service, contributor, adapter, dto, guard, test
$ kzig add httpz             # serve on http.zig; `kzig add swagger` puts Swagger back
$ kzig build                 # zig build -Doptimize=ReleaseSafe
$ kzig start --port 8080     # the built app, NODE_ENV=production
$ kzig rm module task
$ kzig db migrate            # see Database
```

`kzig g module` writes KickJS's REST module — `GET /` (filter/sort/page), `GET /:id`, `POST /`
(201), `PATCH /:id`, `DELETE /:id` (204) — and mounts it. Filters on `name` take `eq`, `neq`,
`contains`, `starts` and `ends`; another operator is a 400. task-api's `tasks` module was
generated this way.

`kzig dev` watches `src/`, `build.zig` and `build.zig.zon`, sets `NODE_ENV=development` unless
it is set, and passes arguments after `--` to the app. A build that fails leaves the running app
up; Ctrl-C stops both. `kzig start` replaces itself with the app, so a supervisor's SIGTERM
reaches the app and it drains. Names may be any case (`TaskList`, `task_list`, `HTTPClient`);
plurals know the irregular words (`person` → `people`).

## Testing

`kzig.testing.request` runs the full pipeline in-process, no socket:

```zig
test "GET /api/v1/hello returns a greeting" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var app: App = undefined;
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();

    var res = try kzig.testing.request(testing.allocator, &app, .{ .target = "/api/v1/hello" });
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try testing.expectEqualStrings("Hello World from kzig!", body.message);
}
```

Replace a service in a test with `app.initWith(io, gpa, &env, .{FakeRepo{ … }})` — KickJS's
`createTestApp({ overrides })`; outside tests it doesn't compile.

## Install

```console
zig fetch --save git+https://github.com/forinda/kzig
```

```zig
// build.zig
const kzig = b.dependency("kzig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("kzig", kzig.module("kzig"));
```

## Server defaults

| Option | Default | |
| --- | --- | --- |
| `max_body_bytes` | 1 MiB | larger → 413 |
| `max_header_bytes` | 16 KiB | larger → 431 |
| `head_timeout_ms` | 60 000 | time to send a request head, keep-alive idle included |
| `body_timeout_ms` | 300 000 | time to send the body, and again to read the response |
| `max_connections` | 1024 | further clients wait in the kernel backlog |

Paths are percent-decoded per segment; `.` / `..` (also behind an encoded `/`), invalid
UTF-8 and malformed escapes answer 400. A request with both `content-length` and
`transfer-encoding` is refused and the connection closed.

## OpenAPI and Swagger UI

The spec comes from the types: path params, `query` / `params` / `body` structs and handler
return types become parameters, request bodies and response schemas, at compile time.

```zig
.plugins = &.{kzig.swagger.Plugin(.{
    .info = .{ .title = "task-api", .version = "0.1.0" },
    .disable_in_prod = true,
})},

pub const ProjectController = struct {
    pub const docs = .{ .tags = &[_][]const u8{"Projects"}, .bearer_auth = true };
    pub const routes = .{
        .{ .method = .POST, .path = "/", .handler = "create", .docs = .{
            .summary = "Create a project",
            .responses = .{.{ .status = 201, .description = "Created", .body = Project }},
        } },
    };
    …
};
```

`/openapi.json` (OpenAPI 3.0.3), `/docs` (Swagger UI) and `/redoc`. Doc options are data on the
controller (`pub const docs`) and the route (`.docs`): `tags`, `summary`, `description`,
`operation_id`, `deprecated`, `responses`, `bearer_auth`, `exclude`.

## Runtimes

`kzig.runtime.std` (no dependencies) is the default. [http.zig](https://github.com/karlseguin/http.zig)
is opt-in, KickJS's `runtime:` option in Zig:

```zig
// build.zig
const kzig = b.dependency("kzig", .{ .target = target, .optimize = optimize, .httpz = true });
exe.root_module.addImport("kzig_httpz", kzig.module("kzig_httpz"));

// main.zig
try @import("kzig_httpz").serve(App, &app, init.io, init.gpa, .{ .port = 3000 });
```

Both pass the same socket-level conformance suite, except that http.zig keeps a reused
connection open after `connection: close` (declared in the suite, listed in the roadmap). std
stays the default. Against KickJS on Express, on one machine (see [benchmarks](./benchmarks)):

| route | kzig std | kzig http.zig | KickJS / Express |
| --- | ---: | ---: | ---: |
| `GET /api/v1/hello` (minimal-api) | 115,930 req/s | 124,032 req/s | 5,292 req/s |
| `GET /api/v1/json` | 74,808 req/s | 138,609 req/s | 9,296 req/s |
| `POST /api/v1/validate` | 103,002 req/s | 58,799 req/s | 9,487 req/s |

## Coming from KickJS

| KickJS | kzig |
| --- | --- |
| `@Controller()` / `@Get('/')` | `pub const routes = .{ … }` on a struct |
| `@Service()` / `@Autowired()` | a `*Dep` field, wired at compile time |
| `defineModule({ routes })` | `kzig.Module(.{ .path, .controllers, .services })` |
| `bootstrap({ modules })` | `kzig.App(.{ .modules, .config })` |
| `loadEnv(zodSchema)` / `@Value('PORT')` | a `Config` struct; inject `*const Config` |
| `@PostConstruct` / `@PreDestroy` | `pub fn init(self: *S) !void` / `pub fn deinit(self: *S) void` |
| `throw new HttpException(422, …)` | `return ctx.fail(.unprocessable_entity, …)` |
| `defineContextDecorator({ key, deps, resolve })` | a struct with `key`, DI fields and `resolve` |
| `ctx.get('tenant')` | a `got: struct { tenant: Tenant }` handler parameter |
| `@Middleware(fn)` / `bootstrap({ middlewares })` | `.middleware = .{fn}` on a route, controller or App |
| `requestId()`, `requestLogger()`, `cors()`, `helmet()` | `kzig.middleware.requestId()`, … |
| `defineAdapter({ beforeMount, onHealthCheck, … })` | a struct with those decls in `.adapters` |
| `definePlugin({ modules, adapters, … })` | `kzig.Plugin(.{ … })` in `.plugins` |
| `app.shutdown()` on SIGTERM | `kzig.runtime.std.serve(…)` + `defer app.deinit()` |
| `SwaggerAdapter({ info })`, `@ApiTags`, `@ApiOperation`, `@ApiResponse` | `kzig.swagger.Plugin(.{ … })`, `docs` / `.docs` data |
| `kick new`, `dev`, `build`, `start`, `g`, `add`, `rm` | `kzig new`, `dev`, `build`, `start`, `g`, `add`, `rm` |
| `bootstrap({ runtime: fastifyRuntime() })` | `@import("kzig_httpz").serve(…)` (`-Dhttpz`) |
| `@Post('/', { body: zodSchema })` / `ctx.body` | `got: struct { body: CreateProject }` |
| `ctx.qs(config)` / `ctx.paginate(…)` | `got.query: kzig.ListQuery(config)` / `query.paginate(…)` |
| `defineSettings('FEATURES', schema)` | a struct with `pub const prefix = "FEATURES"` |
| `createTestApp` + supertest | `app.init` / `initWith` + `kzig.testing.request` |
| `@FileUpload({ maxSize, allowedTypes })` / `ctx.file` | `got: struct { upload: kzig.Upload(.{ … }) }` / `got.upload.file()` |
| `@WsController('/chat')`, `@OnConnect`, `@OnMessage('e')` | a struct in `.gateways` with `path`, `connect`, `events` |
| `ws` in tests | `kzig.testing.WsClient` |
| `@Cron(expr, { timezone, runOnInit, overlap, enabled })` + `KickCronAdapter` | `pub const crons = .{ … }` on a service, scheduled by the App |
| `runCronJobs(container, { name }, 'manual')` | `jobs.run(name, .manual)` on an injected `*kzig.cron.Jobs` |

The full list of deliberate differences is in the [roadmap](./ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). [MIT](./LICENSE) licensed.
