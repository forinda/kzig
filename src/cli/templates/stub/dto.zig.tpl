const kzig = @import("kzig");

/// A request body: read it as `got: struct { body: {{Pascal}} }`. Decoding
/// checks the types (422 names each field); `validate` adds the rules types
/// can't say.
pub const {{Pascal}} = struct {
    name: []const u8,

    pub fn validate(self: *const {{Pascal}}, issues: *kzig.Issues) !void {
        if (self.name.len == 0) try issues.add("name", "is required");
    }
};
