const std = @import("std");
const kzig = @import("kzig");
const service = @import("file.service.zig");
const FilesService = service.FilesService;
const FileSettings = @import("file.settings.zig").FileSettings;
const ApiKeyGuard = @import("../../guards/api-key.guard.zig").ApiKeyGuard;

const FileId = struct {
    id: []const u8,

    pub fn validate(self: *const FileId, issues: *kzig.Issues) !void {
        if (!service.isFileId(self.id)) try issues.add("id", "must be a file id (<uuid>.<ext>)");
    }
};

/// `MAX_UPLOAD_BYTES` is read at boot, so the size is checked in `upload`;
/// the type check and the form parsing are `kzig.Upload`'s.
const FileUpload = kzig.Upload(.{
    .field = "file",
    .max_size = std.math.maxInt(usize),
    .allowed_types = &.{ "png", "jpg", "pdf", "txt" },
});

const ListQuery = struct { cursor: ?[]const u8 = null };

/// Up to 7 days, S3's limit for a presigned URL.
const UrlQuery = struct {
    expiresIn: u32 = 300,

    pub fn validate(self: *const UrlQuery, issues: *kzig.Issues) !void {
        if (self.expiresIn < 1 or self.expiresIn > 604_800) try issues.add("expiresIn", "must be 1 to 604800 seconds");
    }
};

const SignedQuery = struct { expires: i64, sig: []const u8 };

pub const FilesController = struct {
    files: *FilesService,
    settings: *const FileSettings,

    pub const docs = .{ .tags = &[_][]const u8{"Files"} };

    const key = .{ApiKeyGuard};
    pub const routes = .{
        .{ .method = .POST, .path = "/", .handler = "upload", .middleware = key, .docs = .{
            .summary = "Upload a file (form field `file`)",
            .responses = .{.{ .status = 201, .description = "Stored", .body = FilesService.Saved }},
        } },
        .{ .method = .GET, .path = "/", .handler = "list", .middleware = key, .docs = .{ .summary = "List files" } },
        .{ .method = .GET, .path = "/:id", .handler = "download", .middleware = key, .docs = .{ .summary = "Download a file" } },
        .{ .method = .GET, .path = "/:id/url", .handler = "url", .middleware = key, .docs = .{ .summary = "A signed download link" } },
        // No API key: the signature is the credential.
        .{ .method = .GET, .path = "/:id/signed", .handler = "signed", .docs = .{ .summary = "Download through a signed link" } },
        .{ .method = .DELETE, .path = "/:id", .handler = "remove", .middleware = key, .docs = .{ .summary = "Delete a file" } },
    };

    /// Too big → 413, a type not allowed → 415.
    pub fn upload(self: *FilesController, ctx: *kzig.Ctx, got: struct { upload: FileUpload }) !void {
        const file = got.upload.file() orelse return ctx.fail(.bad_request, "Send the file in the `file` form field");
        if (file.data.len > self.settings.max_upload_bytes)
            return ctx.fail(.payload_too_large, try ctx.arena.print("File {s} exceeds the {d}-byte limit", .{ file.original_name, self.settings.max_upload_bytes }));
        try ctx.created(try self.files.save(ctx.arena, file.data, file.content_type));
    }

    pub fn list(self: *FilesController, ctx: *kzig.Ctx, got: struct { query: ListQuery }) !FilesService.Page {
        return self.files.list(ctx.arena, got.query.cursor);
    }

    pub fn download(self: *FilesController, ctx: *kzig.Ctx, got: struct { params: FileId }) !void {
        try self.send(ctx, got.params.id);
    }

    pub fn url(self: *FilesController, ctx: *kzig.Ctx, got: struct { params: FileId, query: UrlQuery }) !FilesService.Link {
        if (!self.files.exists(got.params.id)) return ctx.fail(.not_found, null);
        const origin = self.settings.public_url orelse try ctx.arena.print("http://{s}", .{ctx.header("host") orelse "localhost"});
        return self.files.signedUrl(ctx.arena, got.params.id, got.query.expiresIn, origin);
    }

    pub fn signed(self: *FilesController, ctx: *kzig.Ctx, got: struct { params: FileId, query: SignedQuery }) !void {
        if (!self.files.verifySignature(got.params.id, got.query.expires, got.query.sig))
            return ctx.fail(.forbidden, "Link expired or invalid");
        try self.send(ctx, got.params.id);
    }

    pub fn remove(self: *FilesController, ctx: *kzig.Ctx, got: struct { params: FileId }) !void {
        if (!try self.files.remove(ctx.arena, got.params.id)) return ctx.fail(.not_found, null);
    }

    fn send(self: *FilesController, ctx: *kzig.Ctx, id: []const u8) !void {
        const file = try self.files.open(ctx.arena, id) orelse return ctx.fail(.not_found, null);
        try ctx.setHeader("content-disposition", try ctx.arena.print("attachment; filename=\"{s}\"", .{id}));
        try ctx.setHeader("x-content-type-options", "nosniff");
        try ctx.bytes(file.content_type, file.data);
    }
};
