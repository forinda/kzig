# Relations

Relations shape reads only (they emit no DDL): declare them with the schema, and
`client.query(.t)` reads a table and its relations in one statement.

```zig
pub const Schema = kzig.db.Schema(.{ .users = users, .posts = posts, .tags = tags, .post_tags = post_tags }, .{ .relations = .{
    .users = .{ .posts = .{ .many = .posts } }, // joined by the one back, or posts' key to users
    .posts = .{
        .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id} },
        .tags = .{ .many = .tags, .through = .post_tags },
    },
} });

const user = try db.query(.users).findFirst(arena, .{
    .where = kzig.db.eq(.id, id),
    .columns = .{ .passwordHash = false },
    .with = .{ .posts = .{ .orderBy = .{ .{ .createdAt, .desc } }, .limit = 10, .with = .{ .tags = true } } },
});
// user.?.posts[0].tags[0].name — a `one` reads as `?T`, a `many` as `[]const T`
```

`many` finds its join as kick/db does: the `one` back with the same `relation_name`, else the
only untagged one back, else the target's single foreign key; two keys to the same table need a
`relation_name` on each side. A wrong relation name or column is a compile error. The relations
go into `snapshot.json` as kick/db's sidecar. task-api's `workspaces` module reads a workspace
with its owner, members (with their users) and projects this way.
