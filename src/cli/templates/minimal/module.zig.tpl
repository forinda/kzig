const kzig = @import("kzig");
const {{Pascal}}Controller = @import("{{kebab}}.controller.zig").{{Pascal}}Controller;

pub const {{Pascal}}Module = kzig.Module(.{
    .name = "{{Pascal}}Module",
    .path = "/{{plural}}",
    .controllers = &.{{{Pascal}}Controller},
});
