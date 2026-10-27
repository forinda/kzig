# kzig

[KickJS](https://github.com/forinda/kick-js) for Zig: modules, controllers, services,
middleware, context contributors and adapters, with KickJS's boot order and request pipeline —
built on `comptime` instead of decorators, so a missing service or an unknown handler fails
`zig build`, not the first request.

> **Status: pre-alpha.** The core runtime (M1) works: router, request context, problem bodies,
> an HTTP server on `std.http` and an in-process test runtime. Modules and dependency injection
> (M2) are next. APIs will change. See the [roadmap](./ROADMAP.md).

Requires **Zig 0.17.0**. No dependencies.

## Example

```zig
const std = @import("std");
const kzig = @import("kzig");

fn hello(_: *kzig.Ctx) struct { message: []const u8 } {
    return .{ .message = "Hello World from kzig!" };
}

fn user(ctx: *kzig.Ctx) !struct { id: []const u8 } {
    const id = ctx.param("id").?;
    if (std.mem.eql(u8, id, "0")) return error.NotFound; // 404 problem+json
    return .{ .id = id };
}

const App = kzig.Router(&.{
    kzig.route(.GET, "/api/v1/hello", hello),
    kzig.route(.GET, "/api/v1/users/:id", user),
});

pub fn main(init: std.process.Init) !void {
    var server: kzig.runtime.std.Server(App) = try .init(init.io, init.gpa, .{ .port = 3000 });
    defer server.deinit();
    try server.run();
}
```

```console
$ curl localhost:3000/api/v1/hello
{"message":"Hello World from kzig!"}
$ curl localhost:3000/api/v1/users/0
{"type":"about:blank","title":"Not Found","status":404}
$ curl -X POST -i localhost:3000/api/v1/hello
HTTP/1.1 405 Method Not Allowed
allow: GET, HEAD
```

A handler's return value is the response: a struct is 200 JSON, `void` is 204, a string is
text, a type with `sendResponse` sends itself. Return `error.NotFound`, `error.Conflict`, …
for an RFC 9457 problem body, or `ctx.fail(.unprocessable_entity, "detail")` to add details.

## Testing

`kzig.testing.request` runs the full pipeline in-process, no socket:

```zig
test "GET /api/v1/hello" {
    var res = try kzig.testing.request(std.testing.allocator, App, .{ .target = "/api/v1/hello" });
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try std.testing.expectEqualStrings("Hello World from kzig!", body.message);
}
```

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
| `@Controller()` / `@Get('/')` | `pub const routes = .{ … }` on a struct (M2) |
| `@Service()` / `@Autowired()` | a `*Dep` field, wired at compile time (M2) |
| `defineModule({ routes })` | `kzig.Module(.{ .path, .controllers })` (M2) |
| `throw new HttpException(422, …)` | `return ctx.fail(.unprocessable_entity, …)` |
| `createTestApp` + supertest | `kzig.testing.request` |

The full list of deliberate differences is in the [roadmap](./ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). [MIT](./LICENSE) licensed.
