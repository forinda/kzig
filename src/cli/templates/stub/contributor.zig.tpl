const kzig = @import("kzig");

/// Add it to `.contributors`; read it with `got: struct { {{snake}}: []const u8 }`.
pub const Load{{Pascal}} = struct {
    pub const key = "{{snake}}";

    pub fn resolve(_: *Load{{Pascal}}, ctx: *kzig.Ctx) ![]const u8 {
        return ctx.header("x-{{kebab}}") orelse error.Unauthorized;
    }
};
