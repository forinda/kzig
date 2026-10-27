const kzig = @import("kzig");
const {{Pascal}}Controller = @import("{{kebab}}.controller.zig").{{Pascal}}Controller;
const {{Pascal}}Service = @import("{{kebab}}.service.zig").{{Pascal}}Service;
const {{Pascal}}Repository = @import("{{kebab}}.repository.zig").{{Pascal}}Repository;

pub const {{Pascal}}Module = kzig.Module(.{
    .name = "{{Pascal}}Module",
    .path = "/{{plural}}",
    .controllers = &.{{{Pascal}}Controller},
    .services = &.{ {{Pascal}}Service, {{Pascal}}Repository },
});
