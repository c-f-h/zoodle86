/// File-backed BlockDevice implementation for host-side tools.
///
/// Wraps a `std.Io.File` as a block device, routing sector-level reads and
/// writes through the `BlockDevice` vtable interface defined in
/// `kernel/block_device.zig`.
const block_device = @import("kernel/block_device.zig");
pub const BlockDevice = block_device.BlockDevice;
pub const BlockError = block_device.BlockError;
const std = @import("std");

/// Concrete `BlockDevice` backed by a `std.Io.File`.
pub const FileBlockDevice = struct {
    block_dev: BlockDevice,
    file: std.Io.File,
    io_ctx: std.Io,

    const vtable = BlockDevice.VTable{
        .readBlock = readBlock,
        .writeBlock = writeBlock,
    };

    /// Initializes a `FileBlockDevice` from an already-opened file.
    /// `block_count` is the number of 512-byte sectors in the image.
    pub fn init(file: std.Io.File, io_ctx: std.Io, block_count: u32) FileBlockDevice {
        return .{
            .block_dev = .{ .vtable = &vtable, .block_count = block_count },
            .file = file,
            .io_ctx = io_ctx,
        };
    }

    fn readBlock(bd: *BlockDevice, lba: u32, buf: *[block_device.BLOCK_SIZE]u8) BlockError!void {
        const self: *FileBlockDevice = @fieldParentPtr("block_dev", bd);
        const offset = @as(u64, lba) * block_device.BLOCK_SIZE;
        _ = self.file.readPositionalAll(self.io_ctx, buf, offset) catch return error.ReadError;
    }

    fn writeBlock(bd: *BlockDevice, lba: u32, buf: *const [block_device.BLOCK_SIZE]u8) BlockError!void {
        const self: *FileBlockDevice = @fieldParentPtr("block_dev", bd);
        const offset = @as(u64, lba) * block_device.BLOCK_SIZE;
        self.file.writePositionalAll(self.io_ctx, buf, offset) catch return error.WriteError;
    }
};
