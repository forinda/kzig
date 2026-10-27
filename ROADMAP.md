# kzig roadmap

kzig is [KickJS](https://github.com/forinda/kick-js) in Zig: the same modules, controllers,
services, middleware, context contributors, adapters, boot order and request pipeline, built on
`comptime` instead of decorators and runtime metadata. Requires **Zig 0.17.0**.

The bar for "done" is the [examples archive](https://github.com/forinda/kickjs-examples-archive):
each example ports file for file (`hello.module.zig`, `hello.controller.zig`, …), with the same
routes, status codes and tests.

Engines come in this order: the standard library (`std.http.Server` on `std.Io`) first,
[http.zig](https://github.com/karlseguin/http.zig) second, anything else is decided after that.

## Principles

- **Same flow as KickJS.** Boot phases, hook names, middleware phases, contributor precedence
  (method > class > module > adapter > global), `/api/v1` mounting, RFC 9457 problem bodies.
  A KickJS user should recognise every file.
- **Compile errors over boot errors.** A missing service, an unknown handler, a contributor cycle
  or a `ctx.get` of a value no contributor sets fails `zig build`, not the first request.
- **Explicit over global.** Modules are listed, not discovered by import side effects. No global
  container, no `Container.reset()`.
- **Engine-neutral.** User code talks to `Ctx`, never to the engine. Every runtime runs the same
  test suite.
- **Safe at the edge.** Body size, header size, timeouts, connection limits and path
  normalisation are framework defaults, not app code.

## Where KickJS and kzig differ on purpose

| KickJS | kzig | Why |
| --- | --- | --- |
| Decorators + `reflect-metadata` | `pub const routes = .{ … }` tuples, `@typeInfo` | Zig has no decorators; comptime does the same work earlier |
| Global container, import-time registration | Modules listed in `App(.{ .modules })`, wired at comptime | Removes "No provider for X" and test resets |
| DI cycles found at resolve time | Found at compile time | `container.bootstrap()` is a no-op in KickJS |
| `ctx.get('key')` untyped, fails open | Route context type built from its contributors | A dropped contributor is a compile error |
| `AsyncLocalStorage` request store | `*Ctx` passed explicitly, request arena | No hidden state |
| `throw new HttpException(422, details)` | `return ctx.fail(.unprocessable_entity, details)` | Zig errors carry no payload; details live on `ctx` |
| Adapter `shutdown` run concurrently | Run in reverse mount order | A DB adapter must outlive the adapters that use it |
| Typegen, Vite HMR | None; `zig build --watch` | Zig types are already the source of truth |

Kept for parity even where Zig would allow otherwise: route middleware runs **after** validation.

## Milestones

Each milestone ends with tests passing (`zig build test`, no leaks under
`std.testing.allocator`) and `zig fmt --check` clean.

### M0 — Foundation

- [x] Clean `build.zig`: the `kzig` module and `test` step
- [x] `CLAUDE.md`, `CONTRIBUTING.md`, this roadmap
- [x] CI: `zig build test` and `zig fmt --check` on Linux and macOS

### M1 — Core runtime on `std`

- [x] Engine-neutral `Request` / `Response` views; `Ctx` with `params`, `query`, `header`,
      `json`, `text`, `status`, `setHeader`, `noContent`, `created`
- [x] Return-value handlers: a value is 200 JSON, `void` is 204, a type with `sendResponse`
      sends itself
- [x] Router: `:params`, trailing `*`, percent-decoded and normalised paths, 404, 405 with `Allow`
- [x] Problem bodies (`application/problem+json`): error-set → status mapping, `ctx.fail`,
      request id on a 500, details hidden in release builds
- [x] `std` runtime: listener, one task per connection on `Io.Group` (`concurrent`, since
      `async` may run a connection inline and stall accepting), connection cap, keep-alive,
      one arena per connection reset per request
- [x] Limits: max body (413), max header bytes (431), head and body timeouts (per-connection
      watchdog), connection cap
- [x] `kzig.testing`: an in-process runtime that drives the full pipeline without a socket

Follow-ups:

- [ ] `Expect` other than `100-continue` answers 417 instead of closing
- [ ] A malformed chunked body answers 400 instead of closing silently
- [ ] Close the connection when the watchdog task can't be started
- [ ] Arena reset per request keeps at most a bounded capacity
- [ ] Absolute-form request targets (`GET http://host/x`)
- [ ] `Ctx.setHeader` rejects CR/LF and `:` instead of the runtime dropping them
- [ ] Testing runtime matches the server for HEAD and body limits
- [ ] Decide null optional fields in user JSON (KickJS emits `null`)

### M2 — Modules and comptime DI

- [ ] `kzig.Module(.{ .name, .path, .version, .prefix, .controllers, .services })`
- [ ] `kzig.App(.{ .modules, .config, .api_prefix })` flattening modules into one route table
- [ ] Singletons by `*Dep` field type; `init` hooks in dependency order; `deinit` in reverse;
      rollback when an `init` fails part way
- [ ] Compile errors: missing service, unknown handler, duplicate route, dependency cycle
- [ ] Test overrides (`kzig.testing.app(.{ .overrides })`), allowed only in test builds
- [ ] Config: a struct with defaults, filled from env at boot, every bad key reported at once
- [ ] Built-in health module (`/health`)
- [ ] `examples` build step; example tests run under `zig build test`
- [ ] **Acceptance:** `examples/minimal-api` ported with its three tests

### M3 — Middleware and contributors

- [ ] Middleware `fn (*Ctx, *Next) !void` with `next.run()`, so it can wrap the handler
- [ ] Global phases in KickJS order: `beforeGlobal`, global, `afterGlobal`, `beforeRoutes`,
      `afterRoutes`; module, controller and route middleware
- [ ] Contributors: `key`, `depends_on`, `before_validation`, `optional`, DI deps; precedence and
      comptime topo sort
- [ ] Typed `ctx.get(.key)` per route
- [ ] Built-ins: `requestId`, `requestLogger`, `cors`, `helmet`
- [ ] **Acceptance:** a tenant contributor port of `multi-tenant-kickdb-api`'s request flow
      (in memory, no DB)

### M4 — Validation and bodies

- [ ] Route `.body`, `.query`, `.params` types parsed with `std.json` / field parsers
- [ ] 422 problem body with field errors; validators declared on the type (`pub fn validate`)
- [ ] Query helpers: filters, sort, pagination (`ctx.qs`, `ctx.paginate`)
- [ ] Module settings (`defineSettings` equivalent)
- [ ] **Acceptance:** `examples/settings-api` (minus DevTools)

### M5 — Lifecycle

- [ ] Adapters: `beforeMount`, `middleware`, `contributors`, `onRouteMount`, `beforeStart`,
      `afterStart`, `onError`, `onResponse`, `onHealthCheck`, `shutdown`; `depends_on` order
- [ ] Plugins bundling modules, adapters, middleware and contributors
- [ ] Request and transient scopes, torn down with the request
- [ ] Graceful shutdown: SIGINT/SIGTERM, stop accepting, drain with timeout, adapters in
      reverse, services `deinit`
- [ ] **Acceptance:** shutdown drains an in-flight request; adapter hook order matches KickJS

### M6 — http.zig runtime

- [ ] `kzig.runtime.httpz` behind the same seam, through its `dispatch` hook
- [ ] The whole suite runs on both runtimes
- [ ] Benchmark both runtimes against KickJS on Express and Fastify
- [ ] **Acceptance:** every ported example passes on both runtimes

### Later — decided after M6

Radix-tree router, SSE, multipart uploads (`file-storage-api`), WebSockets (`ws-chat`), OpenAPI
from comptime metadata (swagger), cron (`cron-jobs-api`), queues, a `kzig` CLI with
`new` / `g module`, database layer, a third engine (`io_uring`, edge).

## Open questions

Settled in the milestone that first needs them:

- Cancelling the accept loop and signal handling under `std.Io` (M5)
- How a route's context type is spelled in handler signatures (M3)
- Dispatch by `*anyopaque` thunk or by a comptime `switch`, measured on compile time (M2)
