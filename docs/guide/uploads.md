# File uploads

KickJS's `@FileUpload`: read `upload` in `got`, and the multipart body is parsed for you.

```zig
const Avatar = kzig.Upload(.{ .field = "file", .max_size = 2 * 1024 * 1024, .allowed_types = &.{ "png", "jpg" } });

pub fn upload(self: *FilesController, ctx: *kzig.Ctx, got: struct { upload: Avatar }) !void {
    const file = got.upload.file() orelse return ctx.fail(.bad_request, "Send the file in the `file` form field");
    // file.filename is a UUID plus the extension of its type, never the client's name.
    try ctx.created(try self.files.save(ctx.arena, file.filename, file.data));
}
```

A type outside `allowed_types` (extensions, MIME types, `image/*`) is 415, a file over
`max_size` or more than `max_count` files is 413, a broken body 400; text fields are in
`upload.fields`. The whole request is still bounded by the server's `max_body_bytes`. Send
bytes back with `ctx.bytes(content_type, data)`. task-api's `files` module is
[file-storage-api](https://github.com/forinda/kickjs-examples-archive) on disk: API key, signed
download links.
