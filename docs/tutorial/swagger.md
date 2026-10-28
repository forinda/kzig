# 5. API docs

The app has served Swagger UI at `/docs` since chapter 1. The spec comes from the code: each
route's path, its `params`, `query` and `body` types, and the type a handler returns.
`.docs` on a route adds a summary and the responses it can give.

## Authorize with the key

Two settings make Swagger UI's **Authorize** button send the key: `bearer_auth` on the plugin
adds the scheme, and `.bearer_auth = true` in a route's docs marks it as needing it (the three
writes in the [controller](api-key.md#on-the-routes-that-write)).

## In production too

The scaffold serves the docs only in development (`disable_in_prod = true`). This API is meant
to be used by others, so it keeps them: the spec only describes the API, and the writes still
need the key.

```zig title="src/main.zig"
const std = @import("std");
const kzig = @import("kzig");
const Config = @import("config.zig").Config;
const modules = @import("modules.zig").modules;
const DbAdapter = @import("adapters/db.adapter.zig").DbAdapter;

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .adapters = &.{DbAdapter},
    .middleware = .{
        kzig.middleware.requestId(),
        kzig.middleware.requestLogger(.{ .skip = &.{"/health"} }),
        kzig.middleware.helmet(.{}),
    },
    // /openapi.json, /docs (Swagger UI), /redoc — in production too: the
    // spec only describes the API, and writes still need the key.
    .plugins = &.{kzig.swagger.Plugin(.{
        .info = .{ .title = "Bookmarks API", .version = "0.1.0", .description = "Save links; writes take `Authorization: Bearer <API_KEY>`." },
        .bearer_auth = true,
    })},
});

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    // Until SIGINT/SIGTERM, then drains in-flight requests.
    const config = app.get(Config);
    try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .host = config.host, .port = config.port });
}

test {
    _ = @import("modules/hello/hello.test.zig");
    _ = @import("modules/bookmarks/bookmark.test.zig");
    // kzig:tests
}
```

| Path | What |
| --- | --- |
| `/docs` | Swagger UI: try each route; **Authorize** with the API key first for the writes |
| `/redoc` | ReDoc, for reading |
| `/openapi.json` | The OpenAPI 3.0 spec, for clients and code generators |

```console
$ curl -s localhost:3000/openapi.json | head -c 120
{"openapi":"3.0.3","info":{"title":"Bookmarks API","version":"0.1.0","description":"Save links; writes take `Authorization: …
```

Next, [tests](tests.md).
