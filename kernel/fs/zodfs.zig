// ZODFS v2: a simple inode-based filesystem for Zoodle86.

const block_device = @import("../block_device.zig");
const BlockDevice = block_device.BlockDevice;
const abi = @import("abi");
const std = @import("std");

pub const FILENAME_MAX_LEN: usize = 16;
pub const DIRECTORY_ENTRY_COUNT: usize = 64;
pub const STAGE2_RESERVED_SECTORS: u32 = 16;
pub const SUPERBLOCK_SECTORS: u32 = 1;

pub const FS_START_LBA: u32 = 1 + STAGE2_RESERVED_SECTORS;

pub const MAGIC = "ZOD2".*;
pub const VERSION: u16 = 2;

pub const InodeT = u16;

const InodeKind = abi.InodeKind;

pub const BLOCK_SIZE = 512;

pub const ROOT_INODE_INDEX: InodeT = 0;
pub const DIRECT_BLOCK_COUNT: usize = 8;
pub const BLOCK_POINTER_NONE: u32 = std.math.maxInt(u32);
pub const POINTERS_PER_INDIRECT_BLOCK: usize = BLOCK_SIZE / @sizeOf(u32);

pub const INODES_PER_SECTOR: usize = BLOCK_SIZE / @sizeOf(DiskInode);
pub const DIR_ENTRIES_PER_SECTOR: usize = BLOCK_SIZE / @sizeOf(DirectoryEntry);
pub const MIN_INODE_COUNT: usize = DIRECTORY_ENTRY_COUNT + 1;
pub const ROOT_DIRECTORY_BYTES: usize = DIRECTORY_ENTRY_COUNT * @sizeOf(DirectoryEntry);
pub const ROOT_DIRECTORY_SECTORS: u32 = sectorsForBytes(ROOT_DIRECTORY_BYTES); // = 4

pub const DiskInode = extern struct {
    kind: InodeKind = InodeKind.Free,
    reserved0: u8 = 0,
    link_count: u16 = 0,
    size_bytes: u32 = 0,
    direct_blocks: [DIRECT_BLOCK_COUNT]u32 = @splat(BLOCK_POINTER_NONE),
    indirect_block: u32 = BLOCK_POINTER_NONE,
    double_indirect_block: u32 = BLOCK_POINTER_NONE,
    reserved: [14]u8 = @splat(0),
    device: abi.Device = .{}, // for character and block devices, otherwise {0, 0}
};

const InodeCacheContext = struct {
    pub fn hash(_: *const InodeCacheContext, key: InodeT) u64 {
        return @intCast(key); // TODO: mix
    }
    pub fn eql(_: *const InodeCacheContext, a: InodeT, b: InodeT) bool {
        return a == b;
    }
};

const InodeCache = struct {
    pub const InodeCacheEntry = struct {
        inode_index: InodeT,
        ref_count: u16,
        inode: DiskInode,
    };

    hashmap: std.HashMapUnmanaged(InodeT, InodeCacheEntry, InodeCacheContext, 99) = .empty,
    allocator: std.mem.Allocator = undefined,

    fn init(self: *InodeCache, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
    }

    fn deinit(self: *InodeCache) void {
        self.hashmap.deinit(self.allocator);
    }

    fn get(self: *InodeCache, fs: *const FileSystem, inode_index: InodeT) FsError!*DiskInode {
        const in_hash = self.hashmap.getPtr(inode_index);
        if (in_hash) |entry| {
            entry.ref_count += 1;
            return &entry.inode;
        } else {
            try self.hashmap.put(self.allocator, inode_index, undefined);
            // TODO: it's inefficient to do this in two steps, but the API doesn't seem to provide a way to get a mutable reference on insert
            const ptr = self.hashmap.getPtr(inode_index) orelse @panic("key not found");

            ptr.inode = try fs.readInode(inode_index);
            try fs.validateInode(&ptr.inode);
            ptr.inode_index = inode_index;
            ptr.ref_count = 1;
            return &ptr.inode;
        }
    }

    fn getEntryForInode(inode: *DiskInode) *InodeCacheEntry {
        return @fieldParentPtr("inode", inode);
    }

    fn check(self: *InodeCache, inode_index: InodeT) ?*DiskInode {
        const entry = self.hashmap.getPtr(inode_index);
        if (entry) |e| {
            return &e.inode;
        } else {
            return null;
        }
    }

    fn flush(self: *InodeCache, fs: *const FileSystem, inode: *DiskInode) FsError!void {
        _ = self;
        const entry = InodeCache.getEntryForInode(inode);
        try fs.writeInode(entry.inode_index, inode);
    }

    fn drop(self: *InodeCache, inode_index: InodeT) void {
        const entry = self.hashmap.getPtr(inode_index);
        if (entry) |e| {
            e.ref_count -= 1;
            // TODO: eviction heuristics; for now keep
            //if (e.ref_count == 0) {
            //    _ = self.hashmap.remove(inode_index);
            //}
        } else {
            @panic("inode cache drop of non-existent entry");
        }
    }

    fn dropPtr(self: *InodeCache, inode: *DiskInode) void {
        const entry = InodeCache.getEntryForInode(inode);
        self.drop(entry.inode_index);
    }
};

pub const DirectoryEntry = extern struct {
    inode_index: InodeT = 0,
    kind: InodeKind = InodeKind.Free,
    name_len: u8 = 0,
    name: [FILENAME_MAX_LEN]u8 = @splat(0),
    reserved: [12]u8 = @splat(0),

    /// Create a DirectoryEntry. Assume the name has already been validated and fits within FILENAME_MAX_LEN.
    fn init(name: []const u8, inode_index: InodeT, kind: InodeKind) DirectoryEntry {
        var entry: DirectoryEntry = .{
            .inode_index = inode_index,
            .kind = kind,
            .name_len = @intCast(name.len),
        };
        @memcpy(entry.name[0..name.len], name);
        return entry;
    }
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

pub const STAT_FLAG_READABLE = abi.STAT_FLAG_READABLE;
pub const STAT_FLAG_WRITABLE = abi.STAT_FLAG_WRITABLE;
pub const STAT_FLAG_APPEND = abi.STAT_FLAG_APPEND;
pub const STAT_FLAG_SYNTHETIC = abi.STAT_FLAG_SYNTHETIC;
pub const Stat = abi.Stat;

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
    return @intCast(sectorsForBytes(@as(usize, inode_count) * @sizeOf(DiskInode)));
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
        std.debug.assert(@sizeOf(DiskInode) == 64);
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
    InvalidSuperblock,
    Corrupt,
    NoDevice,
    DirectoryFull,
    FileExists,
    FileNotFound,
    NotAFile,
    NotADirectory,
    DirNotEmpty,
    InvalidName,
    FileInUse,
    NoSpace,
    InvalidFlags,
    InvalidSeek,
    SystemFileTableFull,
    OutOfMemory,
    AccessDenied,
} || block_device.BlockError;

pub const ReadFileError = FsError || error{OutOfMemory};

const MAX_FILE_BLOCK_COUNT: usize = DIRECT_BLOCK_COUNT + POINTERS_PER_INDIRECT_BLOCK + POINTERS_PER_INDIRECT_BLOCK * POINTERS_PER_INDIRECT_BLOCK;

pub const FileSystem = struct {
    block_dev: *BlockDevice,
    superblock: Superblock = undefined,
    inode_cache: InodeCache = .{},

    /// Formats the filesystem on the given block device, preparing it for use.
    pub fn format(bd: *BlockDevice) FsError!void {
        var fs = FileSystem{
            .block_dev = bd,
        };
        try fs.formatFs();
    }

    /// Mounts an existing inode-based filesystem.
    pub fn mount(bd: *BlockDevice, allocator: std.mem.Allocator) FsError!FileSystem {
        var fs = FileSystem{
            .block_dev = bd,
        };
        try fs.readSuperblock();
        try fs.validateRootDirectory();
        try fs.inode_cache.init(allocator);
        return fs;
    }

    pub fn initCache(self: *FileSystem) error{OutOfMemory}!void {
        try self.inode_cache.hashmap.ensureTotalCapacity(self.inode_cache.allocator, 128);
    }

    pub fn unmount(self: *FileSystem) void {
        self.inode_cache.deinit();
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
    pub fn formatFs(self: *FileSystem) FsError!void {
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

        var root_inode: DiskInode = .{};
        root_inode.kind = InodeKind.Directory;
        root_inode.link_count = 1;
        root_inode.size_bytes = @intCast(ROOT_DIRECTORY_BYTES);
        for (root_blocks, 0..) |block_index, index| {
            root_inode.direct_blocks[index] = block_index;
        }
        try self.writeInode(ROOT_INODE_INDEX, &root_inode);
        try self.writeSuperblock();
    }

    /// Returns stat-like metadata for the inode-backed object at `inode_index`.
    pub fn statInode(self: *FileSystem, inode: *DiskInode) FsError!Stat {
        return .{
            .inode = InodeCache.getEntryForInode(inode).inode_index,
            .size = inode.size_bytes,
            .blocks = fileBlocksForSize(inode.size_bytes),
            .blksize = BLOCK_SIZE,
            .nlink = inode.link_count,
            .kind = inode.kind,
            .flags = 0,
            .on_device = self.block_dev.device,
            .device = inode.device,
        };
    }

    pub fn isInodeOpen(self: *FileSystem, inode_index: InodeT) bool {
        if (self.inode_cache.check(inode_index)) |inode| {
            return InodeCache.getEntryForInode(inode).ref_count > 0;
        }
        return false;
    }

    pub fn getRootInode(self: *FileSystem) *DiskInode {
        // TODO: root inode should always be kept in the cache
        // TODO: This should not increase the refcount
        return self.inode_cache.get(self, ROOT_INODE_INDEX) catch @panic("root inode inaccessible");
    }

    pub fn getInode(self: *FileSystem, inode_index: InodeT) FsError!*DiskInode {
        return self.inode_cache.get(self, inode_index);
    }

    pub fn drop(self: *FileSystem, inode: *DiskInode) void {
        self.inode_cache.dropPtr(inode);
    }

    pub fn dup(_: *FileSystem, inode: *DiskInode) *DiskInode {
        const entry = InodeCache.getEntryForInode(inode);
        entry.ref_count += 1;
        return inode;
    }

    pub fn getInodeIndex(_: *FileSystem, inode: *DiskInode) InodeT {
        return InodeCache.getEntryForInode(inode).inode_index;
    }

    /// Returns stat-like metadata for the object referenced by `path`.
    pub fn statPath(self: *FileSystem, path: []const u8) FsError!Stat {
        const inode = try self.getInodeAtPath(path);
        defer self.drop(inode);
        return self.statInode(inode);
    }

    fn createFileInternal(self: *FileSystem, dir_inode: *DiskInode, name: []const u8, kind: InodeKind, size: u32, device: abi.Device) FsError!*DiskInode {
        if (!validateName(name)) return error.InvalidName;
        if ((try self.findDirEntry(dir_inode, name)) != null) return error.FileExists;

        const entry_index = try self.findReusableEntryIndex(dir_inode);
        const new_inode = try self.findFreeInodeIndex();

        const num_blocks = fileBlocksForSize(size);

        new_inode.* = .{};
        new_inode.kind = kind;
        new_inode.size_bytes = size;
        new_inode.link_count = 1;
        new_inode.device = device;
        if (size > 0)
            try self.allocBlockTree(new_inode, num_blocks);
        try self.inode_cache.flush(self, new_inode);

        // Zero out any data blocks allocated to the file
        if (size > 0) {
            for (0..num_blocks) |logical_block| {
                const data_block = try self.getInodeDataBlock(new_inode, @intCast(logical_block));
                try self.zeroBlock(data_block);
            }
        }

        try self.writeDirEntry(dir_inode, entry_index, &DirectoryEntry.init(
            name,
            self.getInodeIndex(new_inode),
            kind,
        ));

        self.superblock.file_count += 1;
        try self.writeSuperblock();
        return new_inode;
    }

    /// Creates a new empty regular file in the given directory and returns its inode index.
    pub fn createFile(self: *FileSystem, dir_inode: *DiskInode, name: []const u8) FsError!*DiskInode {
        return self.createFileInternal(dir_inode, name, InodeKind.Regular, 0, .{});
    }

    /// Creates a new hard link to an existing non-directory inode in the given directory.
    pub fn createLink(self: *FileSystem, dir_inode: *DiskInode, name: []const u8, target_inode: *DiskInode) FsError!void {
        if (!validateName(name)) return error.InvalidName;
        if ((try self.findDirEntry(dir_inode, name)) != null) return error.FileExists;

        switch (target_inode.kind) {
            .Regular, .CharDevice, .BlockDevice => {},
            else => return error.NotAFile,
        }

        const entry_index = try self.findReusableEntryIndex(dir_inode);
        try self.linkInode(target_inode);
        errdefer self.unlinkInode(target_inode) catch unreachable;

        try self.writeDirEntry(dir_inode, entry_index, &DirectoryEntry.init(
            name,
            InodeCache.getEntryForInode(target_inode).inode_index,
            target_inode.kind,
        ));

        self.superblock.file_count += 1;
        try self.writeSuperblock();
    }

    /// Creates a new directory with the given full path and returns its inode index.
    pub fn createDirectory(self: *FileSystem, path: []const u8) FsError!*DiskInode {
        const split = splitPath(path);
        const dir_inode = try self.getInodeAtPath(split.dir);
        defer self.drop(dir_inode);
        return self.createDirectoryAt(dir_inode, split.name);
    }

    /// Creates a new empty directory in the given directory and returns its inode index.
    pub fn createDirectoryAt(self: *FileSystem, dir_inode: *DiskInode, name: []const u8) FsError!*DiskInode {
        return self.createFileInternal(dir_inode, name, InodeKind.Directory, ROOT_DIRECTORY_BYTES, .{});
    }

    /// Creates a new special file (character or block device) in the given directory and returns its inode index.
    pub fn createSpecialFile(self: *FileSystem, dir_inode: *DiskInode, name: []const u8, kind: InodeKind, device: abi.Device) FsError!*DiskInode {
        return self.createFileInternal(dir_inode, name, kind, 0, device);
    }

    /// Resizes a file identified directly by inode number, zero-filling any newly exposed range.
    pub fn resizeInode(self: *FileSystem, inode_index: InodeT, new_size: u32) FsError!void {
        const inode = try self.getFileInode(inode_index);
        defer self.inode_cache.drop(inode_index);
        try self.resizeInodeToSize(inode, new_size);
    }

    /// Truncates a file identified directly by inode number to zero bytes.
    pub fn truncateInode(self: *FileSystem, inode_index: InodeT) FsError!void {
        try self.resizeInode(inode_index, 0);
    }

    //////////// FILE READING ////////////

    /// Reads an entire regular file, given by its full path, into allocator-owned memory.
    pub fn getFileContents(self: *FileSystem, allocator: std.mem.Allocator, path: []const u8) ReadFileError![]u8 {
        const inode = try self.getInodeAtPath(path);
        defer self.drop(inode);
        return self.readInodeContents(allocator, inode);
    }

    pub fn readInodeContents(self: *const FileSystem, allocator: std.mem.Allocator, inode: *const DiskInode) ReadFileError![]u8 {
        if (inode.size_bytes == 0) {
            return allocator.alloc(u8, 0);
        }

        const data = try allocator.alloc(u8, @intCast(inode.size_bytes));
        errdefer allocator.free(data);
        _ = try self.readInodeAt(inode, 0, data);
        return data;
    }

    /// Reads bytes from a file identified directly by inode number.
    pub fn readInodeAt(self: *const FileSystem, inode: *const DiskInode, offset: u32, dest: []u8) FsError!usize {
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

    pub fn getInodeAtPath(self: *FileSystem, path: []const u8) FsError!*DiskInode {
        const inode_index = try self.walkPathToInodeIndex(self.getRootInode(), path);
        return self.inode_cache.get(self, inode_index);
    }

    /// Creates or overwrites a file with the given path with the provided full contents.
    pub fn writeFileContents(self: *FileSystem, path: []const u8, data: []const u8) FsError!void {
        const split = splitPath(path);
        const dir_inode = try self.getInodeAtPath(split.dir);
        defer self.drop(dir_inode);
        try self.writeFileAt(dir_inode, split.name, data);
    }

    /// Creates or overwrites a file in the given directory with the provided full contents.
    pub fn writeFileAt(self: *FileSystem, dir_inode: *DiskInode, name: []const u8, data: []const u8) FsError!void {
        if (!validateName(name)) return error.InvalidName;
        if (fileBlocksForSize(@intCast(data.len)) > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        const inode = try self.findDirEntryInode(dir_inode, name) orelse
            try self.createFile(dir_inode, name);
        defer self.drop(inode);
        if (inode.kind != .Regular) return error.NotAFile;
        try self.writeToInodeAtOffset(inode, 0, data, true);
    }

    /// Writes bytes to a file identified directly by inode number, growing as needed.
    pub fn writeInodeAt(self: *FileSystem, inode: *DiskInode, offset: u32, data: []const u8) FsError!usize {
        if (data.len == 0) return 0;
        try self.writeToInodeAtOffset(inode, offset, data, false);
        return data.len;
    }

    //////////// PATH WALKING ////////////

    /// Walk a full file path, starting from the given directory inode index.
    /// Returns { parent_dir_inode_index, dir_entry_index, dir_entry } or error.FileNotFound.
    pub fn walkPathToDirEntry(self: *FileSystem, dir_inode: *DiskInode, path: []const u8) FsError!struct { *DiskInode, u32, DirectoryEntry } {
        var current_dir = dir_inode;
        if (current_dir.kind != .Directory) return error.NotADirectory;

        var path_iter = std.mem.splitScalar(u8, path, '/');

        // TODO: check the logic here - can we leak opened inodes in the cache?

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

            const new_dir = try self.getDirectoryInode(entry.inode_index);

            if (current_dir != dir_inode) {
                // If it is an inode we opened during walking, drop it
                self.drop(current_dir);
            }
            current_dir = new_dir;
        }
        // TODO: this is reachable if the path is empty or "/"
        unreachable;
    }

    /// Walk a full file path, starting from the given directory inode index.
    /// Returns the final file's inode index or error.FileNotFound.
    pub fn walkPathToInodeIndex(self: *FileSystem, dir_inode: *DiskInode, path: []const u8) FsError!InodeT {
        if (path.len == 0) return InodeCache.getEntryForInode(dir_inode).inode_index;
        if (path.len == 1 and path[0] == '/') return ROOT_INODE_INDEX;
        const parent_inode, _, const entry = try self.walkPathToDirEntry(dir_inode, path);
        self.drop(parent_inode);
        return entry.inode_index;
    }

    /// Returns true if a file or directory exists at the given path, false if not found.
    pub fn pathExists(self: *FileSystem, path: []const u8) FsError!bool {
        _ = self.walkPathToInodeIndex(self.getRootInode(), path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Increments the link count of a non-directory inode.
    fn linkInode(self: *FileSystem, inode: *DiskInode) FsError!void {
        if (inode.link_count == 0) return error.Corrupt;
        switch (inode.kind) {
            .Regular, .CharDevice, .BlockDevice => {},
            else => return error.NotAFile,
        }
        if (inode.link_count == std.math.maxInt(u16)) return error.Corrupt;

        inode.link_count += 1;
        try self.inode_cache.flush(self, inode);
    }

    /// Decrements the link count of an inode, destroying it if the count reached zero.
    fn unlinkInode(self: *FileSystem, inode: *DiskInode) FsError!void {
        if (inode.link_count == 0)
            return error.Corrupt;
        if (self.superblock.file_count == 0) return error.Corrupt;

        inode.link_count -= 1;

        if (inode.link_count == 0) {
            try self.destroyInode(inode);
        }
        try self.inode_cache.flush(self, inode);

        self.superblock.file_count -= 1;
        try self.writeSuperblock();
    }

    /// Deletes a directory entry (which is itself not a directory) from the given directory and unlinks its inode.
    pub fn deleteFile(self: *FileSystem, dir_inode: *DiskInode, index: u32) FsError!void {
        const entry = try self.readDirEntry(dir_inode, index);

        switch (entry.kind) {
            .Regular, .CharDevice, .BlockDevice => {},
            else => return error.NotAFile,
        }

        const inode = try self.getDirectoryInode(entry.inode_index);
        defer self.drop(inode);

        var cleared: DirectoryEntry = .{};
        try self.writeDirEntry(dir_inode, index, &cleared);

        try unlinkInode(self, inode);
    }

    /// Deletes an empty directory from the given directory and frees its inode and blocks.
    pub fn deleteDirectory(self: *FileSystem, dir_inode: *DiskInode, index: u32) FsError!void {
        const entry = try self.readDirEntry(dir_inode, index);

        if (entry.kind != .Directory) return error.NotADirectory;

        const inode = try self.getDirectoryInode(entry.inode_index);
        defer self.drop(inode);

        if (!try self.isDirectoryEmpty(inode)) return error.DirNotEmpty;

        var cleared: DirectoryEntry = .{};
        try self.writeDirEntry(dir_inode, index, &cleared);

        try unlinkInode(self, inode);
    }

    fn isDirectoryEmpty(self: *FileSystem, dir_inode: *DiskInode) FsError!bool {
        var i: usize = 0;
        while (i < DIRECTORY_ENTRY_COUNT) : (i += 1) {
            const entry = try self.readDirEntry(dir_inode, i);
            if (entry.kind != .Free) {
                // TODO: once we support . and .., we should allow them.
                return false;
            }
        }
        return true;
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

    fn writeSuperblock(self: *FileSystem) FsError!void {
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
                .Regular, .Directory, .CharDevice, .BlockDevice => {
                    const inode = try self.readInode(entry.inode_index);
                    try self.validateInode(&inode);
                    if (inode.kind != entry.kind) return error.Corrupt;
                },
                else => return error.Corrupt,
            }
        }
    }

    /// Looks up a named entry in the given directory; returns its slot index and the entry itself.
    pub fn findDirEntryAndIndex(self: *const FileSystem, dir_inode: *DiskInode, name: []const u8) FsError!?struct { u32, DirectoryEntry } {
        if (!validateName(name)) return error.InvalidName;

        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(dir_inode, index);
            if (entry.kind == InodeKind.Free) continue;
            if (entry.name_len != @as(u8, @intCast(name.len))) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return .{ @intCast(index), entry };
            }
        }

        return null;
    }

    /// Looks up a named entry in the given directory.
    fn findDirEntry(self: *const FileSystem, dir_inode: *DiskInode, name: []const u8) FsError!?DirectoryEntry {
        if (try self.findDirEntryAndIndex(dir_inode, name)) |result| {
            return result.@"1";
        } else {
            return null;
        }
    }

    pub fn findDirEntryInode(self: *FileSystem, dir_inode: *DiskInode, name: []const u8) FsError!?*DiskInode {
        if (try self.findDirEntry(dir_inode, name)) |entry| {
            return self.inode_cache.get(self, entry.inode_index);
        } else {
            return null;
        }
    }

    /// Find a free directory entry within the given directory.
    fn findReusableEntryIndex(self: *FileSystem, dir_inode: *DiskInode) FsError!usize {
        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirEntry(dir_inode, index);
            if (entry.kind == .Free) return index;
        }
        return error.DirectoryFull;
    }

    /// Find a free inode index within the inode table.
    fn findFreeInodeIndex(self: *FileSystem) FsError!*DiskInode {
        var inode_index: InodeT = ROOT_INODE_INDEX + 1;
        while (inode_index < self.superblock.inode_count) : (inode_index += 1) {
            // first check the cache to avoid unnecessary disk reads
            if (self.inode_cache.check(inode_index)) |inode| {
                if (InodeCache.getEntryForInode(inode).ref_count > 0) {
                    continue;
                }
            }
            const inode = try self.inode_cache.get(self, inode_index);
            if (inode.kind == .Free) return inode;
            self.drop(inode);
        }
        return error.NoSpace;
    }

    /// Read the inode with the given index and verify that it is a valid file inode.
    pub fn readFileInode(self: *const FileSystem, inode_index: InodeT) FsError!DiskInode {
        const inode = try self.readInode(inode_index);
        try self.validateInode(&inode);
        if (inode.kind != .Regular) return error.NotAFile;
        return inode;
    }

    fn getFileInode(self: *FileSystem, inode_index: InodeT) FsError!*DiskInode {
        const inode = try self.inode_cache.get(self, inode_index);
        errdefer self.inode_cache.drop(inode_index);

        switch (inode.kind) {
            .Regular, .CharDevice, .BlockDevice => return inode,
            else => return error.NotAFile,
        }
    }

    /// Read the inode with the given index and verify that it is a valid directory inode.
    fn readDirectoryInode(self: *const FileSystem, inode_index: InodeT) FsError!DiskInode {
        const inode = try self.readInode(inode_index);
        try self.validateInode(&inode);
        if (inode.kind != .Directory) return error.NotADirectory;
        return inode;
    }

    fn getDirectoryInode(self: *FileSystem, inode_index: InodeT) FsError!*DiskInode {
        const inode = try self.inode_cache.get(self, inode_index);
        errdefer self.inode_cache.drop(inode_index);

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
    fn allocBlockTree(self: *FileSystem, inode: *DiskInode, num_wanted_blocks: u32) !void {
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
    pub fn writeToInodeAtOffset(
        self: *FileSystem,
        inode: *DiskInode,
        ofs: u32,
        data: []const u8,
        truncate: bool,
    ) FsError!void {
        const old_size = inode.size_bytes;
        const data_end: u32 = std.math.add(u32, ofs, @intCast(data.len)) catch return error.NoSpace;
        const new_size: u32 = if (truncate)
            data_end // if truncating, the file will end after the given data
        else
            @max(inode.size_bytes, data_end); // otherwise, keep any existing data after the write window
        // NB: new_size >= data_end = ofs + data.len

        const old_total_blocks = fileBlocksForSize(old_size);
        if (new_size > old_size) {
            try self.resizeInodeToSize(inode, new_size);
        }

        const first_block = ofs / BLOCK_SIZE;
        var sector = [_]u8{0} ** BLOCK_SIZE;

        // Fill the allocated blocks with the new data
        var block_idx = first_block; // block currently being written
        var block_cursor: u32 = ofs % BLOCK_SIZE; // offset within current block (only relevant for first block)
        var data_cursor: usize = 0; // current offset within data slice

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

        if (truncate and new_size < old_size) {
            try self.resizeInodeToSize(inode, new_size);
        }
    }

    /// Change the size of an inode, allocating or freeing blocks as needed.
    /// If the inode is being grown, any newly exposed regions will be zero-filled.
    pub fn resizeInodeToSize(self: *FileSystem, inode: *DiskInode, new_size: u32) FsError!void {
        const old_size = inode.size_bytes;
        if (new_size == old_size) return;

        const new_total_blocks = fileBlocksForSize(new_size);
        if (new_total_blocks > @as(u32, @intCast(MAX_FILE_BLOCK_COUNT))) return error.NoSpace;

        if (new_size > old_size) {
            // grow: allocate new blocks, then zero out the newly exposed range
            try self.allocBlockTree(inode, new_total_blocks);
            try self.zeroInodeRange(inode, old_size, new_size - old_size);
        } else {
            // shrink: zero out the tail of the new final block
            const partial_block_bytes = new_size % BLOCK_SIZE;
            if (partial_block_bytes != 0) {
                const bytes_to_clear: u32 = @min(old_size - new_size, BLOCK_SIZE - partial_block_bytes);
                try self.zeroInodeRange(inode, new_size, bytes_to_clear);
            }
            try self.allocBlockTree(inode, new_total_blocks);
        }

        inode.size_bytes = new_size;
        try self.inode_cache.flush(self, inode);
    }

    /// Zero out a byte range within an inode.
    fn zeroInodeRange(self: *FileSystem, inode: *DiskInode, start: u32, len: u32) FsError!void {
        if (len == 0) return;

        var remaining = len;
        var block_idx: u32 = start / BLOCK_SIZE;
        var block_offset: usize = @intCast(start % BLOCK_SIZE);
        var sector = [_]u8{0} ** BLOCK_SIZE;

        while (remaining > 0) : (block_idx += 1) {
            const chunk_len: usize = @min(@as(usize, remaining), BLOCK_SIZE - block_offset);
            const data_block = try self.getInodeDataBlock(inode, block_idx);

            if (chunk_len != BLOCK_SIZE) {
                try self.readDataBlock(data_block, &sector);
            } else {
                @memset(&sector, 0);
            }

            @memset(sector[block_offset .. block_offset + chunk_len], 0);
            try self.writeDataBlock(data_block, &sector);

            remaining -= @intCast(chunk_len);
            block_offset = 0;
        }
    }

    fn destroyInode(self: *FileSystem, inode: *DiskInode) FsError!void {
        try self.allocBlockTree(inode, 0);
        inode.* = .{};
    }

    fn readInode(self: *const FileSystem, inode_index: InodeT) FsError!DiskInode {
        if (inode_index >= self.superblock.inode_count) return error.Corrupt;

        const sector_lba = self.superblock.inode_table_start_lba +
            @divFloor(@as(u32, inode_index), @as(u32, @intCast(INODES_PER_SECTOR)));
        const inode_offset = (@as(usize, inode_index) % INODES_PER_SECTOR) * @sizeOf(DiskInode);

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(sector_lba, &sector);

        var inode: DiskInode = undefined;
        @memcpy(std.mem.asBytes(&inode), sector[inode_offset .. inode_offset + @sizeOf(DiskInode)]);
        return inode;
    }

    fn writeInode(self: *const FileSystem, inode_index: InodeT, inode: *const DiskInode) FsError!void {
        if (inode_index >= self.superblock.inode_count) return error.Corrupt;

        const sector_lba = self.superblock.inode_table_start_lba +
            @divFloor(@as(u32, inode_index), @as(u32, @intCast(INODES_PER_SECTOR)));
        const inode_offset = (@as(usize, inode_index) % INODES_PER_SECTOR) * @sizeOf(DiskInode);

        var sector = [_]u8{0} ** BLOCK_SIZE;
        try self.block_dev.readBlock(sector_lba, &sector);
        @memcpy(sector[inode_offset .. inode_offset + @sizeOf(DiskInode)], std.mem.asBytes(inode));
        try self.block_dev.writeBlock(sector_lba, &sector);
    }

    fn validateInode(self: *const FileSystem, inode: *const DiskInode) FsError!void {
        switch (inode.kind) {
            .Free => {
                if (inode.size_bytes != 0 or inode.link_count != 0) return error.Corrupt;
                return;
            },
            .Regular, .Directory => {
                if (!inode.device.isEmpty()) return error.Corrupt;
            },
            .CharDevice, .BlockDevice => {
                if (inode.link_count == 0 or inode.size_bytes != 0) return error.Corrupt;
                for (inode.direct_blocks) |block_index| {
                    if (block_index != BLOCK_POINTER_NONE) return error.Corrupt;
                }
                if (inode.indirect_block != BLOCK_POINTER_NONE) return error.Corrupt;
                if (inode.double_indirect_block != BLOCK_POINTER_NONE) return error.Corrupt;
                return;
            },
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
    fn collectInodeDataBlocks(self: *const FileSystem, inode: *const DiskInode, dest: []u32) FsError!void {
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
    fn getInodeDataBlock(self: *const FileSystem, inode: *const DiskInode, logical_block: u32) FsError!u32 {
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

    /// Read a directory entry from a directory inode by index.
    pub fn readDirEntry(self: *const FileSystem, dir_inode: *const DiskInode, index: usize) FsError!DirectoryEntry {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.Corrupt;
        if (dir_inode.kind != .Directory) return error.NotADirectory;

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
    fn writeDirEntry(self: *FileSystem, dir_inode: *DiskInode, index: usize, entry: *const DirectoryEntry) FsError!void {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.Corrupt;
        try validateDirectoryEntry(entry, self.superblock.inode_count);
        if (dir_inode.kind != .Directory) return error.NotADirectory;

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
        .Regular, .Directory, .CharDevice, .BlockDevice => {},
        else => return error.Corrupt,
    }

    if (entry.inode_index >= inode_count) return error.Corrupt;
    if (entry.name_len == 0 or entry.name_len > FILENAME_MAX_LEN) return error.Corrupt;
    if (!validateName(entry.name[0..entry.name_len])) return error.Corrupt;
}

/// Split a file path into directory and filename components.
/// Should live in vfs, but remains here for now for compile_fs.zig.
pub fn splitPath(path: []const u8) struct { dir: []const u8, name: []const u8 } {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    if (last_slash) |idx| {
        return .{ .dir = trimmed[0..idx], .name = trimmed[idx + 1 ..] };
    } else {
        return .{ .dir = &.{}, .name = trimmed };
    }
}
