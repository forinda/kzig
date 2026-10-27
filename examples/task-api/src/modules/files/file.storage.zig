const std = @import("std");
const kzig = @import("kzig");
const FileSettings = @import("file.settings.zig").FileSettings;
const StorageDriver = @import("file.settings.zig").StorageDriver;

/// The files' storage, chosen at boot (file-storage-api's `StorageAdapter`
/// binds `STORAGE` the same way).
pub const FileStorage = struct {
    process: *const kzig.Process,
    settings: *const FileSettings,
    s3_settings: *const kzig.storage.S3Settings,
    driver: Driver = undefined,

    pub const Driver = union(enum) {
        disk: kzig.storage.Disk,
        s3: kzig.storage.S3,
        memory: kzig.storage.Memory,
    };

    pub fn init(self: *FileStorage) !void {
        const p = self.process;
        const choice = self.settings.storage_driver orelse if (p.dev_or_test) StorageDriver.disk else .s3;
        self.driver = switch (choice) {
            .disk => .{ .disk = .{ .io = p.io, .root = self.settings.upload_dir } },
            .s3 => .{ .s3 = try .fromSettings(p.io, p.gpa, self.s3_settings) },
            .memory => .{ .memory = .init(p.io, p.gpa) },
        };
    }

    pub fn deinit(self: *FileStorage) void {
        switch (self.driver) {
            .disk => {},
            .s3 => |*s| s.deinit(),
            .memory => |*m| m.deinit(),
        }
    }

    pub fn storage(self: *FileStorage) kzig.storage.Storage {
        return switch (self.driver) {
            inline else => |*d| d.storage(),
        };
    }

    pub fn name(self: *const FileStorage) []const u8 {
        return @tagName(self.driver);
    }
};
