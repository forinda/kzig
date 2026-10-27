const kzig = @import("kzig");

/// `GET /tasks`: `filter=name:contains:x`, `sort=-created_at`, `q=…`,
/// `page`, `limit`.
pub const Query = kzig.ListQuery(.{
    .filterable = &.{"name"},
    .sortable = &.{ "name", "created_at" },
    .searchable = &.{"name"},
});
