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

pub const InodeT = u16;

const InodeKind = enum(u8) {
    Free = 0,
    File = 1,
    Directory = 2,
    _,
};

pub const BLOCK_SIZE = 512;

pub const ROOT_INODE_INDEX: InodeT = 0;
pub const DIRECT_BLOCK_COUNT: usize = 8;
pub const BLOCK_POINTER_NONE: u32 = std.math.maxInt(u32);
pub const POINTERS_PER_INDIRECT_BLOCK: usize = BLOCK_SIZE / @sizeOf(u32);

pub const INODES_PER_SECTOR: usize = BLOCK_SIZE / @sizeOf(Inode);
pub const DIR_ENTRIES_PER_SECTOR: usize = BLOCK_SIZE / @sizeOf(DirectoryEntry);
pub const MIN_INODE_COUNT: usize = DIRECTORY_ENTRY_COUNT + 1;
pub const ROOT_DIRECTORY_BYTES: usize = DIRECTORY_ENTRY_COUNT * @sizeOf(DirectoryEntry);
pub const ROOT_DIRECTORY_SECTORS: u32 = sectorsForBytes(ROOT_DIRECTORY_BYTES); // = 4

pub const Inode = extern struct {
    kind: InodeKind = InodeKind.Free,
    reserved0: u8 = 0,
    link_count: u16 = 0,
    size_bytes: u32 = 0,
    direct_blocks: [DIRECT_BLOCK_COUNT]u32 = @splat(BLOCK_POINTER_NONE),
    indirect_block: u32 = BLOCK_POINTER_NONE,
    double_indirect_block: u32 = BLOCK_POINTER_NONE,
    reserved: [16]u8 = @splat(0),
};

pub const DirectoryEntry = extern struct {
    inode_index: InodeT = 0,
    kind: InodeKind = InodeKind.Free,
    name_len: u8 = 0,
    name: [FILENAME_MAX_LEN]u8 = @splat(0),
    reserved: [12]u8 = @splat(0),
};

const Superblock = extern struct {
    magic: [4]u8,
    version: u16,
    block_size: u16, // Currently always 512
    fs_sector_count: u32, // Total number of sectors managed by the filesystem
    bitmap_start_lba: u32, // LBA (logical block address) of the start of the block allocation bitmap
    bitmap_sector_count: u16, // Number of sectors allocated to the block allocation bitmap
    inode_table_sector_count: u16, // Number of sectors allocated to the inode table
    inode_table_start_lba: u32, // LBA of the start of the inode table
    inode_count: u16, // Total number of inodes in the inode table
    file_count: u16, // Total number of filesystem entries, excluding the root directory
    data_start_lba: u32, // LBA of the start of the data blocks
    data_block_count: u32, // Total number of data blocks
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
    is_directory: bool,
};

/// Returns the number of 512-byte sectors needed to store `len` bytes.
pub fn sectorsForBytes(len: usize) u32 {
    if (len == 0) return 0;
    return @intCast((len + BLOCK_SIZE - 1) / BLOCK_SIZE);
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

fn makeDefaultSuperblock(layout: Layout) Superblock {
    comptime {
        std.debug.assert(@sizeOf(Inode) == 64);
        std.debug.assert(@sizeOf(DirectoryEntry) == 32);
        std.debug.assert(@sizeOf(Superblock) == 64);
    }
    return .{
        .magic = MAGIC,
        .version = VERSION,
        .block_size = BLOCK_SIZE,
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

/// Validates a mounted superblock against the expected derived layout.
pub fn isValidSuperblock(superblock: *const Superblock) bool {
    const layout = computeLayout(superblock.fs_sector_count) orelse return false;

    return std.mem.eql(u8, superblock.magic[0..], MAGIC[0..]) and
        superblock.version == VERSION and
        superblock.block_size == BLOCK_SIZE and
        superblock.bitmap_start_lba == layout.bitmap_start_lba and
        superblock.bitmap_sector_count == layout.bitmap_sector_count and
        superblock.inode_table_start_lba == layout.inode_table_start_lba and
        superblock.inode_table_sector_count == layout.inode_table_sector_count and
        superblock.inode_count == layout.inode_count and
        superblock.data_start_lba == layout.data_start_lba and
        superblock.data_block_count == layout.data_block_count and
        superblock.file_count < superblock.inode_count;
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
    NotARegularFile,
    NotADirectory,
    InvalidName,
    InvalidSuperblock,
    NoSpace,
} || block_device.BlockError;

pub const ReadFileError = FsError || error{OutOfMemory};
pub const WriteFileError = FsError || error{OutOfMemory};

const MAX_FILE_BLOCK_COUNT: usize = DIRECT_BLOCK_COUNT + POINTERS_PER_INDIRECT_BLOCK + POINTERS_PER_INDIRECT_BLOCK * POINTERS_PER_INDIRECT_BLOCK;

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

    fn zeroBlock(self: *FileSystem, block_index: u32) FsError!void {
        var zero_sector = [_]u8{0} ** BLOCK_SIZE;
        try self.writeDataBlock(block_index, &zero_sector);
    }

    fn readDataBlock(self: *const FileSystem, block_index: u32, dest: *[BLOCK_SIZE]u8) FsError!void {
        const lba = self.dataBlockLba(block_index);
        try self.block_dev.readBlock(lba, dest);
    }

    fn writeDataBlock(self: *FileSystem, block_index: u32, data: *const [BLOCK_SIZE]u8) FsError!void {
        const lba = self.dataBlockLba(block_index);
        try self.block_dev.writeBlock(lba, data);
    }

    /// Formats the filesystem region with the current inode-based layout.
    pub fn format(self: *FileSystem) FsError!void {
        const fs_sector_count = self.block_dev.block_count - FS_START_LBA;
        const layout = computeLayout(fs_sector_count) orelse return error.NoSpace;
        self.superblock = makeDefaultSuperblock(layout);

        var zero_sector = [_]u8{0} ** BLOCK_SIZE;
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
        root_inode.kind = InodeKind.Directory;
        root_inode.link_count = 1;
        root_inode.size_bytes = @intCast(ROOT_DIRECTORY_BYTES);
        for (root_blocks, 0..) |block_index, index| {
            root_inode.direct_blocks[index] = block_index;
        }
        try self.writeInode(ROOT_INODE_INDEX, &root_inode);
        try self.writeSuperblock();
    }

    /// Returns metadata for a non-empty directory slot.
    pub fn getFileInfo(self: *const FileSystem, dir_inode_index: InodeT, index: usize) FsError!?FileInfo {
        if (index >= DIRECTORY_ENTRY_COUNT) return null;

        const entry = try self.readDirEntryFromInode(dir_inode_index, index);
        if (entry.kind == .Free) return null;

        const inode = try self.readInode(entry.inode_index);
        try self.validateInode(&inode);
        return .{
            .index = index,
            .name = entry.name,
            .name_len = @intCast(entry.name_len),
            .size_bytes = inode.size_bytes,
            .sector_count = fileBlocksForSize(inode.size_bytes),
            .is_directory = inode.kind == InodeKind.Directory,
        };
    }

    /// Returns the raw directory entry for a slot when it contains a file or directory.
    pub fn getDirectoryEntry(self: *const FileSystem, dir_inode_index: InodeT, index: usize) FsError!?DirectoryEntry {
        if (index >= DIRECTORY_ENTRY_COUNT) return null;

        const entry = try self.readDirEntryFromInode(dir_inode_index, index);
        if (entry.kind == InodeKind.Free) return null;
        return entry;
    }

    /// Resolves a directory slot to its backing inode number.
    pub fn getFileInodeIndex(self: *const FileSystem, dir_inode_index: InodeT, index: usize) FsError!InodeT {
        const entry = try self.readDirectoryEntry(dir_inode_index, index);
        return entry.inode_index;
    }

    fn createFileInternal(self: *FileSystem, dir_inode_index: InodeT, name: []const u8, kind: InodeKind, size: u32) FsError!InodeT {
        if (!validateName(name)) return error.InvalidName;
        if ((try self.findDirEntry(dir_inode_index, name)) != null) return error.FileExists;

        const entry_index = try self.findReusableEntryIndex(dir_inode_index);
        const inode_index = try self.findFreeInodeIndex();

        const num_blocks = fileBlocksForSize(size);

        var inode: Inode = .{};
        inode.kind = kind;
        inode.size_bytes = size;
        inode.link_count = 1;
        if (size > 0)
            try self.allocBlockTree(&inode, num_blocks);
        try self.writeInode(inode_index, &inode);

        // Zero out any data blocks allocated to the file
        if (size > 0) {
            for (0..num_blocks) |logical_block| {
                const data_block = try self.getInodeDataBlock(&inode, @intCast(logical_block));
                try self.zeroBlock(data_block);
            }
        }

        var entry: DirectoryEntry = .{};
        entry.inode_index = inode_index;
        entry.kind = kind;
        entry.name_len = @intCast(name.len);
        @memcpy(entry.name[0..name.len], name);
        try self.writeDirEntry(dir_inode_index, entry_index, &entry);

        self.superblock.file_count += 1;
        try self.writeSuperblock();
        return inode_index;
    }

    /// Creates a new empty regular file in the given directory and returns its inode index.
    pub fn createFile(self: *FileSystem, dir_inode_index: InodeT, name: []const u8) FsError!InodeT {
        return self.createFileInternal(dir_inode_index, name, InodeKind.File, 0);
    }

    /// Creates a new empty directory in the given directory and returns its inode index.
    pub fn createDirectory(self: *FileSystem, dir_inode_index: InodeT, name: []const u8) FsError!InodeT {
        return self.createFileInternal(dir_inode_index, name, InodeKind.Directory, ROOT_DIRECTORY_BYTES);
    }

    /// Returns the current byte length for a file identified by inode number.
    pub fn getInodeSize(self: *const FileSystem, inode_index: InodeT) FsError!u32 {
        const inode = try self.readFileInode(inode_index);
        return inode.size_bytes;
    }

    /// Truncates a file identified directly by inode number to zero bytes.
    pub fn truncateInode(self: *FileSystem, inode_index: InodeT) FsError!void {
        var inode = try self.readFileInode(inode_index);
        try self.writeToInodeAtOffset(inode_index, &inode, 0, &.{}, true);
    }

    //////////// FILE READING ////////////

    /// Reads an entire regular file, given by its full path, into allocator-owned memory.
    pub fn readFile(self: *const FileSystem, allocator: std.mem.Allocator, path: []const u8) ReadFileError![]u8 {
        const inode_index = try self.walkFilePathToInode(ROOT_INODE_INDEX, path);
        const inode = try self.readFileInode(inode_index);
        return self.readInodeContents(allocator, &inode);
    }

    /// Reads an entire regular file from the given directory into allocator-owned memory.
    pub fn readFileAt(self: *const FileSystem, allocator: std.mem.Allocator, dir_inode_index: InodeT, name: []const u8) ReadFileError![]u8 {
        const inode_index = try self.findFileInodeIndex(dir_inode_index, name) orelse return error.FileNotFound;
        const inode = try self.readFileInode(inode_index);
        return self.readInodeContents(allocator, &inode);
    }

    fn readInodeContents(self: *const FileSystem, allocator: std.mem.Allocator, inode: *const Inode) ReadFileError![]u8 {
        if (inode.size_bytes == 0) {
            return allocator.alloc(u8, 0);
        }

        const data = try allocator.alloc(u8, @intCast(inode.size_bytes));
        errdefer allocator.free(data);
        _ = try self.readInodeAt(inode, 0, data);
        return data;
    }

    /// Reads bytes from a file identified directly by inode number.
    pub fn readInodeAt(self: *const FileSystem, inode: *const Inode, offset: u32, dest: []u8) FsError!usize {
        if (dest.len == 0) return 0;
        if (offset >= inode.size_bytes) return 0;

        var remaining: usize = @min(dest.len, @as(usize, @intCast(inode.size_bytes - offset)));
        var logical_block: u32 = offset / BLOCK_SIZE;
        var block_offset: usize = @intCast(offset % BLOCK_SIZE);
        var out_offset: usize = 0;
        var sector = [_]u8{0} ** BLOCK_SIZE;

        while (remaining > 0) : (logical_block += 1) {
            const data_block = try self.getInodeDataBlock(inode, logical_block);
            try self.block_dev.readBlock(self.dataBlockLba(data_block), &sector);

            const chunk_len: usize = @min(remaining, sector.len - block_offset);
            @memcpy(dest[out_offset .. out_offset + chunk_len], sector[block_offset .. block_offset + chunk_len]);
            out_offset += chunk_len;
            remaining -= chunk_len;
            block_offset = 0;
        }

        return out_offset;
    }

    //////////// FILE WRITING ////////////

    /// Creates or overwrites a file in the given directory with the provided full contents.
    pub fn writeFile(self: *FileSystem, path: []const u8, data: []const u8) WriteFileError!void {
        const split = splitPath(path);
        const dir_inode_index = try self.walkFilePathToInode(ROOT_INODE_INDEX, split.dir);
        try self.writeFileAt(dir_inode_index, split.name, data);
    }

    /// Creates or overwrites a file in the given directory with the provided full contents.
    pub fn writeFileAt(self: *FileSystem, dir_inode_index: InodeT, name: []const u8, data: []const u8) FsError!void {
        if (!validateName(name)) return error.InvalidName;
        if (fileBlocksForSize(@intCast(data.len)) > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        const inode_index = try self.findFileInodeIndex(dir_inode_index, name) orelse
            try self.createFile(dir_inode_index, name);
        var inode = try self.readFileInode(inode_index);
        try self.writeToInodeAtOffset(inode_index, &inode, 0, data, true);
    }

    /// Writes bytes to a file identified directly by inode number, growing as needed.
    pub fn writeInodeAt(self: *FileSystem, inode_index: InodeT, offset: u32, data: []const u8) WriteFileError!usize {
        if (data.len == 0) return 0;

        var inode = try self.readFileInode(inode_index);
        try self.writeToInodeAtOffset(inode_index, &inode, offset, data, false);
        return data.len;
    }

    //////////// PATH WALKING ////////////

    /// Walk a full file path, starting from the given directory inode index.
    /// Returns { parent_dir_inode_index, dir_entry_index, dir_entry } or error.FileNotFound.
    pub fn walkFilePathToDirEntry(self: *const FileSystem, dir_inode_index: InodeT, path: []const u8) FsError!struct { InodeT, u32, DirectoryEntry } {
        var current_dir = dir_inode_index;
        var path_iter = std.mem.splitScalar(u8, path, '/');

        // TODO: proper handling of absolute vs relative paths
        // TODO: handle "." and ".." components
        while (path_iter.next()) |component| {
            if (component.len == 0) continue;

            const index, const entry = try self.findDirEntryAndIndex(current_dir, component) orelse return error.FileNotFound;
            if (path_iter.peek() == null) {
                // At end of path - return the entry
                return .{ current_dir, index, entry };
            } else {
                // Not at end of path - must be a directory to continue traversal
                if (entry.kind != .Directory) return error.FileNotFound;
            }

            current_dir = entry.inode_index;
        }
        // TODO: this is reachable if the path is empty or "/"
        unreachable;
    }

    /// Walk a full file path, starting from the given directory inode index.
    /// Returns the final file's inode index or error.FileNotFound.
    pub fn walkFilePathToInode(self: *const FileSystem, dir_inode_index: InodeT, path: []const u8) FsError!InodeT {
        if (path.len == 0) return dir_inode_index;
        if (path.len == 1 and path[0] == '/') return ROOT_INODE_INDEX;
        _, _, const entry = try self.walkFilePathToDirEntry(dir_inode_index, path);
        return entry.inode_index;
    }

    fn splitPath(path: []const u8) struct { dir: []const u8, name: []const u8 } {
        const trimmed = std.mem.trimEnd(u8, path, "/");
        const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
        if (last_slash) |idx| {
            return .{ .dir = trimmed[0..idx], .name = trimmed[idx + 1 ..] };
        } else {
            return .{ .dir = &.{}, .name = trimmed };
        }
    }

    /// Deletes a regular file from the given directory and frees its inode and blocks.
    pub fn deleteFile(self: *FileSystem, dir_inode_index: InodeT, index: u32) FsError!void {
        const entry = try self.readDirectoryEntry(dir_inode_index, index);

        if (entry.kind != .File) return error.NotARegularFile;

        try self.destroyInode(entry.inode_index);
        var cleared: DirectoryEntry = .{};
        try self.writeDirEntry(dir_inode_index, index, &cleared);

        self.superblock.file_count -= 1;
        try self.writeSuperblock();
    }

    /// Renames a regular file within the root directory.
    pub fn renameFile(self: *FileSystem, old_name: []const u8, new_name: []const u8) FsError!void {
        if (!validateName(new_name)) return error.InvalidName;

        const index = (try self.findFileIndex(ROOT_INODE_INDEX, old_name)) orelse return error.FileNotFound;
        if ((try self.findFileIndex(ROOT_INODE_INDEX, new_name)) != null) return error.FileExists;

        var entry = try self.readDirectoryEntry(ROOT_INODE_INDEX, index);

        if (entry.kind != .File) return error.NotARegularFile;

        entry.name_len = @intCast(new_name.len);
        entry.name = [_]u8{0} ** FILENAME_MAX_LEN;
        @memcpy(entry.name[0..new_name.len], new_name);
        try self.writeDirEntry(ROOT_INODE_INDEX, index, &entry);
    }

    fn readSuperblock(self: *FileSystem) FsError!void {
        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(FS_START_LBA, &sector);

        var superblock: Superblock = undefined;
        @memcpy(std.mem.asBytes(&superblock), sector[0..@sizeOf(Superblock)]);
        if (!isValidSuperblock(&superblock)) {
            return error.InvalidSuperblock;
        }

        self.superblock = superblock;
    }

    fn writeSuperblock(self: *const FileSystem) FsError!void {
        var sector = [_]u8{0} ** BLOCK_SIZE;
        @memcpy(sector[0..@sizeOf(Superblock)], std.mem.asBytes(&self.superblock));
        try self.block_dev.writeBlock(FS_START_LBA, &sector);
    }

    fn validateRootDirectory(self: *const FileSystem) FsError!void {
        const root_inode = try self.readDirectoryInode(ROOT_INODE_INDEX);
        if (root_inode.size_bytes != @as(u32, @intCast(ROOT_DIRECTORY_BYTES))) return error.Corrupt;
        if (fileBlocksForSize(root_inode.size_bytes) != ROOT_DIRECTORY_SECTORS) return error.Corrupt;
        if (root_inode.indirect_block != BLOCK_POINTER_NONE or root_inode.double_indirect_block != BLOCK_POINTER_NONE) {
            return error.Corrupt;
        }

        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&root_inode, index);
            switch (entry.kind) {
                .Free => {},
                .File => {
                    _ = try self.readFileInode(entry.inode_index);
                },
                .Directory => {
                    _ = try self.readDirectoryInode(entry.inode_index);
                },
                else => return error.Corrupt,
            }
        }
    }

    /// Looks up a named entry in the given directory; returns its slot index and the entry itself.
    fn findDirEntryAndIndex(self: *const FileSystem, dir_inode_index: InodeT, name: []const u8) FsError!?struct { u32, DirectoryEntry } {
        if (!validateName(name)) return error.InvalidName;

        const dir_inode = try self.readDirectoryInode(dir_inode_index);

        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&dir_inode, index);
            if (entry.kind == InodeKind.Free) continue;
            if (entry.name_len != @as(u8, @intCast(name.len))) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return .{ @intCast(index), entry };
            }
        }

        return null;
    }

    /// Looks up a named entry in the given directory.
    fn findDirEntry(self: *const FileSystem, dir_inode_index: InodeT, name: []const u8) FsError!?DirectoryEntry {
        if (try self.findDirEntryAndIndex(dir_inode_index, name)) |result| {
            return result.@"1";
        } else {
            return null;
        }
    }

    /// Given the name of a regular file in a directory, find its directory slot index.
    fn findFileIndex(self: *const FileSystem, dir_inode_index: InodeT, name: []const u8) FsError!?u32 {
        if (!validateName(name)) return error.InvalidName;

        const dir_inode = try self.readDirectoryInode(dir_inode_index);
        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&dir_inode, index);
            if (entry.kind != InodeKind.File) continue;
            if (entry.name_len != @as(u8, @intCast(name.len))) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return @intCast(index);
            }
        }

        return null;
    }

    /// Given the name of a regular file in a directory, find its inode index.
    pub fn findFileInodeIndex(self: *const FileSystem, dir_inode_index: InodeT, name: []const u8) FsError!?InodeT {
        const entry = (try self.findDirEntry(dir_inode_index, name)) orelse return null;
        if (entry.kind != InodeKind.File) return null;
        return entry.inode_index;
    }

    /// Find a free directory entry within the given directory.
    fn findReusableEntryIndex(self: *const FileSystem, dir_inode_index: InodeT) FsError!usize {
        var index: usize = 0;
        const dir_inode = try self.readDirectoryInode(dir_inode_index);
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(&dir_inode, index);
            if (entry.kind == .Free) return index;
        }
        return error.DirectoryFull;
    }

    /// Find a free inode index within the inode table.
    fn findFreeInodeIndex(self: *const FileSystem) FsError!InodeT {
        var inode_index: InodeT = ROOT_INODE_INDEX + 1;
        while (inode_index < self.superblock.inode_count) : (inode_index += 1) {
            const inode = try self.readInode(inode_index);
            if (inode.kind == .Free) return inode_index;
        }
        return error.NoSpace;
    }

    /// Read the inode with the given index and verify that it is a valid file inode.
    pub fn readFileInode(self: *const FileSystem, inode_index: InodeT) FsError!Inode {
        const inode = try self.readInode(inode_index);
        try self.validateInode(&inode);
        if (inode.kind != .File) return error.NotARegularFile;
        return inode;
    }

    /// Read the inode with the given index and verify that it is a valid directory inode.
    fn readDirectoryInode(self: *const FileSystem, inode_index: InodeT) FsError!Inode {
        const inode = try self.readInode(inode_index);
        try self.validateInode(&inode);
        if (inode.kind != .Directory) return error.NotADirectory;
        return inode;
    }

    // Recursively allocates or frees blocks for an inode, starting from a given block pointer and descending through indirect blocks as needed.
    fn recAllocBlockTree(self: *FileSystem, block_index: *u32, num_wanted: *u32, level: u32) !void {
        const is_present = block_index.* != BLOCK_POINTER_NONE;

        if (!is_present and num_wanted.* == 0) {
            // Don't want a block, and the index is already NONE; nothing to do.
            return;
        }

        if (level == 0) {
            if (num_wanted.* > 0) {
                if (!is_present)
                    block_index.* = try self.allocateDataBlock();
                num_wanted.* -= 1;
            } else if (num_wanted.* == 0) {
                // Must be present since we checked for the NONE case above.
                try self.freeDataBlock(block_index.*);
                block_index.* = BLOCK_POINTER_NONE;
            }
        } else {
            const block_wanted = num_wanted.* > 0;

            // Either load block pointers from disk or initialize empty pointer array
            var block_pointers: [POINTERS_PER_INDIRECT_BLOCK]u32 = undefined;
            if (is_present) {
                try self.readIndirectPointerBlock(block_index.*, &block_pointers);
            } else {
                @memset(&block_pointers, BLOCK_POINTER_NONE);
            }

            // Recursively allocate block pointers in the indirect block
            for (&block_pointers) |*pointer| {
                try self.recAllocBlockTree(pointer, num_wanted, level - 1);
            }

            // Allocate/destroy indirect block itself
            if (!is_present and block_wanted) {
                block_index.* = try self.allocateDataBlock();
            } else if (is_present and !block_wanted) {
                try self.freeDataBlock(block_index.*);
                block_index.* = BLOCK_POINTER_NONE;
            }

            // If the block has any non-null pointers, write it back to disk
            if (block_wanted) {
                try self.writeDataBlock(block_index.*, @ptrCast(&block_pointers));
            }
        }
    }

    // Recursively allocates or frees blocks for an inode, so that num_wanted_blocks (or as many as can fit in this tree) are allocated.
    fn allocBlockTree(self: *FileSystem, inode: *Inode, num_wanted_blocks: u32) !void {
        var num_wanted = num_wanted_blocks;
        for (0..DIRECT_BLOCK_COUNT) |i| {
            try self.recAllocBlockTree(&inode.direct_blocks[i], &num_wanted, 0);
        }
        try self.recAllocBlockTree(&inode.indirect_block, &num_wanted, 1);
        try self.recAllocBlockTree(&inode.double_indirect_block, &num_wanted, 2);
        if (num_wanted > 0) return error.NoSpace;
    }

    /// Replace or extend file contents by writing the data slice starting at the given offset.
    /// If `truncate` is true, the file will be truncated to the end of the new data;
    /// otherwise, existing data after the end of the new data will be preserved.
    /// If ofs is beyond the current end of the file, the file will be zero-padded up to that point before writing the new data.
    fn writeToInodeAtOffset(
        self: *FileSystem,
        inode_index: InodeT,
        inode: *Inode,
        ofs: u32,
        data: []const u8,
        truncate: bool,
    ) FsError!void {
        const data_end: u32 = std.math.add(u32, ofs, @intCast(data.len)) catch return error.NoSpace;
        const new_size: u32 = if (truncate)
            data_end // if truncating, the file will end after the given data
        else
            @max(inode.size_bytes, data_end); // otherwise, keep any existing data after the write window
        // NB: new_size >= data_end = ofs + data.len

        const old_total_blocks = fileBlocksForSize(inode.size_bytes);
        const new_total_blocks = fileBlocksForSize(new_size);
        if (new_total_blocks > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        // Allocate the block tree structure
        try self.allocBlockTree(inode, new_total_blocks);

        // Update the inode on disk (do this early to minimize risk of leaving orphaned blocks)
        inode.size_bytes = new_size;
        try self.writeInode(inode_index, inode);

        const first_block = ofs / BLOCK_SIZE; // First block index which contains the new data being written

        // If the write starts beyond the current end of the file, we need to zero-pad the gap between the old end and the start of the write.
        if (first_block > old_total_blocks) {
            var block_idx = old_total_blocks; // block currently being zeroed
            while (block_idx < first_block) : (block_idx += 1) {
                const data_block = try self.getInodeDataBlock(inode, @intCast(block_idx));
                try self.zeroBlock(data_block);
            }
        }

        var sector = [_]u8{0} ** BLOCK_SIZE;

        // Fill the allocated blocks with the new data
        var block_idx = first_block; // block currently being written
        var block_cursor: u32 = ofs % BLOCK_SIZE; // offset within current block (only relevant for first block)
        var data_cursor: usize = 0; // current offset within data slice

        // TODO: Possible bug: if the data has length 0, no zeroing occurs.
        while (data_cursor < data.len) {
            const num_bytes: usize = @min(data.len - data_cursor, BLOCK_SIZE - block_cursor);
            const data_block = try self.getInodeDataBlock(inode, @intCast(block_idx));

            // For incomplete block writes, check if we need to read the old block contents
            if (num_bytes != BLOCK_SIZE) {
                if (block_idx < old_total_blocks) {
                    try self.readDataBlock(data_block, &sector);
                } else {
                    @memset(&sector, 0);
                }
            }

            @memcpy(sector[block_cursor .. block_cursor + num_bytes], data[data_cursor .. data_cursor + num_bytes]);
            try self.writeDataBlock(data_block, &sector);

            data_cursor += num_bytes;
            block_idx += 1;
            block_cursor = 0;
        }
    }

    fn destroyInode(self: *FileSystem, inode_index: InodeT) FsError!void {
        var inode = try self.readFileInode(inode_index);

        try self.allocBlockTree(&inode, 0);

        var cleared: Inode = .{};
        try self.writeInode(inode_index, &cleared);
    }

    fn readInode(self: *const FileSystem, inode_index: InodeT) FsError!Inode {
        if (inode_index >= self.superblock.inode_count) return error.Corrupt;

        const sector_lba = self.superblock.inode_table_start_lba +
            @divFloor(@as(u32, inode_index), @as(u32, @intCast(INODES_PER_SECTOR)));
        const inode_offset = (@as(usize, inode_index) % INODES_PER_SECTOR) * @sizeOf(Inode);

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(sector_lba, &sector);

        var inode: Inode = undefined;
        @memcpy(std.mem.asBytes(&inode), sector[inode_offset .. inode_offset + @sizeOf(Inode)]);
        return inode;
    }

    fn writeInode(self: *const FileSystem, inode_index: InodeT, inode: *const Inode) FsError!void {
        if (inode_index >= self.superblock.inode_count) return error.Corrupt;

        const sector_lba = self.superblock.inode_table_start_lba +
            @divFloor(@as(u32, inode_index), @as(u32, @intCast(INODES_PER_SECTOR)));
        const inode_offset = (@as(usize, inode_index) % INODES_PER_SECTOR) * @sizeOf(Inode);

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(sector_lba, &sector);
        @memcpy(sector[inode_offset .. inode_offset + @sizeOf(Inode)], std.mem.asBytes(inode));
        try self.block_dev.writeBlock(sector_lba, &sector);
    }

    fn validateInode(self: *const FileSystem, inode: *const Inode) FsError!void {
        switch (inode.kind) {
            .Free => {
                if (inode.size_bytes != 0 or inode.link_count != 0) return error.Corrupt;
                for (inode.direct_blocks) |block_index| {
                    if (block_index != BLOCK_POINTER_NONE) return error.Corrupt;
                }
                if (inode.indirect_block != BLOCK_POINTER_NONE) return error.Corrupt;
                if (inode.double_indirect_block != BLOCK_POINTER_NONE) return error.Corrupt;
                return;
            },
            .File, .Directory => {},
            else => return error.Corrupt,
        }

        if (inode.link_count == 0) return error.Corrupt;

        const block_count = fileBlocksForSize(inode.size_bytes);
        if (block_count > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.Corrupt;

        const used_direct = @min(@as(usize, @intCast(block_count)), DIRECT_BLOCK_COUNT);

        for (inode.direct_blocks, 0..) |block_index, index| {
            if (index < used_direct) {
                try self.validateDataBlockIndex(block_index);
            } else if (block_index != BLOCK_POINTER_NONE) {
                return error.Corrupt;
            }
        }

        if (inode.indirect_block != BLOCK_POINTER_NONE) {
            try self.validateDataBlockIndex(inode.indirect_block);
        }
        if (inode.double_indirect_block != BLOCK_POINTER_NONE) {
            try self.validateDataBlockIndex(inode.double_indirect_block);
        }
    }

    /// Collects the data block indices for all logical blocks used by an inode into dest.
    fn collectInodeDataBlocks(self: *const FileSystem, inode: *const Inode, dest: []u32) FsError!void {
        const block_count = fileBlocksForSize(inode.size_bytes);
        if (dest.len < block_count) return error.Corrupt;

        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            dest[block_index] = try self.getInodeDataBlock(inode, @intCast(block_index));
        }
    }

    /// Walk an indirect block tree, starting from index block_tree, to find the logical data block with number block_logical.
    fn walkBlockTree(self: *const FileSystem, block_logical: u32, block_tree: u32, level: u32) !u32 {
        if (block_logical == BLOCK_POINTER_NONE) return error.Corrupt;

        var cur_blockidx = block_logical;
        var cur_level = level;
        var cur_tree = block_tree;
        try self.validateDataBlockIndex(cur_tree);

        var block_pointers: [POINTERS_PER_INDIRECT_BLOCK]u32 = undefined;

        while (cur_level > 0) : (cur_level -= 1) {
            try self.readIndirectPointerBlock(cur_tree, &block_pointers);

            const blocks_per_pointer = std.math.pow(u32, POINTERS_PER_INDIRECT_BLOCK, cur_level - 1);
            const blocks_per_level = blocks_per_pointer * POINTERS_PER_INDIRECT_BLOCK;
            if (cur_blockidx >= blocks_per_level) @panic("block index out of range for block tree");

            const pointer_index = @divTrunc(cur_blockidx, blocks_per_pointer);

            cur_tree = block_pointers[pointer_index];
            cur_blockidx = @mod(cur_blockidx, blocks_per_pointer);
            try self.validateDataBlockIndex(cur_tree);
        }
        return cur_tree;
    }

    /// Find the data block index for a given logical block within an inode.
    fn getInodeDataBlock(self: *const FileSystem, inode: *const Inode, logical_block: u32) FsError!u32 {
        if (logical_block < @as(u32, DIRECT_BLOCK_COUNT)) {
            const block_index = inode.direct_blocks[logical_block];
            try self.validateDataBlockIndex(block_index);
            return block_index;
        }

        var idx = logical_block - @as(u32, DIRECT_BLOCK_COUNT);
        if (idx < POINTERS_PER_INDIRECT_BLOCK) {
            return try self.walkBlockTree(idx, inode.indirect_block, 1);
        }

        idx -= POINTERS_PER_INDIRECT_BLOCK;
        if (idx < POINTERS_PER_INDIRECT_BLOCK * POINTERS_PER_INDIRECT_BLOCK) {
            return try self.walkBlockTree(idx, inode.double_indirect_block, 2);
        }

        // Invalid logical block index for the inode (too large for maximum tree size)
        return error.Corrupt;
    }

    fn readIndirectPointerBlock(self: *const FileSystem, block_index: u32, dest: *[POINTERS_PER_INDIRECT_BLOCK]u32) FsError!void {
        try self.validateDataBlockIndex(block_index);
        try self.block_dev.readBlock(self.dataBlockLba(block_index), @ptrCast(dest));
    }

    fn readDirectoryEntry(self: *const FileSystem, dir_inode_index: InodeT, index: usize) FsError!DirectoryEntry {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.FileNotFound;

        const entry = try self.readDirEntryFromInode(dir_inode_index, index);
        if (entry.kind == .Free) return error.FileNotFound;
        return entry;
    }

    /// Read the directory inode and then a directory entry from it by index.
    /// Inefficient when used in a loop.
    fn readDirEntryFromInode(self: *const FileSystem, dir_inode_index: InodeT, index: usize) FsError!DirectoryEntry {
        const root_inode = try self.readDirectoryInode(dir_inode_index);
        return self.readDirEntry(&root_inode, index);
    }

    /// Read a directory entry from a directory inode by index.
    fn readDirEntry(self: *const FileSystem, dir_inode: *const Inode, index: usize) FsError!DirectoryEntry {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.Corrupt;

        const block_slot = index / DIR_ENTRIES_PER_SECTOR;
        const entry_offset = (index % DIR_ENTRIES_PER_SECTOR) * @sizeOf(DirectoryEntry);
        const block_index = dir_inode.direct_blocks[block_slot];
        try self.validateDataBlockIndex(block_index);

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(self.dataBlockLba(block_index), &sector);

        var entry: DirectoryEntry = undefined;
        @memcpy(std.mem.asBytes(&entry), sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)]);
        try validateDirectoryEntry(&entry, self.superblock.inode_count);
        return entry;
    }

    /// Write a directory entry to a directory inode by index.
    fn writeDirEntry(self: *FileSystem, dir_inode_index: InodeT, index: usize, entry: *const DirectoryEntry) FsError!void {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.Corrupt;
        try validateDirectoryEntry(entry, self.superblock.inode_count);

        const dir_inode = try self.readDirectoryInode(dir_inode_index);
        const block_slot = index / DIR_ENTRIES_PER_SECTOR;
        const entry_offset = (index % DIR_ENTRIES_PER_SECTOR) * @sizeOf(DirectoryEntry);
        const block_index = dir_inode.direct_blocks[block_slot];
        try self.validateDataBlockIndex(block_index);

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(self.dataBlockLba(block_index), &sector);
        @memcpy(sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)], std.mem.asBytes(entry));
        try self.writeDataBlock(block_index, &sector);
    }

    /// Find a free data block from the bitmap and allocate it.
    fn allocateDataBlock(self: *FileSystem) FsError!u32 {
        var bitmap_sector_index: u32 = 0;
        while (bitmap_sector_index < self.superblock.bitmap_sector_count) : (bitmap_sector_index += 1) {
            const sector_lba = self.superblock.bitmap_start_lba + bitmap_sector_index;

            var sector = [_]u8{0} ** BLOCK_SIZE;
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

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(sector_lba, &sector);

        const mask: u8 = @as(u8, 1) << @intCast(bit_index);
        if (allocated) {
            sector[byte_index] |= mask;
        } else {
            sector[byte_index] &= ~mask;
        }

        try self.block_dev.writeBlock(sector_lba, &sector);
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

fn validateDirectoryEntry(entry: *const DirectoryEntry, inode_count: u16) FsError!void {
    switch (entry.kind) {
        .Free => {
            if (entry.name_len != 0) return error.Corrupt;
            return;
        },
        .File, .Directory => {},
        else => return error.Corrupt,
    }

    if (entry.inode_index >= inode_count) return error.Corrupt;
    if (entry.name_len == 0 or entry.name_len > FILENAME_MAX_LEN) return error.Corrupt;
    if (!validateName(entry.name[0..entry.name_len])) return error.Corrupt;
}
