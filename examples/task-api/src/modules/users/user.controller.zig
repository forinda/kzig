const std = @import("std");
const kzig = @import("kzig");
const repo = @import("user.repository.zig");

const UserId = struct {
    id: []const u8,

    /// Not a UUID: no such user, rather than a database error.
    pub fn validate(self: *const UserId, issues: *kzig.Issues) !void {
        if (self.id.len != 36) return issues.add("id", "must be a UUID");
        for (self.id, 0..) |c, i| {
            const dash = i == 8 or i == 13 or i == 18 or i == 23;
            if (if (dash) c != '-' else !std.ascii.isHex(c)) return issues.add("id", "must be a UUID");
        }
    }
};

pub const UserController = struct {
    users: *repo.UserRepository,

    pub const docs = .{ .tags = &[_][]const u8{"Users"} };

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list", .docs = .{ .summary = "List users" } },
        .{ .method = .GET, .path = "/:id", .handler = "show", .docs = .{
            .summary = "Get a user",
            .responses = .{ .{ .status = 200, .description = "The user", .body = repo.User }, .{ .status = 404, .description = "No such user" } },
        } },
        .{ .method = .POST, .path = "/", .handler = "create", .docs = .{
            .summary = "Create a user",
            .responses = .{ .{ .status = 201, .description = "Created", .body = repo.User }, .{ .status = 409, .description = "Email taken" } },
        } },
    };

    pub fn list(self: *UserController, ctx: *kzig.Ctx) !struct { users: []const repo.User } {
        return .{ .users = try self.users.list(ctx.arena) };
    }

    pub fn show(self: *UserController, ctx: *kzig.Ctx, got: struct { params: UserId }) !repo.User {
        return try self.users.findById(ctx.arena, got.params.id) orelse ctx.fail(.not_found, null);
    }

    pub fn create(self: *UserController, ctx: *kzig.Ctx, got: struct { body: repo.NewUser }) !void {
        try ctx.created(try self.users.create(ctx.arena, got.body));
    }
};
