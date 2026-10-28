# Getting started

kzig needs **Zig 0.17.0**. The library has no dependencies; the optional http.zig runtime and
local SQLite files fetch theirs only when you ask for them (`-Dhttpz`, `-Dsqlite`).

## A new app

The `kzig` CLI writes an app with a hello module, its tests and Swagger UI:

```console
$ kzig new my-api
$ cd my-api && zig build test
$ kzig dev   # builds, runs, and restarts on change
```

Prebuilt `kzig` binaries for Linux and macOS are attached to each
[release](https://github.com/forinda/kzig/releases). See [the CLI](cli.md) for every command.

## In an existing project

```console
zig fetch --save git+https://github.com/forinda/kzig
```

```zig
// build.zig
const kzig = b.dependency("kzig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("kzig", kzig.module("kzig"));
```

Then read [modules, controllers and services](guide/modules.md): it walks through the example
app, [`examples/task-api`](https://github.com/forinda/kzig/tree/main/examples/task-api), which
ports the KickJS example apps module by module, with their tests.
