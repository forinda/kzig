# kzig

[KickJS](https://github.com/forinda/kick-js) for Zig: modules, controllers, services,
middleware, context contributors and adapters, with KickJS's boot order and request pipeline,
built on `comptime` instead of decorators. A missing service or an unknown handler fails
`zig build`, not the first request.

**[Documentation](https://forinda.github.io/kzig/)** · [API reference](https://forinda.github.io/kzig/api/) ·
[Roadmap](./ROADMAP.md)

> **Status: pre-alpha.** APIs will change. Requires **Zig 0.17.0**; no dependencies (http.zig
> and SQLite's C library are fetched only when you ask for them).

```zig
pub const HelloController = struct {
    hello: *HelloService, // injected by type; a missing service is a compile error

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
    };

    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !HelloService.Greeting {
        return self.hello.greet(ctx.arena, "World"); // sent as 200 JSON
    }
};

pub const App = kzig.App(.{
    .modules = &.{HelloModule},
    .middleware = .{ kzig.middleware.requestId(), kzig.middleware.helmet(.{}) },
});
```

## Highlights

- **Compile-time wiring.** Services injected by type, cycles and missing services caught by
  the compiler, typed context values (`got: struct { tenant: Tenant }`) checked against the
  route's contributors.
- **KickJS's pipeline.** Middleware and contributors in KickJS's order, adapters with its
  lifecycle hooks, health checks, graceful shutdown, RFC 9457 problem bodies.
- **Types as the schema.** Request bodies, queries and settings decoded and validated from
  Zig types; OpenAPI and Swagger UI generated from them.
- **Database.** Postgres without libpq (TLS, client certificates, CRLs, SCRAM channel
  binding), kick/db's schema, query builder, relations and generated migrations, on Postgres,
  SQLite, Turso and Cloudflare D1.
- **Batteries.** File uploads, disk and S3 storage, WebSockets with rooms, cron jobs with
  timezones, an in-process test runtime, two HTTP runtimes (`std.http`, http.zig), and a
  `kzig` CLI (`new`, `dev`, generators, `db generate`/`migrate`).

[`examples/task-api`](./examples/task-api) is one app that ports the
[KickJS example apps](https://github.com/forinda/kickjs-examples-archive) module by module,
with their tests.

## Install

```console
zig fetch --save git+https://github.com/forinda/kzig
```

```zig
// build.zig
const kzig = b.dependency("kzig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("kzig", kzig.module("kzig"));
```

Or start from the CLI: `kzig new my-api` ([getting started](https://forinda.github.io/kzig/getting-started/)).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). [MIT](./LICENSE) licensed.
