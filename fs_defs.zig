const std = @import("std");

pub const FILENAME_MAX_LEN: usize = 16;
pub const DIRECTORY_ENTRY_COUNT: usize = 64;
pub const STAGE2_RESERVED_SECTORS: u32 = 63;
pub const FS_START_LBA: u32 = 1 + STAGE2_RESERVED_SECTORS;
pub const SUPERBLOCK_SECTORS: u32 = 1;
pub const DIRECTORY_SECTORS: u32 = 8;
pub const DATA_START_LBA: u32 = FS_START_LBA + SUPERBLOCK_SECTORS + DIRECTORY_SECTORS;

pub const MAGIC = "ZOD1".*;
pub const VERSION: u16 = 1;

pub const ENTRY_STATE_FREE: u8 = 0;
pub const ENTRY_STATE_FILE: u8 = 1;
pub const ENTRY_STATE_RESERVED: u8 = 2;
pub const ENTRY_STATE_DELETED: u8 = 3;

pub const Superblock = extern struct {
    magic: [4]u8,
    version: u16,
    directory_entry_count: u16,
    fs_start_lba: u32,
    fs_sector_count: u32,
    directory_start_lba: u32,
    directory_sector_count: u32,
    data_start_lba: u32,
    next_free_lba: u32,
    file_count: u32,
    reserved: [28]u8,
};

pub const DirectoryEntry = extern struct {
    state: u8,
    name_len: u8,
    reserved0: u16,
    name: [FILENAME_MAX_LEN]u8,
    start_lba: u32,
    sector_count: u32,
    size_bytes: u32,
    created_ticks: u32,
    modified_ticks: u32,
    flags: u32,
    reserved: [20]u8,
};

comptime {
    if (@sizeOf(Superblock) != 64) @compileError("Superblock must be 64 bytes.");
    if (@sizeOf(DirectoryEntry) != 64) @compileError("DirectoryEntry must be 64 bytes.");
}

pub const FileInfo = struct {
    index: usize,
    name: [FILENAME_MAX_LEN]u8,
    name_len: usize,
    size_bytes: u32,
    sector_count: u32,
};

pub fn isValidSuperblock(superblock: *const Superblock) bool {
    return std.mem.eql(u8, superblock.magic[0..], MAGIC[0..]) and
        superblock.version == VERSION and
        superblock.directory_entry_count == @as(u16, DIRECTORY_ENTRY_COUNT) and
        superblock.fs_start_lba == FS_START_LBA and
        superblock.fs_sector_count > DATA_START_LBA and
        superblock.directory_start_lba == FS_START_LBA + SUPERBLOCK_SECTORS and
        superblock.directory_sector_count == DIRECTORY_SECTORS and
        superblock.data_start_lba == DATA_START_LBA and
        superblock.next_free_lba >= DATA_START_LBA and
        superblock.next_free_lba <= FS_START_LBA + superblock.fs_sector_count;
}

pub fn sectorsForBytes(len: usize) u32 {
    if (len == 0) return 0;
    return @intCast((len + 511) / 512);
}

pub fn validateName(name: []const u8) bool {
    if (name.len == 0 or name.len > FILENAME_MAX_LEN) return false;

    for (name) |ch| {
        if (ch <= 0x20 or ch > 0x7E or ch == '/' or ch == '\\') {
            return false;
        }
    }
    return true;
}
