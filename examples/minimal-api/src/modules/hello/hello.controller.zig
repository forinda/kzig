const kzig = @import("kzig");
const HelloService = @import("hello.service.zig").HelloService;

// Return-value handlers: what a handler returns is sent as 200 JSON.
pub const HelloController = struct {
    hello: *HelloService,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
        .{ .method = .GET, .path = "/health", .handler = "health" },
    };

    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !HelloService.Greeting {
        return self.hello.greet(ctx.arena, "World");
    }

    pub fn health(self: *HelloController, _: *kzig.Ctx) HelloService.Health {
        return self.hello.healthCheck();
    }
};
