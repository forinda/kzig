# Modules, controllers and services

[`examples/task-api`](https://github.com/forinda/kzig/tree/main/examples/task-api) is one app that grows with each milestone. Its modules
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
    .config = Config, // PORT, LOG_LEVEL
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
$ zig build examples && KZIG_ENV=development ./zig-out/bin/task-api
$ curl localhost:3000/api/v1/hello
{"message":"Hello World from kzig!","timestamp":"2026-10-27T05:22:26.756Z"}
$ curl -H 'authorization: Bearer token-all' -H 'x-tenant: acme' -H 'content-type: application/json' \
    -d '{"title":""}' localhost:3000/api/v1/projects
{"type":"about:blank","title":"Unprocessable Entity","status":422,"detail":"must be 1 to 200 characters","errors":[{"field":"title","message":"must be 1 to 200 characters"}]}
$ KZIG_ENV=production ./zig-out/bin/task-api
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
