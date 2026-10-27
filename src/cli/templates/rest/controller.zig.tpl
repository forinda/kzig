const kzig = @import("kzig");
const repo = @import("{{kebab}}.repository.zig");
const constants = @import("{{kebab}}.constants.zig");
const {{Pascal}}Service = @import("{{kebab}}.service.zig").{{Pascal}}Service;

const Id = struct { id: u64 };

pub const {{Pascal}}Controller = struct {
    service: *{{Pascal}}Service,

    pub const docs = .{ .tags = &[_][]const u8{"{{PluralPascal}}"} };

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list", .docs = .{ .summary = "List {{plural}}" } },
        .{ .method = .GET, .path = "/:id", .handler = "get", .docs = .{ .summary = "Get a {{kebab}}" } },
        .{ .method = .POST, .path = "/", .handler = "create", .docs = .{
            .summary = "Create a {{kebab}}",
            .responses = .{.{ .status = 201, .description = "Created", .body = repo.{{Pascal}} }},
        } },
        .{ .method = .PATCH, .path = "/:id", .handler = "update", .docs = .{ .summary = "Update a {{kebab}}" } },
        .{ .method = .DELETE, .path = "/:id", .handler = "remove", .docs = .{ .summary = "Delete a {{kebab}}" } },
    };

    pub fn list(self: *{{Pascal}}Controller, ctx: *kzig.Ctx, got: struct { query: constants.Query }) !kzig.Paginated(repo.{{Pascal}}) {
        const page = try self.service.list(ctx.arena, got.query);
        return got.query.paginate(ctx, repo.{{Pascal}}, page.rows, page.total);
    }

    pub fn get(self: *{{Pascal}}Controller, _: *kzig.Ctx, got: struct { params: Id }) !repo.{{Pascal}} {
        return self.service.get(got.params.id);
    }

    pub fn create(self: *{{Pascal}}Controller, ctx: *kzig.Ctx, got: struct { body: repo.Create{{Pascal}} }) !void {
        try ctx.created(try self.service.create(got.body));
    }

    pub fn update(self: *{{Pascal}}Controller, _: *kzig.Ctx, got: struct { params: Id, body: repo.Update{{Pascal}} }) !repo.{{Pascal}} {
        return self.service.update(got.params.id, got.body);
    }

    /// 204 when it returns.
    pub fn remove(self: *{{Pascal}}Controller, _: *kzig.Ctx, got: struct { params: Id }) !void {
        try self.service.remove(got.params.id);
    }
};
