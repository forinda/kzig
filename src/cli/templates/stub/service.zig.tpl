/// Add it to a module's `.services`; inject it with a `*{{Pascal}}Service` field.
pub const {{Pascal}}Service = struct {
    pub fn hello(_: *{{Pascal}}Service) []const u8 {
        return "{{kebab}}";
    }
};
