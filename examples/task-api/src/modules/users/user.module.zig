const kzig = @import("kzig");
const UserController = @import("user.controller.zig").UserController;
const UserRepository = @import("user.repository.zig").UserRepository;
const db = @import("../../db/database.zig");

/// task-kickdb-api's users, on Postgres.
pub const UserModule = kzig.Module(.{
    .name = "UserModule",
    .path = "/users",
    .controllers = &.{UserController},
    .services = &.{ UserRepository, db.Database },
    .settings = &.{ kzig.db.Settings, db.DbSettings },
});
