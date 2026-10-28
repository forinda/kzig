# Adapters, plugins and shutdown

An adapter is a service with optional KickJS hooks — `beforeMount`, `onRouteMount`,
`beforeStart`, `afterStart`, `onError`, `onResponse`, `onHealthCheck`, `shutdown` — plus
`depends_on`, phased `middleware`, `contributors` and `settings`:

```zig
pub fn MailAdapter(comptime name: []const u8, comptime Settings: type) type {
    return struct {
        pub const settings = &.{Settings}; // read and validated because this adapter is mounted
        mail: *const Settings,
        process: *const kzig.Process,

        /// Part of /health/ready: 503 "degraded" when any check is down.
        pub fn onHealthCheck(self: *@This()) kzig.HealthCheck {
            return .{ .name = "MailAdapter:" ++ name, .status = if (self.reachable()) .up else .down };
        }
        …
    };
}
```

```console
$ curl -i localhost:3000/health/ready
HTTP/1.1 503 Service Unavailable
{"status":"degraded","checks":[{"name":"MailAdapter:transactional","status":"down"},{"name":"MailAdapter:marketing","status":"down"}]}
```

`kzig.Plugin(.{ .modules, .adapters, .middleware, .contributors, .settings })` bundles them.
On SIGINT/SIGTERM `serve` stops accepting new connections, requests in flight finish (their
sockets are cut after `shutdown_timeout_ms`, 30 s; a handler still running a second later makes
the process exit with status 1 rather than free services under it) and idle connections close;
then `app.deinit()` runs adapters' `shutdown` in reverse dependency order. `/health/*` answer
`draining` from the moment shutdown begins, to requests already in flight. `/health/ready` runs
every adapter's check at once, counts one slower than 2 s as down, and shares a run between
probes within a second. A contributor's `dispose(self, *V)` runs when its handler returns,
before the response is written — a response body must not borrow memory `dispose` frees.
