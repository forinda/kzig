# CLAUDE.md — kzig Development Guide

## Project Overview

kzig is KickJS ported to Zig: modules, controllers, services, middleware, context contributors
and adapters with KickJS's boot order and request pipeline, built on `comptime` instead of
decorators. Requires **Zig 0.17.0**. [`ROADMAP.md`](./ROADMAP.md) is the plan and the list of
deliberate differences from KickJS — read it before starting work.

References (clone them to read the source; `CLAUDE.local.md`, git-ignored, can point at your
local checkouts):

- [forinda/kick-js](https://github.com/forinda/kick-js) — the TypeScript framework being
  ported. Its flow is the spec: boot in `packages/kickjs/src/http/application.ts`, the per-route
  pipeline in `packages/kickjs/src/http/runtimes/express.ts`, contributors in
  `packages/kickjs/src/core/contributor-pipeline.ts`, errors in
  `packages/kickjs/src/http/middleware/error-handler.ts`, DI in `packages/di/src/container.ts`.
- [forinda/kickjs-examples-archive](https://github.com/forinda/kickjs-examples-archive) — the
  acceptance suite. Each example ports file for file.
- [cztomsik/tokamak](https://github.com/cztomsik/tokamak) — Zig framework on http.zig; source of
  the comptime DI and route-reflection ideas.
- [karlseguin/http.zig](https://github.com/karlseguin/http.zig) — the second runtime (M6).

When porting a feature, read the KickJS source for it first and match its behaviour (order,
status codes, error bodies). A deliberate difference goes in the roadmap's "differ on purpose"
table.

## Quick Commands

```bash
zig build              # Build
zig build test         # Run all tests (std runtime)
zig build test -Dhttpz # …plus the http.zig runtime (fetches http.zig)
zig build bench -Dhttpz -Doptimize=ReleaseFast && ./benchmarks/run.sh
zig fmt build.zig src examples tests benchmarks              # Format
zig fmt --check build.zig build.zig.zon src examples tests benchmarks      # Check formatting
zig build --watch      # Rebuild on change
```

## Repository Structure

```
src/
  root.zig             # Public API — re-exports only, selective
  app.zig              # App(.{ … }), Module(.{ … }), Plugin(.{ … }), boot and shutdown
  adapter.zig          # Adapter hooks, ordering, StartInfo/RouteInfo
  di.zig               # Comptime container
  contributor.zig      # Context contributors: precedence, order, typed `got` values
  config.zig           # Config and settings sections from env
  decode.zig           # JSON/strings into types with field issues
  query.zig            # ListQuery (filter/sort/page) and Paginated
  health.zig           # Built-in /health/live, /health/ready
  context.zig          # Ctx, Request/Response views, return-value send
  router.zig           # Route table, matching, 404/405
  problem.zig          # RFC 9457 problem bodies, error-set → status
  middleware.zig       # Next chain; re-exports the built-ins
  middleware/          # requestId, requestLogger, cors, helmet
  runtime/std.zig      # std.http.Server engine
  runtime/httpz.zig    # http.zig engine (module kzig_httpz, -Dhttpz)
  runtime/conformance.zig # Socket behaviour every runtime must pass
  runtime/wire.zig     # Response rules every runtime applies
  testing.zig          # In-process runtime and assertions
examples/task-api/     # The one example app; grows each milestone
benchmarks/            # bench.zig servers + run.sh against KickJS
tests/compile_errors/  # Fixtures that must fail to compile (listed in build.zig)
```

Files appear as their milestone lands; don't scaffold ahead.

## Zig 0.17 Notes

The API moved a lot; these bite first:

- `@Type` is gone: use `@Struct`, `@Tuple`, `@Union`, `@Enum`, `@Pointer`, `@Int`.
- `@typeInfo(T).@"struct"` gives parallel arrays (`field_names`, `field_types`, `field_attrs`,
  `decl_names`); defaults come from `attrs.defaultValue(FieldType)`. `std.meta.fields` is a
  compile error.
- `main(init: std.process.Init)` provides `init.io`, `init.gpa`, `init.arena`.
- Networking: `std.Io.net.IpAddress.parse(host, port)` → `.listen(io, .{ .reuse_address = true })`
  → `accept(io)` → `Stream.reader(io, buf)` / `.writer(io, buf)`.
- HTTP: `std.http.Server.init(&reader.interface, &writer.interface)`, `receiveHead()`,
  `request.respond(body, .{ .status, .extra_headers })`.
- Concurrency: `Io.Group` with `.async` / `.concurrent` / `.await` / `.cancel`.
- Slices joined with `++` must be comptime-known, so route prefixes are comptime.
- `std.mem.indexOf*` are deprecated aliases: use `find`, `findScalar`, `findAny`, `findScalarLast`,
  `findScalarPos`. `std.fmt.allocPrint` / `bufPrint` → `allocator.print(…)` / `std.mem.print(buf, …)`.
- `**` (array repetition) is gone; `@splat` a fixed array instead.

Verify std API against the installed source (`zig env` → `lib_dir`) rather than memory.

## Key Patterns

### Controllers

```zig
pub const HelloController = struct {
    hello: *HelloService,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
        .{ .method = .GET, .path = "/health", .handler = "health" },
    };

    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !Greeting {
        _ = ctx;
        return self.hello.greet("World");
    }
};
```

### Modules

```zig
pub const HelloModule = kzig.Module(.{
    .name = "HelloModule",
    .path = "/hello",
    .controllers = &.{HelloController},
    .services = &.{HelloService},
});
```

### Errors

Handlers return error unions. Use the framework error set for HTTP statuses; carry details with
`return ctx.fail(status, details)`. Anything else becomes a logged 500 with the request id.

### Adapters

Any struct with optional decls: `beforeMount`, `middleware`, `contributors`, `onRouteMount`,
`beforeStart`, `afterStart`, `onError`, `onResponse`, `onHealthCheck`, `shutdown`. Missing ones
are skipped via `@hasDecl`. Keep KickJS's names.

## Code Style

- `zig fmt` formats. Run it before committing.
- Comments say why, not what. Match the density of the surrounding code.
- Fail at comptime with `@compileError` naming the type and field
  (`"UserService.repo: no service UserRepo"`), not at runtime.
- No allocation without an owner: app lifetime → `gpa`, request lifetime → the request arena.
- Runtime code stays engine-neutral: only `src/runtime/*` touches `std.http` or `httpz`.
- No dependency without a reason in the commit message; the `std` runtime has none.

## Testing

- `zig build test` runs everything; tests sit next to the code (`test "…"` blocks) and in
  `examples/*`.
- Use `std.testing.allocator` — a leak fails the test.
- A bug fix comes with a test that fails without it.
- Pipeline behaviour is tested through `kzig.testing` (full router, middleware and contributors,
  no socket). From M6 on, behaviour tests run on every runtime.
- Compile-error guarantees are checked with a small negative-compile test, not by hand.

## Git Workflow

Pre-1.0, work commits straight to `main`:

```bash
git checkout main && git pull
# … change, test, format …
git commit -m "feat: router with :params and 405"
```

Keep commits to one change. Tick the roadmap item in the same commit that lands it.

### Commit convention

```
feat: description      # New feature
fix: description       # Bug fix
docs: description      # Documentation only
chore: description     # Maintenance
refactor: description  # Code restructuring
ci: description        # CI changes
test: description      # Test changes
```

### No AI co-author trailers in commits

Commit messages carry no `Co-Authored-By:` trailer naming an AI assistant. A PR body may say it
was generated with an assistant; the commits stay clean.

### PR / issue bodies with markdown — always via a temp file

Write rich bodies to a file and pass `--body-file`; never inline multi-line markdown in
`gh … --body "…"`.

## Important Notes

- Design docs, specs, plans and experiment notes live in the git-ignored `.ignored/designs/`
  and are never referenced from tracked files. `ROADMAP.md` is the public plan.
- Keep `ROADMAP.md` true: tick items as they land, move settled open questions into the
  relevant milestone.
- There is one example app, `examples/task-api`. A milestone adds modules to it rather than a
  new app; read the KickJS archive example first and port its tests with the same paths and
  status codes.
