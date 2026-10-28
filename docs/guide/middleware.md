# Middleware and contributors

From the `projects` module:

```zig
/// A context contributor: a service with a `key` and a `resolve`.
pub const LoadTenant = struct {
    pub const key = "tenant";
    repo: *TenantRepository,

    // Reading `user` makes LoadAuthUser run first; no `dependsOn` list.
    pub fn resolve(self: *LoadTenant, ctx: *kzig.Ctx, got: struct { user: AuthUser }) !Tenant { … }
};

pub const ProjectController = struct {
    projects: *ProjectRepository,
    pub const contributors = .{ LoadTenant, LoadAuthUser };
    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list" },
        .{ .method = .POST, .path = "/", .handler = "create" },
    };

    // `got.tenant` is typed; drop LoadTenant above and this doesn't compile.
    pub fn list(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: Tenant }) !Projects { … }

    // `body` is decoded from JSON and validated before the handler runs.
    pub fn create(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: Tenant, body: CreateProject }) !void { … }
};
```

Middleware is `fn (ctx: *kzig.Ctx, next: *kzig.Next) !void` (or a service struct with that
`handle`), registered on the App, a controller (`pub const middleware`) or a route
(`.middleware`). Code after `next.run()` sees the final response, errors included. Contributors
register on the App, a module, a controller or a route; the more specific one wins for a key.
On a matched route the order is: `before_validation` contributors, request decoding, then
controller and route middleware around the other contributors and the handler. A contributor or
middleware that answers (or sets a status and returns) ends the request there.

Services, middleware and contributors are app-wide singletons shared by concurrent requests:
keep per-request data on `ctx`, and guard shared state with atomics or a lock.
