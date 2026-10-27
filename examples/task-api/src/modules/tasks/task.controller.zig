const kzig = @import("kzig");
const repo = @import("task.repository.zig");
const Query = @import("task.constants.zig").Query;
const TaskService = @import("task.service.zig").TaskService;

const Id = struct { id: u64 };

pub const TaskController = struct {
    service: *TaskService,

    pub const docs = .{ .tags = &[_][]const u8{"Tasks"} };

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list", .docs = .{ .summary = "List tasks" } },
        .{ .method = .GET, .path = "/:id", .handler = "get", .docs = .{ .summary = "Get a task" } },
        .{ .method = .POST, .path = "/", .handler = "create", .docs = .{
            .summary = "Create a task",
            .responses = .{.{ .status = 201, .description = "Created", .body = repo.Task }},
        } },
        .{ .method = .PATCH, .path = "/:id", .handler = "update", .docs = .{ .summary = "Update a task" } },
        .{ .method = .DELETE, .path = "/:id", .handler = "remove", .docs = .{ .summary = "Delete a task" } },
    };

    pub fn list(self: *TaskController, ctx: *kzig.Ctx, got: struct { query: Query }) !kzig.Paginated(repo.Task) {
        const page = try self.service.list(ctx.arena, got.query);
        return got.query.paginate(ctx, repo.Task, page.rows, page.total);
    }

    pub fn get(self: *TaskController, _: *kzig.Ctx, got: struct { params: Id }) !repo.Task {
        return self.service.get(got.params.id);
    }

    pub fn create(self: *TaskController, ctx: *kzig.Ctx, got: struct { body: repo.CreateTask }) !void {
        try ctx.created(try self.service.create(got.body));
    }

    pub fn update(self: *TaskController, _: *kzig.Ctx, got: struct { params: Id, body: repo.UpdateTask }) !repo.Task {
        return self.service.update(got.params.id, got.body);
    }

    /// 204 when it returns.
    pub fn remove(self: *TaskController, _: *kzig.Ctx, got: struct { params: Id }) !void {
        try self.service.remove(got.params.id);
    }
};
