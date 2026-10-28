# OpenAPI and Swagger UI

The spec comes from the types: path params, `query` / `params` / `body` structs and handler
return types become parameters, request bodies and response schemas, at compile time.

```zig
.plugins = &.{kzig.swagger.Plugin(.{
    .info = .{ .title = "task-api", .version = "0.1.0" },
    .disable_in_prod = true,
})},

pub const ProjectController = struct {
    pub const docs = .{ .tags = &[_][]const u8{"Projects"}, .bearer_auth = true };
    pub const routes = .{
        .{ .method = .POST, .path = "/", .handler = "create", .docs = .{
            .summary = "Create a project",
            .responses = .{.{ .status = 201, .description = "Created", .body = Project }},
        } },
    };
    …
};
```

`/openapi.json` (OpenAPI 3.0.3), `/docs` (Swagger UI) and `/redoc`. Doc options are data on the
controller (`pub const docs`) and the route (`.docs`): `tags`, `summary`, `description`,
`operation_id`, `deprecated`, `responses`, `bearer_auth`, `exclude`.
