const kzig = @import("kzig");

/// Add it to `.middleware` on the App, a controller or a route.
pub fn {{camelId}}(ctx: *kzig.Ctx, next: *kzig.Next) !void {
    // Before the rest of the chain.
    next.run();
    // After: ctx.res holds the final response.
    _ = ctx;
}
