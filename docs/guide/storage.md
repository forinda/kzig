# Storage

KickJS's `@forinda/kickjs-storage`: one `kzig.storage.Storage` over memory, a disk folder or an S3
bucket (AWS, R2, MinIO, SeaweedFS).

```zig
var s3: kzig.storage.S3 = try .fromSettings(io, gpa, settings); // S3_BUCKET, S3_ENDPOINT, …
defer s3.deinit();
const files = s3.storage();
try files.put("files/a.png", bytes, .{ .content_type = "image/png" });
const page = try files.list(arena, .{ .prefix = "files/", .limit = 100 });
const link = try files.url(arena, "files/a.png", .{ .expires_in = 300 }); // presigned GET
```

`get` and `stat` answer null for a missing file, `delete` of one is fine, and `list` pages with a
cursor. Requests are signed with SigV4 by kzig itself (no SDK). A bucket that can't be reached,
answers 5xx or takes longer than `timeout_ms` (30 s) is `error.ServiceUnavailable`, a 503; an
object over `max_object_bytes` (256 MiB) isn't read. The disk driver refuses keys that pass
through a symbolic link. task-api's `files` module picks
the driver from `STORAGE_DRIVER`.
