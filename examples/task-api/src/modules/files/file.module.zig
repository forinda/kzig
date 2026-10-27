const kzig = @import("kzig");
const FilesController = @import("file.controller.zig").FilesController;
const service = @import("file.service.zig");
const FileSettings = @import("file.settings.zig").FileSettings;
const FileStorage = @import("file.storage.zig").FileStorage;

/// file-storage-api's files module on its disk driver.
pub const FilesModule = kzig.Module(.{
    .name = "FilesModule",
    .path = "/files",
    .controllers = &.{FilesController},
    .services = &.{ service.FilesService, service.Clock, FileStorage },
    .settings = &.{ FileSettings, kzig.storage.S3Settings },
});
