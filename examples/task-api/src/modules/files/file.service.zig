const std = @import("std");
const kzig = @import("kzig");
const FileSettings = @import("file.settings.zig").FileSettings;
const FileStorage = @import("file.storage.zig").FileStorage;
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

/// file-storage-api's `FilesService`: keys are `files/<id>`, on whichever
/// storage `STORAGE_DRIVER` chose.
pub const FilesService = struct {
    process: *const kzig.Process,
    settings: *const FileSettings,
    clock: *Clock,
    files: *FileStorage,

    const prefix = "files/";

    fn keyOf(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.mem.concat(arena, u8, &.{ prefix, id });
    }

    pub const Saved = struct { id: []const u8, size: usize, contentType: []const u8 };

    /// `content_type` is one of `allowed` (the upload checked it).
    pub fn save(self: *FilesService, arena: std.mem.Allocator, data: []const u8, content_type: []const u8) !Saved {
        const media = std.mem.trim(u8, content_type[0 .. std.mem.findScalar(u8, content_type, ';') orelse content_type.len], " ");
        const ext = for (allowed) |a| {
            if (std.ascii.eqlIgnoreCase(a[0], media)) break a[1];
        } else return error.UnsupportedType;
        const id = try arena.print("{s}.{s}", .{ &kzig.multipart.uuid(self.process.io), ext });
        try self.files.storage().put(try keyOf(arena, id), data, .{ .content_type = typeOf(id) });
        return .{ .id = id, .size = data.len, .contentType = typeOf(id) };
    }

    pub const Listed = struct { id: []const u8, size: u64, contentType: []const u8, lastModified: []const u8 };
    pub const Page = struct { files: []const Listed, cursor: ?[]const u8 };

    /// 100 at a time; `cursor` comes from the previous page.
    pub fn list(self: *FilesService, arena: std.mem.Allocator, cursor: ?[]const u8) !Page {
        const page = try self.files.storage().list(arena, .{ .prefix = prefix, .cursor = cursor, .limit = 100 });
        var files: std.ArrayList(Listed) = .empty;
        for (page.files) |f| {
            const id = f.key[prefix.len..];
            if (!isFileId(id)) continue;
            try files.append(arena, .{ .id = id, .size = f.size, .contentType = f.content_type orelse typeOf(id), .lastModified = try iso(arena, f.last_modified) });
        }
        return .{ .files = files.items, .cursor = page.cursor };
    }

    pub const Opened = struct { data: []const u8, content_type: []const u8 };

    pub fn open(self: *FilesService, arena: std.mem.Allocator, id: []const u8) !?Opened {
        const data = try self.files.storage().get(arena, try keyOf(arena, id)) orelse return null;
        return .{ .data = data, .content_type = typeOf(id) };
    }

    /// A storage failure is an error (500), not "no such file".
    pub fn exists(self: *FilesService, arena: std.mem.Allocator, id: []const u8) !bool {
        return self.files.storage().exists(try keyOf(arena, id));
    }

    pub fn remove(self: *FilesService, arena: std.mem.Allocator, id: []const u8) !bool {
        if (!try self.exists(arena, id)) return false;
        try self.files.storage().delete(try keyOf(arena, id));
        return true;
    }

    pub const Link = struct { url: []const u8, expiresAt: []const u8 };

    /// A bucket presigns its own GET (the bucket enforces the expiry); disk
    /// and memory have no signer, so the app signs
    /// `/files/:id/signed?expires=&sig=`.
    pub fn signedUrl(self: *FilesService, arena: std.mem.Allocator, id: []const u8, expires_in: u32, origin: []const u8) !Link {
        const expires = self.clock.now() + expires_in;
        const link = if (self.files.driver == .s3)
            try self.files.storage().url(arena, try keyOf(arena, id), .{ .expires_in = expires_in })
        else
            try arena.print("{s}/api/v1/files/{s}/signed?expires={d}&sig={s}", .{ std.mem.trimEnd(u8, origin, "/"), id, expires, &self.sign(id, expires) });
        return .{ .url = link, .expiresAt = try iso(arena, expires) };
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

test "isFileId takes ours only" {
    try std.testing.expect(isFileId("3f2b0c1e-0000-4000-8000-000000000000.png"));
    try std.testing.expect(!isFileId("../secret"));
    try std.testing.expect(!isFileId("3f2b0c1e-0000-4000-8000-000000000000.PNG"));
    try std.testing.expect(!isFileId("3f2b0c1e-0000-4000-8000-00000000000/.png"));
}
