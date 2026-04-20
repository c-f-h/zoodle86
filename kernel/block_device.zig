/// Block device abstraction layer.
///
/// Provides a vtable-based interface for 512-byte sector I/O.
pub const BLOCK_SIZE: u32 = 512;

pub const BlockError = error{
    /// The underlying device failed to read the requested block.
    ReadError,
    /// The underlying device failed to write the requested block.
    WriteError,
    /// The requested LBA is out of range for this device.
    InvalidBlock,
};

/// Abstract block device. Concrete implementations embed this struct as a field
/// named `block_dev` and dispatch I/O through the vtable.
pub const BlockDevice = struct {
    vtable: *const VTable,
    /// Total number of 512-byte blocks available on this device.
    block_count: u32,

    pub const VTable = struct {
        /// Read one 512-byte block at `lba` into `buf`.
        readBlock: *const fn (self: *BlockDevice, lba: u32, buf: *[BLOCK_SIZE]u8) BlockError!void,
        /// Write one 512-byte block at `lba` from `buf`.
        writeBlock: *const fn (self: *BlockDevice, lba: u32, buf: *const [BLOCK_SIZE]u8) BlockError!void,
    };

    /// Read one 512-byte block at `lba` into `buf`.
    pub fn readBlock(self: *BlockDevice, lba: u32, buf: *[BLOCK_SIZE]u8) BlockError!void {
        return self.vtable.readBlock(self, lba, buf);
    }

    /// Write one 512-byte block at `lba` from `buf`.
    pub fn writeBlock(self: *BlockDevice, lba: u32, buf: *const [BLOCK_SIZE]u8) BlockError!void {
        return self.vtable.writeBlock(self, lba, buf);
    }
};
