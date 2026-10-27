const kzig = @import("kzig");
const FileStorage = @import("../modules/files/file.storage.zig").FileStorage;

/// `storage:<driver>` on `/health/ready`: a one-key list must answer.
pub const StorageAdapter = struct {
    files: *FileStorage,

    pub fn onHealthCheck(self: *StorageAdapter) kzig.HealthCheck {
        // Not a small fixed buffer: the disk driver walks its folder to list.
        var arena: @import("std").heap.ArenaAllocator = .init(self.files.process.gpa);
        defer arena.deinit();
        const up = if (self.files.storage().list(arena.allocator(), .{ .limit = 1 })) |_| true else |_| false;
        return .{ .name = switch (self.files.driver) {
            .disk => "storage:disk",
            .s3 => "storage:s3",
            .memory => "storage:memory",
        }, .status = if (up) .up else .down };
    }
};
