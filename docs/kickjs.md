# Coming from KickJS

| KickJS | kzig |
| --- | --- |
| `@Controller()` / `@Get('/')` | `pub const routes = .{ … }` on a struct |
| `@Service()` / `@Autowired()` | a `*Dep` field, wired at compile time |
| `defineModule({ routes })` | `kzig.Module(.{ .path, .controllers, .services })` |
| `bootstrap({ modules })` | `kzig.App(.{ .modules, .config })` |
| `loadEnv(zodSchema)` / `@Value('PORT')` | a `Config` struct; inject `*const Config` |
| `@PostConstruct` / `@PreDestroy` | `pub fn init(self: *S) !void` / `pub fn deinit(self: *S) void` |
| `throw new HttpException(422, …)` | `return ctx.fail(.unprocessable_entity, …)` |
| `defineContextDecorator({ key, deps, resolve })` | a struct with `key`, DI fields and `resolve` |
| `ctx.get('tenant')` | a `got: struct { tenant: Tenant }` handler parameter |
| `@Middleware(fn)` / `bootstrap({ middlewares })` | `.middleware = .{fn}` on a route, controller or App |
| `requestId()`, `requestLogger()`, `cors()`, `helmet()` | `kzig.middleware.requestId()`, … |
| `defineAdapter({ beforeMount, onHealthCheck, … })` | a struct with those decls in `.adapters` |
| `definePlugin({ modules, adapters, … })` | `kzig.Plugin(.{ … })` in `.plugins` |
| `app.shutdown()` on SIGTERM | `kzig.runtime.std.serve(…)` + `defer app.deinit()` |
| `SwaggerAdapter({ info })`, `@ApiTags`, `@ApiOperation`, `@ApiResponse` | `kzig.swagger.Plugin(.{ … })`, `docs` / `.docs` data |
| `kick new`, `dev`, `build`, `start`, `g`, `add`, `rm` | `kzig new`, `dev`, `build`, `start`, `g`, `add`, `rm` |
| `bootstrap({ runtime: fastifyRuntime() })` | `@import("kzig_httpz").serve(…)` (`-Dhttpz`) |
| `@Post('/', { body: zodSchema })` / `ctx.body` | `got: struct { body: CreateProject }` |
| `ctx.qs(config)` / `ctx.paginate(…)` | `got.query: kzig.ListQuery(config)` / `query.paginate(…)` |
| `defineSettings('FEATURES', schema)` | a struct with `pub const prefix = "FEATURES"` |
| `createTestApp` + supertest | `app.init` / `initWith` + `kzig.testing.request` |
| `@FileUpload({ maxSize, allowedTypes })` / `ctx.file` | `got: struct { upload: kzig.Upload(.{ … }) }` / `got.upload.file()` |
| `@WsController('/chat')`, `@OnConnect`, `@OnMessage('e')` | a struct in `.gateways` with `path`, `connect`, `events` |
| `ws` in tests | `kzig.testing.WsClient` |
| `@Cron(expr, { timezone, runOnInit, overlap, enabled })` + `KickCronAdapter` | `pub const crons = .{ … }` on a service, scheduled by the App |
| `runCronJobs(container, { name }, 'manual')` | `jobs.run(name, .manual)` on an injected `*kzig.cron.Jobs` |

The full list of deliberate differences is in the [roadmap](https://github.com/forinda/kzig/blob/main/ROADMAP.md).
