const block_device = @import("block_device.zig");
const BlockDevice = block_device.BlockDevice;
const std = @import("std");

pub const FILENAME_MAX_LEN: usize = 16;
pub const DIRECTORY_ENTRY_COUNT: usize = 64;
pub const STAGE2_RESERVED_SECTORS: u32 = 16;
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

pub const INODES_PER_SECTOR: usize = 512 / @sizeOf(Inode);
pub const DIR_ENTRIES_PER_SECTOR: usize = 512 / @sizeOf(DirectoryEntry);
pub const MIN_INODE_COUNT: usize = DIRECTORY_ENTRY_COUNT + 1;
pub const ROOT_DIRECTORY_BYTES: usize = DIRECTORY_ENTRY_COUNT * @sizeOf(DirectoryEntry);
pub const ROOT_DIRECTORY_SECTORS: u32 = sectorsForBytes(ROOT_DIRECTORY_BYTES); // = 4

pub const Inode = extern struct {
    kind: u8 = INODE_KIND_FREE,
    reserved0: u8 = 0,
    link_count: u16 = 0,
    size_bytes: u32 = 0,
    direct_blocks: [DIRECT_BLOCK_COUNT]u32 = @splat(BLOCK_POINTER_NONE),
    indirect_blocks: [INDIRECT_BLOCK_COUNT]u32 = @splat(BLOCK_POINTER_NONE),
    reserved: [16]u8 = @splat(0),
};

pub const DirectoryEntry = extern struct {
    inode_index: u16 = 0,
    kind: u8 = DIR_ENTRY_KIND_FREE,
    name_len: u8 = 0,
    name: [FILENAME_MAX_LEN]u8 = @splat(0),
    reserved: [12]u8 = @splat(0),
};

const Superblock = extern struct {
    magic: [4]u8,
    version: u16,
    block_size: u16,
    fs_sector_count: u32,
    bitmap_start_lba: u32,
    bitmap_sector_count: u16,
    inode_table_sector_count: u16,
    inode_table_start_lba: u32,
    inode_count: u16,
    file_count: u16,
    data_start_lba: u32,
    data_block_count: u32,
    reserved: [28]u8,
};

const Layout = struct {
    fs_sector_count: u32,
    bitmap_start_lba: u32,
    bitmap_sector_count: u16,
    inode_table_start_lba: u32,
    inode_table_sector_count: u16,
    inode_count: u16,
    data_start_lba: u32,
    data_block_count: u32,
};

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
        superblock.bitmap_start_lba == layout.bitmap_start_lba and
        superblock.bitmap_sector_count == layout.bitmap_sector_count and
        superblock.inode_table_start_lba == layout.inode_table_start_lba and
        superblock.inode_table_sector_count == layout.inode_table_sector_count and
        superblock.inode_count == layout.inode_count and
        superblock.data_start_lba == layout.data_start_lba and
        superblock.data_block_count == layout.data_block_count and
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

pub const FsError = error{
    Corrupt,
    DirectoryFull,
    FileExists,
    FileNotFound,
    InvalidName,
    InvalidSuperblock,
    NoSpace,
} || block_device.BlockError;

pub const ReadFileError = FsError || error{OutOfMemory};
pub const WriteFileError = FsError || error{OutOfMemory};

const MAX_FILE_BLOCK_COUNT: usize = DIRECT_BLOCK_COUNT + INDIRECT_BLOCK_COUNT * POINTERS_PER_INDIRECT_BLOCK;

pub const FileSystem = struct {
    block_dev: *BlockDevice,
    superblock: Superblock,

    /// Mounts the filesystem, formatting a fresh inode-based image if needed.
    pub fn mountOrFormat(bd: *BlockDevice) FsError!FileSystem {
        var fs = FileSystem{
            .block_dev = bd,
            .superblock = undefined,
        };

        fs.readSuperblock() catch |err| switch (err) {
            error.InvalidSuperblock => {
                try fs.format();
                return fs;
            },
            else => return err,
        };

        try fs.validateRootDirectory();
        return fs;
    }

    /// Mounts an existing inode-based filesystem.
    pub fn mount(bd: *BlockDevice) FsError!FileSystem {
        var fs = FileSystem{
            .block_dev = bd,
            .superblock = undefined,
        };
        try fs.readSuperblock();
        try fs.validateRootDirectory();
        return fs;
    }

    /// Formats the filesystem region with the current inode-based layout.
    pub fn format(self: *FileSystem) FsError!void {
        const fs_sector_count = self.block_dev.block_count - FS_START_LBA;
        const layout = computeLayout(fs_sector_count) orelse return error.NoSpace;
        self.superblock = makeDefaultSuperblock(layout);

        var zero_sector = [_]u8{0} ** 512;
        var lba = FS_START_LBA;
        const zero_limit = self.superblock.data_start_lba + ROOT_DIRECTORY_SECTORS;
        while (lba < zero_limit) : (lba += 1) {
            try self.block_dev.writeBlock(lba, &zero_sector);
        }

        var root_blocks: [ROOT_DIRECTORY_SECTORS]u32 = undefined;
        for (&root_blocks) |*block_index| {
            block_index.* = try self.allocateDataBlock();
        }

        comptime {
            // The logic below relies on the fact that the directory fits into the direct blocks.
            std.debug.assert(ROOT_DIRECTORY_SECTORS <= DIRECT_BLOCK_COUNT);
        }

        var root_inode: Inode = .{};
        root_inode.kind = INODE_KIND_DIRECTORY;
        root_inode.link_count = 1;
        root_inode.size_bytes = @intCast(ROOT_DIRECTORY_BYTES);
        for (root_blocks, 0..) |block_index, index| {
            root_inode.direct_blocks[index] = block_index;
        }
        try self.writeInode(ROOT_INODE_INDEX, &root_inode);
        try self.writeSuperblock();
    }

    /// Returns the number of visible regular files in the root directory.
    pub fn fileCount(self: *const FileSystem) u32 {
        return self.superblock.file_count;
    }

    /// Returns metadata for a root-directory slot when it contains a regular file.
    pub fn getFileInfo(self: *const FileSystem, index: usize) FsError!?FileInfo {
        if (index >= DIRECTORY_ENTRY_COUNT) return null;

        const entry = try self.readDirEntryFromInode(ROOT_INODE_INDEX, index);
        if (entry.kind != DIR_ENTRY_KIND_FILE) return null;

        const inode = try self.readFileInode(entry.inode_index);
        return .{
            .index = index,
            .name = entry.name,
            .name_len = @intCast(entry.name_len),
            .size_bytes = inode.size_bytes,
            .sector_count = fileBlocksForSize(inode.size_bytes),
        };
    }

    /// Resolves a root-directory slot to its backing inode number.
    pub fn getFileInodeIndex(self: *const FileSystem, index: usize) FsError!u16 {
        const entry = try self.readLiveRootFileEntry(index);
        return entry.inode_index;
    }

    /// Creates a new empty regular file in the root directory and returns its inode index.
    pub fn createFile(self: *FileSystem, name: []const u8) FsError!u16 {
        if (!validateName(name)) return error.InvalidName;
        if ((try self.findFileIndex(ROOT_INODE_INDEX, name)) != null) return error.FileExists;

        const entry_index = try self.findReusableEntryIndex(ROOT_INODE_INDEX);
        const inode_index = try self.findFreeInodeIndex();

        var inode: Inode = .{};
        inode.kind = INODE_KIND_FILE;
        inode.link_count = 1;
        try self.writeInode(inode_index, &inode);

        var entry: DirectoryEntry = .{};
        entry.inode_index = inode_index;
        entry.kind = DIR_ENTRY_KIND_FILE;
        entry.name_len = @intCast(name.len);
        @memcpy(entry.name[0..name.len], name);
        try self.writeDirEntry(ROOT_INODE_INDEX, entry_index, &entry);

        self.superblock.file_count += 1;
        try self.writeSuperblock();
        return inode_index;
    }

    /// Returns the current byte length for a file identified by inode number.
    pub fn getInodeSize(self: *const FileSystem, inode_index: u16) FsError!u32 {
        const inode = try self.readFileInode(inode_index);
        return inode.size_bytes;
    }

    /// Reads bytes from a file identified directly by inode number.
    pub fn readInodeAt(self: *const FileSystem, inode_index: u16, offset: u32, dest: []u8) FsError!usize {
        if (dest.len == 0) return 0;

        const inode = try self.readFileInode(inode_index);
        if (offset >= inode.size_bytes) return 0;

        var remaining: usize = @min(dest.len, @as(usize, @intCast(inode.size_bytes - offset)));
        var logical_block: u32 = offset / 512;
        var block_offset: usize = @intCast(offset % 512);
        var out_offset: usize = 0;
        var sector = [_]u8{0} ** 512;
        var indirect_pointers: [POINTERS_PER_INDIRECT_BLOCK]u32 = undefined;

        while (remaining > 0) : (logical_block += 1) {
            const data_block = try self.getInodeDataBlock(&inode, logical_block, &indirect_pointers);
            try self.block_dev.readBlock(self.dataBlockLba(data_block), &sector);

            const chunk_len: usize = @min(remaining, sector.len - block_offset);
            @memcpy(dest[out_offset .. out_offset + chunk_len], sector[block_offset .. block_offset + chunk_len]);
            out_offset += chunk_len;
            remaining -= chunk_len;
            block_offset = 0;
        }

        return out_offset;
    }

    /// Writes bytes to a file identified directly by inode number, growing as needed.
    pub fn writeInodeAt(self: *FileSystem, allocator: std.mem.Allocator, inode_index: u16, offset: u32, data: []const u8) WriteFileError!usize {
        if (data.len == 0) return 0;

        const inode = try self.readFileInode(inode_index);
        const data_len_u32: u32 = @intCast(data.len);
        const required_size = std.math.add(u32, offset, data_len_u32) catch return error.NoSpace;
        const new_size = @max(inode.size_bytes, required_size);
        if (fileBlocksForSize(new_size) > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        const merged = try allocator.alloc(u8, new_size);
        defer allocator.free(merged);

        @memset(merged, 0);
        if (inode.size_bytes > 0) {
            _ = try self.readInodeAt(inode_index, 0, merged[0..inode.size_bytes]);
        }
        @memcpy(merged[offset..required_size], data);

        try self.replaceInodeContents(allocator, inode_index, &inode, merged);
        return data.len;
    }

    /// Truncates a file identified by root-directory slot to zero bytes.
    pub fn truncateFile(self: *FileSystem, allocator: std.mem.Allocator, index: usize) WriteFileError!void {
        const inode_index = try self.getFileInodeIndex(index);
        try self.truncateInode(allocator, inode_index);
    }

    /// Truncates a file identified directly by inode number to zero bytes.
    pub fn truncateInode(self: *FileSystem, allocator: std.mem.Allocator, inode_index: u16) WriteFileError!void {
        const inode = try self.readFileInode(inode_index);
        try self.replaceInodeContents(allocator, inode_index, &inode, &.{});
    }

    /// Reads an entire regular file into allocator-owned memory.
    pub fn readFile(self: *const FileSystem, allocator: std.mem.Allocator, path: []const u8) ReadFileError![]u8 {
        const inode_index = try self.findFileInodeIndex(path) orelse return error.FileNotFound;
        const inode = try self.readFileInode(inode_index);
        if (inode.size_bytes == 0) {
            return allocator.alloc(u8, 0);
        }

        const data = try allocator.alloc(u8, @intCast(inode.size_bytes));
        errdefer allocator.free(data);
        _ = try self.readInodeAt(inode_index, 0, data);
        return data;
    }

    /// Creates or overwrites a root-directory file with the provided full contents.
    pub fn writeFile(self: *FileSystem, allocator: std.mem.Allocator, name: []const u8, data: []const u8) WriteFileError!void {
        if (!validateName(name)) return error.InvalidName;
        if (fileBlocksForSize(@intCast(data.len)) > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        const inode_index = (try self.findFileInodeIndex(name)) orelse try self.createFile(name);
        const inode = try self.readFileInode(inode_index);
        try self.replaceInodeContents(allocator, inode_index, &inode, data);
    }

    /// Deletes a regular file from the root directory and frees its inode and blocks.
    pub fn deleteFile(self: *FileSystem, allocator: std.mem.Allocator, name: []const u8) WriteFileError!void {
        const index = (try self.findFileIndex(ROOT_INODE_INDEX, name)) orelse return error.FileNotFound;
        const entry = try self.readLiveRootFileEntry(index);

        try self.destroyInode(allocator, entry.inode_index);
        var cleared: DirectoryEntry = .{};
        try self.writeDirEntry(ROOT_INODE_INDEX, index, &cleared);

        self.superblock.file_count -= 1;
        try self.writeSuperblock();
    }

    /// Renames a regular file within the root directory.
    pub fn renameFile(self: *FileSystem, old_name: []const u8, new_name: []const u8) FsError!void {
        if (!validateName(new_name)) return error.InvalidName;

        const index = (try self.findFileIndex(ROOT_INODE_INDEX, old_name)) orelse return error.FileNotFound;
        if ((try self.findFileIndex(ROOT_INODE_INDEX, new_name)) != null) return error.FileExists;

        var entry = try self.readLiveRootFileEntry(index);
        entry.name_len = @intCast(new_name.len);
        entry.name = [_]u8{0} ** FILENAME_MAX_LEN;
        @memcpy(entry.name[0..new_name.len], new_name);
        try self.writeDirEntry(ROOT_INODE_INDEX, index, &entry);
    }

    fn readSuperblock(self: *FileSystem) FsError!void {
        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(FS_START_LBA, &sector);

        var superblock: Superblock = undefined;
        @memcpy(std.mem.asBytes(&superblock), sector[0..@sizeOf(Superblock)]);
        if (!isValidSuperblock(&superblock)) {
            return error.InvalidSuperblock;
        }

        self.superblock = superblock;
    }

    fn writeSuperblock(self: *const FileSystem) FsError!void {
        var sector = [_]u8{0} ** 512;
        @memcpy(sector[0..@sizeOf(Superblock)], std.mem.asBytes(&self.superblock));
        try self.block_dev.writeBlock(FS_START_LBA, &sector);
    }

    fn validateRootDirectory(self: *const FileSystem) FsError!void {
        const root_inode = try self.readDirectoryInode(ROOT_INODE_INDEX);
        if (root_inode.size_bytes != @as(u32, @intCast(ROOT_DIRECTORY_BYTES))) return error.Corrupt;
        if (fileBlocksForSize(root_inode.size_bytes) != ROOT_DIRECTORY_SECTORS) return error.Corrupt;
        if (root_inode.indirect_blocks[0] != BLOCK_POINTER_NONE or root_inode.indirect_blocks[1] != BLOCK_POINTER_NONE) {
            return error.Corrupt;
        }

        var visible_files: usize = 0;
        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&root_inode, index);
            switch (entry.kind) {
                DIR_ENTRY_KIND_FREE => {},
                DIR_ENTRY_KIND_FILE => {
                    _ = try self.readFileInode(entry.inode_index);
                    visible_files += 1;
                },
                else => return error.Corrupt,
            }
        }

        if (visible_files != @as(usize, self.superblock.file_count)) return error.Corrupt;
    }

    // Looks up the root-directory slot for a named regular file.
    // DEPRECATED: prefer findFileInodeIndex for direct inode lookup
    fn findFileIndex(self: *const FileSystem, dir_inode_index: u16, name: []const u8) FsError!?usize {
        if (!validateName(name)) return error.InvalidName;

        const dir_inode = try self.readDirectoryInode(dir_inode_index);

        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&dir_inode, index);
            if (entry.kind != DIR_ENTRY_KIND_FILE) continue;
            if (entry.name_len != @as(u8, @intCast(name.len))) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return index;
            }
        }

        return null;
    }

    /// Given the full path to a file, find its inode index.
    pub fn findFileInodeIndex(self: *const FileSystem, path: []const u8) FsError!?u16 {
        if (!validateName(path)) return error.InvalidName;

        const root_inode = try self.readDirectoryInode(ROOT_INODE_INDEX);

        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&root_inode, index);
            if (entry.kind != DIR_ENTRY_KIND_FILE) continue;
            if (entry.name_len != @as(u8, @intCast(path.len))) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], path)) {
                return entry.inode_index;
            }
        }

        return null;
    }

    /// Find a free directory entry within the given directory.
    fn findReusableEntryIndex(self: *const FileSystem, dir_inode_index: u16) FsError!usize {
        var index: usize = 0;
        const dir_inode = try self.readDirectoryInode(dir_inode_index);
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&dir_inode, index);
            if (entry.kind == DIR_ENTRY_KIND_FREE) return index;
        }
        return error.DirectoryFull;
    }

    /// Find a free inode index within the inode table.
    fn findFreeInodeIndex(self: *const FileSystem) FsError!u16 {
        var inode_index: u16 = ROOT_INODE_INDEX + 1;
        while (inode_index < self.superblock.inode_count) : (inode_index += 1) {
            const inode = try self.readInode(inode_index);
            if (inode.kind == INODE_KIND_FREE) return inode_index;
        }
        return error.NoSpace;
    }

    fn readLiveRootFileEntry(self: *const FileSystem, index: usize) FsError!DirectoryEntry {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.FileNotFound;

        const entry = try self.readDirEntryFromInode(ROOT_INODE_INDEX, index);
        if (entry.kind != DIR_ENTRY_KIND_FILE) return error.FileNotFound;
        return entry;
    }

    /// Read the inode with the given index and verify that it is a valid file inode.
    fn readFileInode(self: *const FileSystem, inode_index: u16) FsError!Inode {
        const inode = try self.readInode(inode_index);
        try self.validateInode(&inode);
        if (inode.kind != INODE_KIND_FILE) return error.FileNotFound;
        return inode;
    }

    /// Read the inode with the given index and verify that it is a valid directory inode.
    fn readDirectoryInode(self: *const FileSystem, inode_index: u16) FsError!Inode {
        const inode = try self.readInode(inode_index);
        try self.validateInode(&inode);
        if (inode.kind != INODE_KIND_DIRECTORY) return error.Corrupt;
        return inode;
    }

    fn replaceInodeContents(self: *FileSystem, allocator: std.mem.Allocator, inode_index: u16, existing_inode: *const Inode, data: []const u8) WriteFileError!void {
        const new_block_count_u32 = fileBlocksForSize(@intCast(data.len));
        const old_block_count_u32 = fileBlocksForSize(existing_inode.size_bytes);
        if (new_block_count_u32 > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        const new_block_count: usize = @intCast(new_block_count_u32);
        const old_block_count: usize = @intCast(old_block_count_u32);
        const old_indirect_count = indirectBlocksForFileBlocks(old_block_count_u32);
        const new_indirect_count = indirectBlocksForFileBlocks(new_block_count_u32);

        const indirect_pointers = try allocator.create([POINTERS_PER_INDIRECT_BLOCK]u32);
        defer allocator.destroy(indirect_pointers);

        const old_file_blocks = try allocator.alloc(u32, old_block_count);
        defer allocator.free(old_file_blocks);
        if (old_block_count > 0) {
            try self.collectInodeDataBlocks(existing_inode, old_file_blocks, indirect_pointers);
        }

        const new_file_blocks = try allocator.alloc(u32, new_block_count);
        defer allocator.free(new_file_blocks);
        @memset(new_file_blocks, BLOCK_POINTER_NONE);

        const newly_allocated_data_blocks = try allocator.alloc(u32, new_block_count);
        defer allocator.free(newly_allocated_data_blocks);
        @memset(newly_allocated_data_blocks, BLOCK_POINTER_NONE);
        var newly_allocated_data_count: usize = 0;
        errdefer {
            for (newly_allocated_data_blocks[0..newly_allocated_data_count]) |block_index| {
                self.freeDataBlock(block_index) catch {};
            }
        }

        var sector = [_]u8{0} ** 512;
        var all_blocks_reused = existing_inode.size_bytes == @as(u32, @intCast(data.len));
        var block_idx: usize = 0;
        while (block_idx < new_block_count) : (block_idx += 1) {
            const byte_start = block_idx * 512;
            const byte_end = @min(data.len, byte_start + 512);
            sector = [_]u8{0} ** 512;
            if (byte_start < data.len) {
                @memcpy(sector[0 .. byte_end - byte_start], data[byte_start..byte_end]);
            }

            if (block_idx < old_block_count and try self.blockMatches(old_file_blocks[block_idx], &sector)) {
                new_file_blocks[block_idx] = old_file_blocks[block_idx];
            } else {
                const block_index = try self.allocateDataBlock();
                newly_allocated_data_blocks[newly_allocated_data_count] = block_index;
                newly_allocated_data_count += 1;
                try self.block_dev.writeBlock(self.dataBlockLba(block_index), &sector);
                new_file_blocks[block_idx] = block_index;
                all_blocks_reused = false;
            }
        }

        if (all_blocks_reused and old_block_count == new_block_count) {
            return;
        }

        const new_indirect_blocks = try allocator.alloc(u32, new_indirect_count);
        defer allocator.free(new_indirect_blocks);
        @memset(new_indirect_blocks, BLOCK_POINTER_NONE);

        const newly_allocated_indirect_blocks = try allocator.alloc(u32, new_indirect_count);
        defer allocator.free(newly_allocated_indirect_blocks);
        @memset(newly_allocated_indirect_blocks, BLOCK_POINTER_NONE);
        var newly_allocated_indirect_count: usize = 0;
        errdefer {
            for (newly_allocated_indirect_blocks[0..newly_allocated_indirect_count]) |block_index| {
                self.freeDataBlock(block_index) catch {};
            }
        }

        var indirect_index: usize = 0;
        while (indirect_index < new_indirect_count) : (indirect_index += 1) {
            const block_index = try self.allocateDataBlock();
            newly_allocated_indirect_blocks[newly_allocated_indirect_count] = block_index;
            newly_allocated_indirect_count += 1;
            new_indirect_blocks[indirect_index] = block_index;

            const slice_start = DIRECT_BLOCK_COUNT + indirect_index * POINTERS_PER_INDIRECT_BLOCK;
            const slice_end = @min(new_block_count, slice_start + POINTERS_PER_INDIRECT_BLOCK);
            try self.writeIndirectPointerBlock(block_index, new_file_blocks[slice_start..slice_end]);
        }

        var next_inode = existing_inode.*;
        next_inode.size_bytes = @intCast(data.len);
        next_inode.direct_blocks = [_]u32{BLOCK_POINTER_NONE} ** DIRECT_BLOCK_COUNT;
        next_inode.indirect_blocks = [_]u32{BLOCK_POINTER_NONE} ** INDIRECT_BLOCK_COUNT;
        next_inode.link_count = 1;

        for (new_file_blocks[0..@min(new_block_count, DIRECT_BLOCK_COUNT)], 0..) |block_index, index| {
            next_inode.direct_blocks[index] = block_index;
        }
        for (new_indirect_blocks[0..new_indirect_count], 0..) |block_index, index| {
            next_inode.indirect_blocks[index] = block_index;
        }

        try self.writeInode(inode_index, &next_inode);

        var old_index: usize = 0;
        while (old_index < old_block_count) : (old_index += 1) {
            if (old_index < new_block_count and old_file_blocks[old_index] == new_file_blocks[old_index]) {
                continue;
            }
            try self.freeDataBlock(old_file_blocks[old_index]);
        }

        for (existing_inode.indirect_blocks[0..old_indirect_count]) |block_index| {
            try self.freeDataBlock(block_index);
        }
    }

    fn destroyInode(self: *FileSystem, allocator: std.mem.Allocator, inode_index: u16) WriteFileError!void {
        const inode = try self.readFileInode(inode_index);

        const old_block_count: usize = @intCast(fileBlocksForSize(inode.size_bytes));
        const indirect_pointers = try allocator.create([POINTERS_PER_INDIRECT_BLOCK]u32);
        defer allocator.destroy(indirect_pointers);

        const old_blocks = try allocator.alloc(u32, old_block_count);
        defer allocator.free(old_blocks);
        if (old_block_count > 0) {
            try self.collectInodeDataBlocks(&inode, old_blocks, indirect_pointers);
        }

        for (old_blocks) |block_index| {
            try self.freeDataBlock(block_index);
        }

        const old_indirect_count = indirectBlocksForFileBlocks(fileBlocksForSize(inode.size_bytes));
        for (inode.indirect_blocks[0..old_indirect_count]) |block_index| {
            try self.freeDataBlock(block_index);
        }

        var cleared: Inode = .{};
        try self.writeInode(inode_index, &cleared);
    }

    fn readInode(self: *const FileSystem, inode_index: u16) FsError!Inode {
        if (inode_index >= self.superblock.inode_count) return error.Corrupt;

        const sector_lba = self.superblock.inode_table_start_lba +
            @divFloor(@as(u32, inode_index), @as(u32, @intCast(INODES_PER_SECTOR)));
        const inode_offset = (@as(usize, inode_index) % INODES_PER_SECTOR) * @sizeOf(Inode);

        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(sector_lba, &sector);

        var inode: Inode = undefined;
        @memcpy(std.mem.asBytes(&inode), sector[inode_offset .. inode_offset + @sizeOf(Inode)]);
        return inode;
    }

    fn writeInode(self: *const FileSystem, inode_index: u16, inode: *const Inode) FsError!void {
        if (inode_index >= self.superblock.inode_count) return error.Corrupt;

        const sector_lba = self.superblock.inode_table_start_lba +
            @divFloor(@as(u32, inode_index), @as(u32, @intCast(INODES_PER_SECTOR)));
        const inode_offset = (@as(usize, inode_index) % INODES_PER_SECTOR) * @sizeOf(Inode);

        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(sector_lba, &sector);
        @memcpy(sector[inode_offset .. inode_offset + @sizeOf(Inode)], std.mem.asBytes(inode));
        try self.block_dev.writeBlock(sector_lba, &sector);
    }

    fn validateInode(self: *const FileSystem, inode: *const Inode) FsError!void {
        switch (inode.kind) {
            INODE_KIND_FREE => {
                if (inode.size_bytes != 0 or inode.link_count != 0) return error.Corrupt;
                for (inode.direct_blocks) |block_index| {
                    if (block_index != BLOCK_POINTER_NONE) return error.Corrupt;
                }
                for (inode.indirect_blocks) |block_index| {
                    if (block_index != BLOCK_POINTER_NONE) return error.Corrupt;
                }
                return;
            },
            INODE_KIND_FILE, INODE_KIND_DIRECTORY => {},
            else => return error.Corrupt,
        }

        if (inode.link_count == 0) return error.Corrupt;

        const block_count = fileBlocksForSize(inode.size_bytes);
        if (block_count > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.Corrupt;

        const used_direct = @min(@as(usize, @intCast(block_count)), DIRECT_BLOCK_COUNT);
        const used_indirect = indirectBlocksForFileBlocks(block_count);

        for (inode.direct_blocks, 0..) |block_index, index| {
            if (index < used_direct) {
                try self.validateDataBlockIndex(block_index);
            } else if (block_index != BLOCK_POINTER_NONE) {
                return error.Corrupt;
            }
        }

        var indirect_pointers: [POINTERS_PER_INDIRECT_BLOCK]u32 = undefined;
        for (inode.indirect_blocks, 0..) |block_index, index| {
            if (index < used_indirect) {
                try self.validateDataBlockIndex(block_index);
                try self.readIndirectPointerBlock(block_index, &indirect_pointers);
                const used_entries: usize = if (index + 1 < used_indirect)
                    POINTERS_PER_INDIRECT_BLOCK
                else
                    @as(usize, @intCast(block_count)) - DIRECT_BLOCK_COUNT - index * POINTERS_PER_INDIRECT_BLOCK;

                for (indirect_pointers, 0..) |pointer, pointer_index| {
                    if (pointer_index < used_entries) {
                        try self.validateDataBlockIndex(pointer);
                    } else if (pointer != BLOCK_POINTER_NONE) {
                        return error.Corrupt;
                    }
                }
            } else if (block_index != BLOCK_POINTER_NONE) {
                return error.Corrupt;
            }
        }
    }

    /// Collects the data block indices for all logical blocks used by an inode into dest.
    fn collectInodeDataBlocks(self: *const FileSystem, inode: *const Inode, dest: []u32, indirect_pointers: *[POINTERS_PER_INDIRECT_BLOCK]u32) FsError!void {
        const block_count = fileBlocksForSize(inode.size_bytes);
        if (dest.len < block_count) return error.Corrupt;

        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            dest[block_index] = try self.getInodeDataBlock(inode, @intCast(block_index), indirect_pointers);
        }
    }

    /// Find the data block index for a given logical block within an inode.
    fn getInodeDataBlock(self: *const FileSystem, inode: *const Inode, logical_block: u32, indirect_pointers: *[POINTERS_PER_INDIRECT_BLOCK]u32) FsError!u32 {
        if (logical_block < @as(u32, DIRECT_BLOCK_COUNT)) {
            const block_index = inode.direct_blocks[logical_block];
            try self.validateDataBlockIndex(block_index);
            return block_index;
        }

        const indirect_logical = logical_block - DIRECT_BLOCK_COUNT;
        const indirect_slot: usize = @intCast(indirect_logical / POINTERS_PER_INDIRECT_BLOCK);
        if (indirect_slot >= INDIRECT_BLOCK_COUNT) return error.Corrupt;

        const indirect_block_index = inode.indirect_blocks[indirect_slot];
        try self.validateDataBlockIndex(indirect_block_index);

        const pointer_index: usize = @intCast(indirect_logical % POINTERS_PER_INDIRECT_BLOCK);
        try self.readIndirectPointerBlock(indirect_block_index, indirect_pointers);
        const block_index = indirect_pointers[pointer_index];
        try self.validateDataBlockIndex(block_index);
        return block_index;
    }

    fn readIndirectPointerBlock(self: *const FileSystem, block_index: u32, dest: *[POINTERS_PER_INDIRECT_BLOCK]u32) FsError!void {
        try self.validateDataBlockIndex(block_index);
        try self.block_dev.readBlock(self.dataBlockLba(block_index), @ptrCast(dest));
    }

    fn writeIndirectPointerBlock(self: *FileSystem, block_index: u32, pointers: []const u32) FsError!void {
        if (pointers.len > POINTERS_PER_INDIRECT_BLOCK) return error.Corrupt;
        try self.validateDataBlockIndex(block_index);

        var pointer_block = [_]u32{BLOCK_POINTER_NONE} ** POINTERS_PER_INDIRECT_BLOCK;
        for (pointers, 0..) |pointer, index| {
            try self.validateDataBlockIndex(pointer);
            pointer_block[index] = pointer;
        }

        try self.block_dev.writeBlock(self.dataBlockLba(block_index), @ptrCast(&pointer_block));
    }

    /// Read the directory inode and then a directory entry from it by index.
    /// Inefficient when used in a loop.
    fn readDirEntryFromInode(self: *const FileSystem, dir_inode_index: u16, index: usize) FsError!DirectoryEntry {
        const root_inode = try self.readDirectoryInode(dir_inode_index);
        return self.readDirEntry(&root_inode, index);
    }

    /// Read a directory entry from a directory inode by index.
    fn readDirEntry(self: *const FileSystem, dir_inode: *const Inode, index: usize) FsError!DirectoryEntry {
        // TODO: This is only implemented for the root directory with a fixed number of entries.
        if (index >= DIRECTORY_ENTRY_COUNT) return error.Corrupt;

        const block_slot = index / DIR_ENTRIES_PER_SECTOR;
        const entry_offset = (index % DIR_ENTRIES_PER_SECTOR) * @sizeOf(DirectoryEntry);
        const block_index = dir_inode.direct_blocks[block_slot];
        try self.validateDataBlockIndex(block_index);

        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(self.dataBlockLba(block_index), &sector);

        var entry: DirectoryEntry = undefined;
        @memcpy(std.mem.asBytes(&entry), sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)]);
        try validateDirectoryEntry(&entry, self.superblock.inode_count);
        return entry;
    }

    /// Write a directory entry to a directory inode by index.
    fn writeDirEntry(self: *const FileSystem, dir_inode_index: u16, index: usize, entry: *const DirectoryEntry) FsError!void {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.Corrupt;
        try validateDirectoryEntry(entry, self.superblock.inode_count);

        const dir_inode = try self.readDirectoryInode(dir_inode_index);
        const block_slot = index / DIR_ENTRIES_PER_SECTOR;
        const entry_offset = (index % DIR_ENTRIES_PER_SECTOR) * @sizeOf(DirectoryEntry);
        const block_index = dir_inode.direct_blocks[block_slot];
        try self.validateDataBlockIndex(block_index);

        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(self.dataBlockLba(block_index), &sector);
        @memcpy(sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)], std.mem.asBytes(entry));
        try self.block_dev.writeBlock(self.dataBlockLba(block_index), &sector);
    }

    /// Find a free data block from the bitmap and allocate it.
    fn allocateDataBlock(self: *FileSystem) FsError!u32 {
        var bitmap_sector_index: u32 = 0;
        while (bitmap_sector_index < self.superblock.bitmap_sector_count) : (bitmap_sector_index += 1) {
            const sector_lba = self.superblock.bitmap_start_lba + bitmap_sector_index;

            var sector = [_]u8{0} ** 512;
            try self.block_dev.readBlock(sector_lba, &sector);

            for (sector, 0..) |byte, byte_index| {
                if (byte == 0xFF) continue;

                var bit_index: u8 = 0;
                while (bit_index < 8) : (bit_index += 1) {
                    const candidate = bitmap_sector_index * 4096 + @as(u32, @intCast(byte_index * 8)) + bit_index;
                    if (candidate >= self.superblock.data_block_count) break;

                    const mask: u8 = @as(u8, 1) << @intCast(bit_index);
                    if ((sector[byte_index] & mask) != 0) continue;

                    sector[byte_index] |= mask;
                    try self.block_dev.writeBlock(sector_lba, &sector);
                    return candidate;
                }
            }
        }

        return error.NoSpace;
    }

    /// Free a data block in the bitmap by index.
    fn freeDataBlock(self: *FileSystem, block_index: u32) FsError!void {
        try self.setDataBlockAllocated(block_index, false);
    }

    fn setDataBlockAllocated(self: *FileSystem, block_index: u32, allocated: bool) FsError!void {
        try self.validateDataBlockIndex(block_index);

        const sector_index = block_index / 4096;
        const bit_in_sector: usize = @intCast(block_index % 4096);
        const byte_index = bit_in_sector / 8;
        const bit_index: u8 = @intCast(bit_in_sector % 8);
        const sector_lba = self.superblock.bitmap_start_lba + sector_index;

        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(sector_lba, &sector);

        const mask: u8 = @as(u8, 1) << @intCast(bit_index);
        if (allocated) {
            sector[byte_index] |= mask;
        } else {
            sector[byte_index] &= ~mask;
        }

        try self.block_dev.writeBlock(sector_lba, &sector);
    }

    fn blockMatches(self: *const FileSystem, block_index: u32, expected: *const [512]u8) FsError!bool {
        try self.validateDataBlockIndex(block_index);

        var sector = [_]u8{0} ** 512;
        try self.block_dev.readBlock(self.dataBlockLba(block_index), &sector);
        return std.mem.eql(u8, &sector, expected);
    }

    fn dataBlockLba(self: *const FileSystem, block_index: u32) u32 {
        return self.superblock.data_start_lba + block_index;
    }

    fn validateDataBlockIndex(self: *const FileSystem, block_index: u32) FsError!void {
        if (block_index == BLOCK_POINTER_NONE or block_index >= self.superblock.data_block_count) {
            return error.Corrupt;
        }
    }
};

fn makeDefaultSuperblock(layout: Layout) Superblock {
    comptime {
        std.debug.assert(@sizeOf(Inode) == 64);
        std.debug.assert(@sizeOf(DirectoryEntry) == 32);
        std.debug.assert(@sizeOf(Superblock) == 64);
    }
    return .{
        .magic = MAGIC,
        .version = VERSION,
        .block_size = 512,
        .fs_sector_count = layout.fs_sector_count,
        .bitmap_start_lba = layout.bitmap_start_lba,
        .bitmap_sector_count = layout.bitmap_sector_count,
        .inode_table_start_lba = layout.inode_table_start_lba,
        .inode_table_sector_count = layout.inode_table_sector_count,
        .inode_count = layout.inode_count,
        .data_start_lba = layout.data_start_lba,
        .data_block_count = layout.data_block_count,
        .file_count = 0,
        .reserved = [_]u8{0} ** 28,
    };
}

fn validateDirectoryEntry(entry: *const DirectoryEntry, inode_count: u16) FsError!void {
    switch (entry.kind) {
        DIR_ENTRY_KIND_FREE => {
            if (entry.name_len != 0) return error.Corrupt;
            return;
        },
        DIR_ENTRY_KIND_FILE, DIR_ENTRY_KIND_DIRECTORY => {},
        else => return error.Corrupt,
    }

    if (entry.inode_index >= inode_count) return error.Corrupt;
    if (entry.name_len == 0 or entry.name_len > FILENAME_MAX_LEN) return error.Corrupt;
    if (!validateName(entry.name[0..entry.name_len])) return error.Corrupt;
}

fn indirectBlocksForFileBlocks(block_count: u32) usize {
    if (block_count <= DIRECT_BLOCK_COUNT) return 0;

    const indirect_data_blocks = block_count - DIRECT_BLOCK_COUNT;
    return @intCast((indirect_data_blocks + POINTERS_PER_INDIRECT_BLOCK - 1) / POINTERS_PER_INDIRECT_BLOCK);
}
