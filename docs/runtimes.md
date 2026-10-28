# Runtimes and server defaults

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
stays the default. Against KickJS on Express, on one machine (see [benchmarks](https://github.com/forinda/kzig/tree/main/benchmarks)):

| route | kzig std | kzig http.zig | KickJS / Express |
| --- | ---: | ---: | ---: |
| `GET /api/v1/hello` (minimal-api) | 115,930 req/s | 124,032 req/s | 5,292 req/s |
| `GET /api/v1/json` | 74,808 req/s | 138,609 req/s | 9,296 req/s |
| `POST /api/v1/validate` | 103,002 req/s | 58,799 req/s | 9,487 req/s |

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
