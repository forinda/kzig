# kzig

[KickJS](https://github.com/forinda/kick-js) for Zig: modules, controllers, services, middleware,
context contributors and adapters, with KickJS's boot order and request pipeline. It is built on
`comptime` instead of decorators, so a missing service or an unknown handler fails `zig build`,
not the first request.

!!! warning "Pre-alpha"
    APIs will change. Requires **Zig 0.17.0**. The [roadmap](https://github.com/forinda/kzig/blob/main/ROADMAP.md)
    says what's done, what's next, and where kzig differs from KickJS on purpose.

```zig
pub const HelloController = struct {
    hello: *HelloService, // a missing service is a compile error

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
    };

    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !HelloService.Greeting {
        return self.hello.greet(ctx.arena, "World"); // sent as 200 JSON
    }
};

pub const HelloModule = kzig.Module(.{
    .name = "HelloModule",
    .path = "/hello",
    .controllers = &.{HelloController},
    .services = &.{HelloService},
});
```

New here? The [tutorial](tutorial/index.md) builds a complete API, from `kzig new` to a Docker
image: SQLite with migrations, validation, an API key, Swagger UI and tests.

## What's in it

| | |
| --- | --- |
| [Modules and DI](guide/modules.md) | Services wired by type at compile time; a cycle or a missing service fails the build |
| [Middleware and contributors](guide/middleware.md) | Typed context values (`got.tenant`), ordered by what they read |
| [Validation and settings](guide/validation.md) | Bodies, queries and params decoded into types; settings sections from the environment |
| [Adapters](guide/adapters.md) | KickJS's lifecycle hooks, health checks, graceful shutdown |
| [Uploads](guide/uploads.md) and [storage](guide/storage.md) | Multipart with limits; disk and S3 (SigV4, no SDK) |
| [Database](database/index.md) | Postgres without libpq (TLS, client certs), kick/db's schema, builder, relations and migrations |
| [SQLite, Turso, D1](database/sqlite.md) | The same layer on local files, Turso over HTTP and Cloudflare D1 |
| [WebSockets](guide/websockets.md) and [jobs](guide/jobs.md) | Gateways with rooms and heartbeats; cron with timezones |
| [OpenAPI](guide/openapi.md) | The spec from the types, Swagger UI and ReDoc |
| [CLI](cli.md) and [testing](guide/testing.md) | `kzig new`, `dev`, generators; the whole pipeline in-process |
| [API reference](api/) | Every public declaration, from the source's doc comments |
