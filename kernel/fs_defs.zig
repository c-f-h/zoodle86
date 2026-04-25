const std = @import("std");

pub const FILENAME_MAX_LEN: usize = 16;
pub const DIRECTORY_ENTRY_COUNT: usize = 64;
pub const STAGE2_RESERVED_SECTORS: u32 = 96;
pub const SUPERBLOCK_SECTORS: u32 = 1;

pub const FS_START_LBA: u32 = 1 + STAGE2_RESERVED_SECTORS;

pub const MAGIC = "ZOD2".*;
pub const VERSION: u16 = 2;

pub const INODE_KIND_FREE: u8 = 0;
pub const INODE_KIND_FILE: u8 = 1;
pub const INODE_KIND_DIRECTORY: u8 = 2;

pub const DIR_ENTRY_KIND_FREE: u8 = 0;
pub const DIR_ENTRY_KIND_FILE: u8 = 1;
pub const DIR_ENTRY_KIND_DIRECTORY: u8 = 2;

pub const ROOT_INODE_INDEX: u16 = 0;
pub const DIRECT_BLOCK_COUNT: usize = 8;
pub const INDIRECT_BLOCK_COUNT: usize = 2;
pub const BLOCK_POINTER_NONE: u32 = std.math.maxInt(u32);
pub const POINTERS_PER_INDIRECT_BLOCK: usize = 512 / @sizeOf(u32);

pub const Inode = extern struct {
    kind: u8,
    reserved0: u8 = 0,
    link_count: u16,
    size_bytes: u32,
    direct_blocks: [DIRECT_BLOCK_COUNT]u32,
    indirect_blocks: [INDIRECT_BLOCK_COUNT]u32,
    reserved: [16]u8,
};

pub const DirectoryEntry = extern struct {
    inode_index: u16,
    kind: u8,
    name_len: u8,
    name: [FILENAME_MAX_LEN]u8,
    reserved: [12]u8,
};

pub const INODES_PER_SECTOR: usize = 512 / @sizeOf(Inode);
pub const DIR_ENTRIES_PER_SECTOR: usize = 512 / @sizeOf(DirectoryEntry);
pub const MIN_INODE_COUNT: usize = DIRECTORY_ENTRY_COUNT + 1;
pub const ROOT_DIRECTORY_BYTES: usize = DIRECTORY_ENTRY_COUNT * @sizeOf(DirectoryEntry);
pub const ROOT_DIRECTORY_SECTORS: u32 = sectorsForBytes(ROOT_DIRECTORY_BYTES);

pub const Superblock = extern struct {
    magic: [4]u8,
    version: u16,
    block_size: u16,
    fs_start_lba: u32,
    fs_sector_count: u32,
    bitmap_start_lba: u32,
    bitmap_sector_count: u16,
    inode_table_start_lba: u32,
    inode_table_sector_count: u16,
    inode_count: u16,
    data_start_lba: u32,
    data_block_count: u32,
    root_inode_index: u16,
    file_count: u16,
    reserved: [20]u8,
};

pub const Layout = struct {
    fs_sector_count: u32,
    bitmap_start_lba: u32,
    bitmap_sector_count: u16,
    inode_table_start_lba: u32,
    inode_table_sector_count: u16,
    inode_count: u16,
    data_start_lba: u32,
    data_block_count: u32,
};

comptime {
    std.debug.assert(@sizeOf(Inode) == 64);
    std.debug.assert(@sizeOf(DirectoryEntry) == 32);
    std.debug.assert(@sizeOf(Superblock) == 64);
}

pub const FileInfo = struct {
    index: usize,
    name: [FILENAME_MAX_LEN]u8,
    name_len: usize,
    size_bytes: u32,
    sector_count: u32,
};

/// Returns the number of 512-byte sectors needed to store `len` bytes.
pub fn sectorsForBytes(len: usize) u32 {
    if (len == 0) return 0;
    return @intCast((len + 511) / 512);
}

/// Returns the number of file data blocks needed to store `size_bytes`.
pub fn fileBlocksForSize(size_bytes: u32) u32 {
    return sectorsForBytes(size_bytes);
}

/// Returns the number of bitmap sectors needed to track `data_block_count` bits.
pub fn bitmapSectorsForDataBlocks(data_block_count: u32) u32 {
    if (data_block_count == 0) return 0;
    return @intCast((data_block_count + 4095) / 4096);
}

/// Returns the number of inode-table sectors needed to store `inode_count` inodes.
pub fn inodeTableSectorsForCount(inode_count: u16) u16 {
    return @intCast(sectorsForBytes(@as(usize, inode_count) * @sizeOf(Inode)));
}

/// Returns the minimum number of filesystem sectors needed to format a valid image.
pub fn minimumFsSectorCount() u32 {
    return SUPERBLOCK_SECTORS +
        1 + // one bitmap sector is enough for the minimum image
        inodeTableSectorsForCount(@intCast(MIN_INODE_COUNT)) +
        ROOT_DIRECTORY_SECTORS;
}

/// Returns the minimum total disk size, including the reserved stage-2 area.
pub fn minimumImageSectorCount() u32 {
    return FS_START_LBA + minimumFsSectorCount();
}

/// Computes the metadata/data layout for a filesystem of `fs_sector_count` sectors.
pub fn computeLayout(fs_sector_count: u32) ?Layout {
    if (fs_sector_count < minimumFsSectorCount()) return null;

    const inode_count = inodeCountForFsSectors(fs_sector_count) orelse return null;
    const inode_table_sector_count = inodeTableSectorsForCount(inode_count);

    var bitmap_sector_count: u16 = 1;
    while (true) {
        const metadata_sectors = SUPERBLOCK_SECTORS + bitmap_sector_count + inode_table_sector_count;
        if (metadata_sectors >= fs_sector_count) return null;

        const data_block_count = fs_sector_count - metadata_sectors;
        if (data_block_count < ROOT_DIRECTORY_SECTORS) return null;

        const required_bitmap = bitmapSectorsForDataBlocks(data_block_count);
        if (required_bitmap == bitmap_sector_count) {
            const bitmap_start_lba = FS_START_LBA + SUPERBLOCK_SECTORS;
            const inode_table_start_lba = bitmap_start_lba + bitmap_sector_count;
            const data_start_lba = inode_table_start_lba + inode_table_sector_count;
            return .{
                .fs_sector_count = fs_sector_count,
                .bitmap_start_lba = bitmap_start_lba,
                .bitmap_sector_count = bitmap_sector_count,
                .inode_table_start_lba = inode_table_start_lba,
                .inode_table_sector_count = inode_table_sector_count,
                .inode_count = inode_count,
                .data_start_lba = data_start_lba,
                .data_block_count = data_block_count,
            };
        }

        if (required_bitmap > std.math.maxInt(u16)) return null;
        bitmap_sector_count = @intCast(required_bitmap);
    }
}

/// Validates a mounted superblock against the expected derived layout.
pub fn isValidSuperblock(superblock: *const Superblock) bool {
    const layout = computeLayout(superblock.fs_sector_count) orelse return false;

    return std.mem.eql(u8, superblock.magic[0..], MAGIC[0..]) and
        superblock.version == VERSION and
        superblock.block_size == 512 and
        superblock.fs_start_lba == FS_START_LBA and
        superblock.bitmap_start_lba == layout.bitmap_start_lba and
        superblock.bitmap_sector_count == layout.bitmap_sector_count and
        superblock.inode_table_start_lba == layout.inode_table_start_lba and
        superblock.inode_table_sector_count == layout.inode_table_sector_count and
        superblock.inode_count == layout.inode_count and
        superblock.data_start_lba == layout.data_start_lba and
        superblock.data_block_count == layout.data_block_count and
        superblock.root_inode_index == ROOT_INODE_INDEX and
        superblock.file_count <= DIRECTORY_ENTRY_COUNT;
}

/// Validates a single root-directory filename under the v1 flat namespace rules.
pub fn validateName(name: []const u8) bool {
    if (name.len == 0 or name.len > FILENAME_MAX_LEN) return false;

    for (name) |ch| {
        if (ch <= 0x20 or ch > 0x7E or ch == '/' or ch == '\\') {
            return false;
        }
    }
    return true;
}

fn inodeCountForFsSectors(fs_sector_count: u32) ?u16 {
    const scaled = std.math.divCeil(u32, fs_sector_count, 32) catch return null;
    const desired = @max(@as(u32, MIN_INODE_COUNT), scaled);
    if (desired > std.math.maxInt(u16)) return null;
    return @intCast(desired);
}
