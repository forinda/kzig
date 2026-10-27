const std = @import("std");

pub const HelloService = struct {
    pub const Greeting = struct { message: []const u8 };

    pub fn greet(_: *HelloService, arena: std.mem.Allocator, name: []const u8) !Greeting {
        return .{ .message = try arena.print("Hello {s} from kzig!", .{name}) };
    }
};
