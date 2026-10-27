const kzig = @import("kzig");
const TaskController = @import("task.controller.zig").TaskController;
const TaskService = @import("task.service.zig").TaskService;
const TaskRepository = @import("task.repository.zig").TaskRepository;

pub const TaskModule = kzig.Module(.{
    .name = "TaskModule",
    .path = "/tasks",
    .controllers = &.{TaskController},
    .services = &.{ TaskService, TaskRepository },
});
