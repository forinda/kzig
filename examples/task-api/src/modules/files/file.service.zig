const std = @import("std");
const kzig = @import("kzig");
const FileSettings = @import("file.settings.zig").FileSettings;
const clock = @import("../../clock.zig");
pub const Clock = clock.Clock;
const iso = clock.iso;

const Io = std.Io;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// What may be uploaded, and the extension each type is stored under.
pub const allowed = [_][2][]const u8{
    .{ "image/png", "png" },
    .{ "image/jpeg", "jpg" },
    .{ "application/pdf", "pdf" },
    .{ "text/plain", "txt" },
};

/// `<uuid>.<ext>`: ids we generate, never the client's file name.
pub fn isFileId(id: []const u8) bool {
    if (id.len < 38 or id[36] != '.') return false;
    for (id[0..36]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) if (c != '-') return false;
    for (id[37..]) |c| if (!std.ascii.isLower(c)) return false;
    return true;
}

/// file-storage-api's `FilesService` on its disk driver: files live in
/// `<UPLOAD_DIR>/files/<id>`, the folder made on the first upload.
pub const FilesService = struct {
    process: *const kzig.Process,
    settings: *const FileSettings,
    clock: *Clock,

    // ponytail: opens the folder per call; keep it open if that shows up.
    fn folder(self: *FilesService, create: bool) !?Io.Dir {
        const io = self.process.io;
        const path = try std.fs.path.join(self.process.gpa, &.{ self.settings.upload_dir, "files" });
        defer self.process.gpa.free(path);
        if (create) return try Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
        return Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    pub const Saved = struct { id: []const u8, size: usize, contentType: []const u8 };

    /// `content_type` is one of `allowed` (the upload checked it).
    pub fn save(self: *FilesService, arena: std.mem.Allocator, data: []const u8, content_type: []const u8) !Saved {
        const media = std.mem.trim(u8, content_type[0 .. std.mem.findScalar(u8, content_type, ';') orelse content_type.len], " ");
        const ext = for (allowed) |a| {
            if (std.ascii.eqlIgnoreCase(a[0], media)) break a[1];
        } else return error.UnsupportedType;
        const id = try arena.print("{s}.{s}", .{ &kzig.multipart.uuid(self.process.io), ext });
        var dir = (try self.folder(true)).?;
        defer dir.close(self.process.io);
        try dir.writeFile(self.process.io, .{ .sub_path = id, .data = data });
        return .{ .id = id, .size = data.len, .contentType = typeOf(id) };
    }

    pub const Listed = struct { id: []const u8, size: u64, contentType: []const u8, lastModified: []const u8 };
    pub const Page = struct { files: []const Listed, cursor: ?[]const u8 };

    /// 100 at a time, by id; `cursor` is the last id of the previous page.
    pub fn list(self: *FilesService, arena: std.mem.Allocator, cursor: ?[]const u8) !Page {
        const io = self.process.io;
        var dir = try self.folder(false) orelse return .{ .files = &.{}, .cursor = null };
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !isFileId(entry.name)) continue;
            if (cursor) |c| if (std.mem.order(u8, entry.name, c) != .gt) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        const page = names.items[0..@min(names.items.len, 100)];
        const files = try arena.alloc(Listed, page.len);
        for (page, files) |name, *f| {
            const st = try dir.statFile(io, name, .{});
            f.* = .{ .id = name, .size = st.size, .contentType = typeOf(name), .lastModified = try iso(arena, @intCast(@divTrunc(st.mtime.toNanoseconds(), std.time.ns_per_s))) };
        }
        return .{ .files = files, .cursor = if (names.items.len > page.len) page[page.len - 1] else null };
    }

    pub const Opened = struct { data: []const u8, content_type: []const u8 };

    pub fn open(self: *FilesService, arena: std.mem.Allocator, id: []const u8) !?Opened {
        var dir = try self.folder(false) orelse return null;
        defer dir.close(self.process.io);
        const data = dir.readFileAlloc(self.process.io, id, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return .{ .data = data, .content_type = typeOf(id) };
    }

    pub fn exists(self: *FilesService, id: []const u8) bool {
        var dir = (self.folder(false) catch return false) orelse return false;
        defer dir.close(self.process.io);
        dir.access(self.process.io, id, .{}) catch return false;
        return true;
    }

    pub fn remove(self: *FilesService, id: []const u8) !bool {
        var dir = try self.folder(false) orelse return false;
        defer dir.close(self.process.io);
        dir.deleteFile(self.process.io, id) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub const Link = struct { url: []const u8, expiresAt: []const u8 };

    /// Disk has no signer: the app signs `/files/:id/signed?expires=&sig=`.
    pub fn signedUrl(self: *FilesService, arena: std.mem.Allocator, id: []const u8, expires_in: u32, origin: []const u8) !Link {
        const expires = self.clock.now() + expires_in;
        const sig = self.sign(id, expires);
        return .{
            .url = try arena.print("{s}/api/v1/files/{s}/signed?expires={d}&sig={s}", .{ std.mem.trimEnd(u8, origin, "/"), id, expires, &sig }),
            .expiresAt = try iso(arena, expires),
        };
    }

    pub fn verifySignature(self: *FilesService, id: []const u8, expires: i64, sig: []const u8) bool {
        if (expires < self.clock.now()) return false;
        const want = self.sign(id, expires);
        if (sig.len != want.len) return false;
        return std.crypto.timing_safe.eql([want.len]u8, want, sig[0..want.len].*);
    }

    const Sig = [std.base64.url_safe_no_pad.Encoder.calcSize(HmacSha256.mac_length)]u8;

    fn sign(self: *FilesService, id: []const u8, expires: i64) Sig {
        var mac: [HmacSha256.mac_length]u8 = undefined;
        var h = HmacSha256.init(self.settings.signing_secret);
        h.update(id);
        var buf: [24]u8 = undefined;
        h.update(std.fmt.bufPrint(&buf, ":{d}", .{expires}) catch unreachable);
        h.final(&mac);
        var out: Sig = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &mac);
        return out;
    }
};

/// Disk keeps no content type: the extension chosen at upload says it.
fn typeOf(id: []const u8) []const u8 {
    const ext = id[(std.mem.findScalarLast(u8, id, '.') orelse return "application/octet-stream") + 1 ..];
    for (allowed) |a| if (std.mem.eql(u8, a[1], ext)) return a[0];
    return "application/octet-stream";
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "isFileId takes ours only" {
    try std.testing.expect(isFileId("3f2b0c1e-0000-4000-8000-000000000000.png"));
    try std.testing.expect(!isFileId("../secret"));
    try std.testing.expect(!isFileId("3f2b0c1e-0000-4000-8000-000000000000.PNG"));
    try std.testing.expect(!isFileId("3f2b0c1e-0000-4000-8000-00000000000/.png"));
}
