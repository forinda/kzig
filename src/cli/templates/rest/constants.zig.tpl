const kzig = @import("kzig");

/// `GET /{{plural}}`: `filter=name:contains:x`, `sort=-created_at`, `q=…`,
/// `page`, `limit`.
pub const Query = kzig.ListQuery(.{
    .filterable = &.{"name"},
    .sortable = &.{ "name", "created_at" },
    .searchable = &.{"name"},
});

/// `name` is text: comparison operators (`gt`, `between`, …) are a 400,
/// not a filter that quietly matches everything.
pub fn checkFilters(ctx: *kzig.Ctx, query: Query) !void {
    for (query.filters) |f| switch (f.operator) {
        .eq, .neq, .contains, .starts, .ends => {},
        else => return ctx.fail(.bad_request, "filter: name supports eq, neq, contains, starts and ends"),
    };
}
