const kzig = @import("kzig");
const FileStorage = @import("../modules/files/file.storage.zig").FileStorage;

/// `storage:<driver>` on `/health/ready`: a one-key list must answer.
pub const StorageAdapter = struct {
    files: *FileStorage,

    pub fn onHealthCheck(self: *StorageAdapter) kzig.HealthCheck {
        var buf: [4096]u8 = undefined;
        var fba: @import("std").heap.FixedBufferAllocator = .init(&buf);
        const up = if (self.files.storage().list(fba.allocator(), .{ .limit = 1 })) |_| true else |_| false;
        return .{ .name = switch (self.files.driver) {
            .disk => "storage:disk",
            .s3 => "storage:s3",
            .memory => "storage:memory",
        }, .status = if (up) .up else .down };
    }
};
