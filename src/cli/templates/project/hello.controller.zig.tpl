const kzig = @import("kzig");
const HelloService = @import("hello.service.zig").HelloService;

pub const HelloController = struct {
    hello: *HelloService,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "index" },
    };

    /// What a handler returns is sent as 200 JSON.
    pub fn index(self: *HelloController, ctx: *kzig.Ctx) !HelloService.Greeting {
        return self.hello.greet(ctx.arena, "World");
    }
};
