# 1. Set up

## Zig and the CLI

kzig needs **Zig 0.17.0**. Get it from [ziglang.org/download](https://ziglang.org/download/) and
check it's the one on your path:

```console
$ zig version
0.17.0
```

The `kzig` CLI scaffolds apps, generates modules and writes migrations. Download it for Linux or
macOS from the [releases](https://github.com/forinda/kzig/releases) (on macOS, a browser
download needs `xattr -d com.apple.quarantine kzig`), or build it:

```console
$ git clone https://github.com/forinda/kzig && cd kzig
$ zig build            # zig-out/bin/kzig; put it on your PATH
```

## A new app

```console
$ kzig new bookmarks
  create bookmarks/build.zig
  create bookmarks/build.zig.zon
  …
  create bookmarks/src/modules/hello/hello.test.zig
$ cd bookmarks
$ zig build test
```

`kzig new` fetched kzig into `build.zig.zon` and wrote an app with one module:

```text
bookmarks/
  build.zig, build.zig.zon     # `zig build`, `zig build run`, `zig build test`
  src/main.zig                 # the App: modules, config, middleware, plugins
  src/config.zig               # PORT, KZIG_ENV, LOG_LEVEL from the environment
  src/modules.zig              # every mounted module; the generators edit it
  src/test_app.zig             # boots a fresh app per test
  src/modules/hello/           # a module: controller, service, test
```

`src/main.zig` is the whole application:

```zig title="src/main.zig"
const std = @import("std");
const kzig = @import("kzig");
const Config = @import("config.zig").Config;
const modules = @import("modules.zig").modules;

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .middleware = .{
        kzig.middleware.requestId(),
        kzig.middleware.requestLogger(.{ .skip = &.{"/health"} }),
        kzig.middleware.helmet(.{}),
    },
    // /openapi.json, /docs, /redoc — development and test only.
    .plugins = &.{kzig.swagger.Plugin(.{
        .info = .{ .title = "bookmarks", .version = "0.0.1" },
        .disable_in_prod = true,
    })},
});

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    // Until SIGINT/SIGTERM, then drains in-flight requests.
    try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .port = app.get(Config).port });
}

test {
    _ = @import("modules/hello/hello.test.zig");
    // kzig:tests
}
```

Run it:

```console
$ KZIG_ENV=development zig build run
info: listening on http://127.0.0.1:3000
```

```console
$ curl localhost:3000/api/v1/hello
{"message":"Hello World from kzig!"}
$ curl localhost:3000/health/ready
{"status":"ready","checks":[]}
```

Open <http://localhost:3000/docs> for Swagger UI. Every route mounts at
`/api/v1/<module path><route path>`; `/health/live` and `/health/ready` are built in.

!!! tip "Rebuild on save"
    `kzig dev` builds, runs, and restarts the app whenever `src/` changes. A build that fails
    leaves the running app up.

Next: [a first module](first-module.md).
