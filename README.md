# kzig

[KickJS](https://github.com/forinda/kick-js) for Zig: modules, controllers, services,
middleware, context contributors and adapters, with KickJS's boot order and request pipeline —
built on `comptime` instead of decorators, so a missing service or an unknown handler fails
`zig build`, not the first request.

> **Status: pre-alpha.** Modules, compile-time DI, env config, the router, problem bodies, an
> HTTP server on `std.http` and an in-process test runtime work (M1–M2). Middleware and context
> contributors (M3) are next. APIs will change. See the [roadmap](./ROADMAP.md).

Requires **Zig 0.17.0**. No dependencies.

## Example

The [`minimal-api`](./examples/minimal-api) port of KickJS's smallest app, file for file:

```zig
// hello.service.zig
pub const HelloService = struct {
    process: *const kzig.Process, // injected by type

    pub fn greet(self: *HelloService, arena: std.mem.Allocator, name: []const u8) !Greeting { … }
};

// hello.controller.zig
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

// hello.module.zig
pub const HelloModule = kzig.Module(.{
    .name = "HelloModule",
    .path = "/hello",
    .controllers = &.{HelloController},
    .services = &.{HelloService},
});

// config.zig — each field reads its upper-cased env var (PORT, NODE_ENV, LOG_LEVEL)
pub const Config = struct {
    port: u16 = 3000,
    node_env: enum { development, production, @"test" } = .development,
    log_level: []const u8 = "info",
};

// main.zig
pub const App = kzig.App(.{ .modules = &.{HelloModule}, .config = Config });

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();

    var server: kzig.runtime.std.Server(App) = try .init(init.io, init.gpa, &app, .{ .port = app.get(Config).port });
    defer server.deinit();
    try server.run();
}
```

```console
$ zig build examples && ./zig-out/bin/minimal-api
$ curl localhost:3000/api/v1/hello
{"message":"Hello World from kzig!","timestamp":"2026-10-27T04:39:51.658Z"}
$ curl localhost:3000/health/ready
{"status":"ready","checks":[]}
$ curl localhost:3000/api/v1/nope
{"type":"about:blank","title":"Not Found","status":404}
$ PORT=abc ./zig-out/bin/minimal-api
error: config: PORT: expected an integer
```

Routes mount at `/api/v{version}{module.path}{route.path}`; a module takes `.version = 2` or
`.version = false`, and `.prefix = false` drops `/api`. `/health/live` and `/health/ready` are
built in. A handler's return value is the response: a struct is 200 JSON, `void` is 204, a
string is text, a type with `sendResponse` sends itself. Return `error.NotFound`,
`error.Conflict`, … for an RFC 9457 problem body, or `ctx.fail(.unprocessable_entity, "detail")`
to add details.

These fail `zig build`, not the first request: a service field pointing at an unlisted service, a
dependency cycle, a route naming a missing handler, two routes with the same method and path,
a misspelt `Module`/`App` option.

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
| `createTestApp` + supertest | `app.init` / `initWith` + `kzig.testing.request` |

The full list of deliberate differences is in the [roadmap](./ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). [MIT](./LICENSE) licensed.
