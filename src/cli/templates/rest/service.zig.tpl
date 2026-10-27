const std = @import("std");
const repo = @import("{{kebab}}.repository.zig");
const constants = @import("{{kebab}}.constants.zig");

pub const {{Pascal}}Service = struct {
    repo: *repo.{{Pascal}}Repository,

    pub fn list(self: *{{Pascal}}Service, arena: std.mem.Allocator, query: constants.Query) !repo.{{Pascal}}Page {
        return self.repo.findAll(arena, query);
    }

    pub fn get(self: *{{Pascal}}Service, id: u64) !repo.{{Pascal}} {
        return self.repo.findById(id) orelse error.NotFound;
    }

    pub fn create(self: *{{Pascal}}Service, input: repo.Create{{Pascal}}) !repo.{{Pascal}} {
        return self.repo.create(input);
    }

    pub fn update(self: *{{Pascal}}Service, id: u64, input: repo.Update{{Pascal}}) !repo.{{Pascal}} {
        return (try self.repo.update(id, input)) orelse error.NotFound;
    }

    pub fn remove(self: *{{Pascal}}Service, id: u64) !void {
        if (!self.repo.delete(id)) return error.NotFound;
    }
};
