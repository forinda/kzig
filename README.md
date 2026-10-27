# kzig

[KickJS](https://github.com/forinda/kick-js) for Zig: modules, controllers, services,
middleware, context contributors and adapters, with KickJS's boot order and request pipeline —
built on `comptime` instead of decorators, so a missing service or an unknown handler fails
`zig build`, not the first request.

> **Status: pre-alpha.** Modules, compile-time DI, config and settings sections, middleware,
> context contributors, typed and validated request bodies, list queries, adapters, plugins,
> health checks, graceful shutdown, an HTTP server on `std.http` and an in-process test runtime
> work (M1–M5). An http.zig runtime (M6) is next. APIs will change. See the
> [roadmap](./ROADMAP.md).

Requires **Zig 0.17.0**. No dependencies.

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
On SIGINT/SIGTERM `serve` stops accepting, health answers `draining`, requests in flight finish
(cut after `shutdown_timeout_ms`, 30 s) and idle connections close; then `app.deinit()` runs
adapters' `shutdown` in reverse dependency order. A contributor's `dispose(self, *V)` runs after
each response — KickJS's request scope.

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
| `@Post('/', { body: zodSchema })` / `ctx.body` | `got: struct { body: CreateProject }` |
| `ctx.qs(config)` / `ctx.paginate(…)` | `got.query: kzig.ListQuery(config)` / `query.paginate(…)` |
| `defineSettings('FEATURES', schema)` | a struct with `pub const prefix = "FEATURES"` |
| `createTestApp` + supertest | `app.init` / `initWith` + `kzig.testing.request` |

The full list of deliberate differences is in the [roadmap](./ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). [MIT](./LICENSE) licensed.
