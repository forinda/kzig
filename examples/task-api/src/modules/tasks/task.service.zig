const std = @import("std");
const repo = @import("task.repository.zig");
const constants = @import("task.constants.zig");

pub const TaskService = struct {
    repo: *repo.TaskRepository,

    pub fn list(self: *TaskService, arena: std.mem.Allocator, query: constants.Query) !repo.TaskPage {
        return self.repo.findAll(arena, query);
    }

    pub fn get(self: *TaskService, id: u64) !repo.Task {
        return self.repo.findById(id) orelse error.NotFound;
    }

    pub fn create(self: *TaskService, input: repo.CreateTask) !repo.Task {
        return self.repo.create(input);
    }

    pub fn update(self: *TaskService, id: u64, input: repo.UpdateTask) !repo.Task {
        return (try self.repo.update(id, input)) orelse error.NotFound;
    }

    pub fn remove(self: *TaskService, id: u64) !void {
        if (!self.repo.delete(id)) return error.NotFound;
    }
};
