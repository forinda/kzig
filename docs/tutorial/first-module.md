# 2. A first module

```console
$ kzig g module bookmark
  create src/modules/bookmarks/bookmark.module.zig
  create src/modules/bookmarks/bookmark.controller.zig
  create src/modules/bookmarks/bookmark.service.zig
  create src/modules/bookmarks/bookmark.repository.zig
  create src/modules/bookmarks/bookmark.constants.zig
  create src/modules/bookmarks/bookmark.test.zig
  update src/modules.zig
  update src/main.zig
Mounted at /api/v1/bookmarks
$ zig build test
```

That's KickJS's REST module: list (filter, sort, page), get, create, update, delete, with tests,
over an in-memory repository. Try it:

```console
$ curl -H 'content-type: application/json' -d '{"name":"Zig"}' localhost:3000/api/v1/bookmarks
{"id":1,"name":"Zig","created_at":1793156653000,"updated_at":1793156653000}
$ curl 'localhost:3000/api/v1/bookmarks?q=zi&sort=-created_at'
{"data":[{"id":1,"name":"Zig",…}],"meta":{"page":1,"limit":20,"total":1,…},"links":{…}}
$ curl -H 'content-type: application/json' -d '{"name":""}' localhost:3000/api/v1/bookmarks
{"type":"about:blank","title":"Unprocessable Entity","status":422,"detail":"must be 1 to 200 characters","errors":[{"field":"name","message":"must be 1 to 200 characters"}]}
```

## How the pieces fit

The **module** names what it mounts and what it owns:

```zig title="src/modules/bookmarks/bookmark.module.zig"
const kzig = @import("kzig");
const BookmarkController = @import("bookmark.controller.zig").BookmarkController;
const BookmarkService = @import("bookmark.service.zig").BookmarkService;
const BookmarkRepository = @import("bookmark.repository.zig").BookmarkRepository;

pub const BookmarkModule = kzig.Module(.{
    .name = "BookmarkModule",
    .path = "/bookmarks",
    .controllers = &.{BookmarkController},
    .services = &.{ BookmarkService, BookmarkRepository },
});
```

The **controller** lists its routes as data. A handler's parameters say what it needs: `got.params`
is the path's `:id` parsed into a struct, `got.body` the JSON body decoded and validated,
`got.query` the list query. What a handler returns is the response: a struct is 200 JSON,
`void` is 204, `error.NotFound` is a 404 problem body.

```zig
pub fn create(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { body: repo.CreateBookmark }) !void {
    try ctx.created(try self.service.create(got.body)); // 201
}
```

The **service** holds the logic; the **repository** holds the data. Each is a struct whose
pointer fields are other services, injected by type when the app boots:

```zig
pub const BookmarkService = struct {
    repo: *repo.BookmarkRepository, // a service not listed in a module is a compile error
    …
};
```

Change `repo` to a type no module lists and `zig build` stops with
`BookmarkService.repo: no service …`, before anything runs.

The repository keeps rows in memory, so they're gone on restart. Next, [a database](database.md).
