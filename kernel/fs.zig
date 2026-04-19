const ide = @import("ide.zig");
const fs_defs = @import("fs_defs.zig");
const std = @import("std");

pub const FILENAME_MAX_LEN = fs_defs.FILENAME_MAX_LEN;
pub const DIRECTORY_ENTRY_COUNT = fs_defs.DIRECTORY_ENTRY_COUNT;
pub const STAGE2_RESERVED_SECTORS = fs_defs.STAGE2_RESERVED_SECTORS;
pub const FS_START_LBA = fs_defs.FS_START_LBA;
pub const SUPERBLOCK_SECTORS = fs_defs.SUPERBLOCK_SECTORS;
pub const DIRECTORY_SECTORS = fs_defs.DIRECTORY_SECTORS;
pub const DATA_START_LBA = fs_defs.DATA_START_LBA;
pub const ENTRY_STATE_FREE = fs_defs.ENTRY_STATE_FREE;
pub const ENTRY_STATE_FILE = fs_defs.ENTRY_STATE_FILE;
pub const ENTRY_STATE_RESERVED = fs_defs.ENTRY_STATE_RESERVED;
pub const ENTRY_STATE_DELETED = fs_defs.ENTRY_STATE_DELETED;
pub const Superblock = fs_defs.Superblock;
pub const DirectoryEntry = fs_defs.DirectoryEntry;
pub const FileInfo = fs_defs.FileInfo;
pub const isValidSuperblock = fs_defs.isValidSuperblock;
pub const sectorsForBytes = fs_defs.sectorsForBytes;
pub const validateName = fs_defs.validateName;

pub const FsError = error{
    Corrupt,
    DirectoryFull,
    FileExists,
    FileNotFound,
    InvalidName,
    InvalidSuperblock,
    NoSpace,
} || ide.IdeError;

pub const ReadFileError = FsError || error{OutOfMemory};
pub const WriteFileError = FsError || error{OutOfMemory};

pub const FileSystem = struct {
    drive: ide.Drive,
    superblock: Superblock,

    /// Mounts the filesystem, formatting a fresh one if the superblock is missing.
    pub fn mountOrFormat(drive: ide.Drive) FsError!FileSystem {
        var fs = FileSystem{
            .drive = drive,
            .superblock = undefined,
        };

        fs.readSuperblock() catch |err| switch (err) {
            error.InvalidSuperblock => {
                try fs.format();
                return fs;
            },
            else => return err,
        };

        return fs;
    }

    /// Formats the fixed filesystem region and initializes the reserved directory slot.
    pub fn format(self: *FileSystem) FsError!void {
        const drive_info = try ide.identifyDrive(self.drive);
        const fs_sector_count: u32 = drive_info.max_lba28 - FS_START_LBA;

        self.superblock = makeDefaultSuperblock(fs_sector_count);

        var zero_sector = [_]u8{0} ** 512;
        var sector_lba: u32 = FS_START_LBA;
        while (sector_lba < DATA_START_LBA) : (sector_lba += 1) {
            try ide.writeSectorLba28(self.drive, sector_lba, &zero_sector);
        }

        var reserved_entry = zeroEntry();
        reserved_entry.state = ENTRY_STATE_RESERVED;
        try self.writeDirectoryEntry(0, &reserved_entry);
        try self.writeSuperblock();
    }

    /// Returns the number of visible user files.
    pub fn fileCount(self: *const FileSystem) u32 {
        return self.superblock.file_count;
    }

    /// Returns metadata for a directory slot when it contains a normal file.
    pub fn getFileInfo(self: *const FileSystem, index: usize) FsError!?FileInfo {
        if (index >= DIRECTORY_ENTRY_COUNT) return null;

        const entry = try self.readDirectoryEntry(index);
        if (entry.state != ENTRY_STATE_FILE) return null;

        return FileInfo{
            .index = index,
            .name = entry.name,
            .name_len = @intCast(entry.name_len),
            .size_bytes = entry.size_bytes,
            .sector_count = entry.sector_count,
        };
    }

    /// Looks up the directory slot for a named file.
    pub fn getFileIndex(self: *const FileSystem, name: []const u8) FsError!?usize {
        return self.findFileIndex(name);
    }

    /// Creates a new empty file and returns its directory slot.
    pub fn createFile(self: *FileSystem, name: []const u8) FsError!usize {
        if (!validateName(name)) return error.InvalidName;
        if ((try self.findFileIndex(name)) != null) return error.FileExists;

        const target_index = try self.findReusableEntryIndex();
        var entry = zeroEntry();
        entry.state = ENTRY_STATE_FILE;
        entry.name_len = @intCast(name.len);
        @memcpy(entry.name[0..name.len], name);
        try self.writeDirectoryEntry(target_index, &entry);

        self.superblock.file_count += 1;
        self.superblock.next_free_lba = try self.computeNextFreeLba();
        try self.writeSuperblock();
        return target_index;
    }

    /// Returns the current size in bytes for a file identified by directory slot.
    pub fn getFileSize(self: *const FileSystem, index: usize) FsError!u32 {
        const entry = try self.readLiveFileEntry(index);
        return entry.size_bytes;
    }

    /// Reads a byte range from an already-opened file entry.
    pub fn readFileAt(self: *const FileSystem, index: usize, offset: u32, dest: []u8) FsError!usize {
        if (dest.len == 0) return 0;

        const entry = try self.readLiveFileEntry(index);
        if (offset >= entry.size_bytes) return 0;
        try validateDataExtent(&entry);

        const available: usize = @intCast(entry.size_bytes - offset);
        var remaining: usize = @min(dest.len, available);
        var lba = entry.start_lba + offset / 512;
        var sector_offset: usize = @intCast(offset % 512);
        var out_offset: usize = 0;
        var sector = [_]u8{0} ** 512;

        while (remaining > 0) : (lba += 1) {
            try ide.readSectorLba28(self.drive, lba, &sector);
            const chunk_len: usize = @min(remaining, sector.len - sector_offset);
            @memcpy(dest[out_offset .. out_offset + chunk_len], sector[sector_offset .. sector_offset + chunk_len]);
            remaining -= chunk_len;
            out_offset += chunk_len;
            sector_offset = 0;
        }

        return out_offset;
    }

    /// Writes a byte range to an already-opened file entry, growing the file as needed.
    pub fn writeFileAt(self: *FileSystem, allocator: std.mem.Allocator, index: usize, offset: u32, data: []const u8) WriteFileError!usize {
        if (data.len == 0) return 0;

        const entry = try self.readLiveFileEntry(index);
        try validateDataExtent(&entry);

        const data_len_u32: u32 = @intCast(data.len);
        const required_size = std.math.add(u32, offset, data_len_u32) catch return error.NoSpace;
        const new_size = @max(entry.size_bytes, required_size);

        const merged = try allocator.alloc(u8, new_size);
        defer allocator.free(merged);

        @memset(merged, 0);
        if (entry.size_bytes > 0) {
            _ = try self.readFileAt(index, 0, merged[0..entry.size_bytes]);
        }
        @memcpy(merged[offset..required_size], data);

        try self.replaceEntryContents(index, &entry, merged);
        return data.len;
    }

    /// Truncates a file to zero length while preserving its directory slot and name.
    pub fn truncateFile(self: *FileSystem, index: usize) FsError!void {
        var entry = try self.readLiveFileEntry(index);
        entry.start_lba = 0;
        entry.sector_count = 0;
        entry.size_bytes = 0;
        try self.writeDirectoryEntry(index, &entry);

        self.superblock.next_free_lba = try self.computeNextFreeLba();
        try self.writeSuperblock();
    }

    /// Reads an entire file into allocator-owned memory.
    pub fn readFile(self: *const FileSystem, allocator: std.mem.Allocator, name: []const u8) ReadFileError![]u8 {
        const index = (try self.findFileIndex(name)) orelse return error.FileNotFound;
        const entry = try self.readLiveFileEntry(index);
        try validateDataExtent(&entry);
        if (entry.size_bytes == 0) {
            return allocator.alloc(u8, 0);
        }

        const data = try allocator.alloc(u8, @intCast(entry.size_bytes));
        errdefer allocator.free(data);
        _ = try self.readFileAt(index, 0, data);
        return data;
    }

    /// Creates or overwrites a file with the provided full contents.
    pub fn writeFile(self: *FileSystem, name: []const u8, data: []const u8) FsError!void {
        if (!validateName(name)) return error.InvalidName;

        const existing_index = try self.findFileIndex(name);
        const target_index = existing_index orelse try self.findReusableEntryIndex();
        var entry = if (existing_index) |index|
            try self.readLiveFileEntry(index)
        else blk: {
            var created = zeroEntry();
            created.state = ENTRY_STATE_FILE;
            created.name_len = @intCast(name.len);
            @memcpy(created.name[0..name.len], name);
            break :blk created;
        };

        try self.replaceEntryContents(target_index, &entry, data);

        if (existing_index == null) {
            self.superblock.file_count += 1;
            try self.writeSuperblock();
        }
    }

    /// Deletes a file from the directory and makes its old extent reusable.
    pub fn deleteFile(self: *FileSystem, name: []const u8) FsError!void {
        const index = (try self.findFileIndex(name)) orelse return error.FileNotFound;
        var entry = try self.readDirectoryEntry(index);
        markEntryDeleted(&entry);
        try self.writeDirectoryEntry(index, &entry);

        self.superblock.file_count -= 1;
        self.superblock.next_free_lba = try self.computeNextFreeLba();
        try self.writeSuperblock();
    }

    /// Renames a file while preserving its existing data extent.
    pub fn renameFile(self: *FileSystem, old_name: []const u8, new_name: []const u8) FsError!void {
        if (!validateName(new_name)) return error.InvalidName;
        const index = (try self.findFileIndex(old_name)) orelse return error.FileNotFound;
        if ((try self.findFileIndex(new_name)) != null) return error.FileExists;

        var entry = try self.readDirectoryEntry(index);
        entry.name_len = @intCast(new_name.len);
        entry.name = [_]u8{0} ** FILENAME_MAX_LEN;
        @memcpy(entry.name[0..new_name.len], new_name);
        try self.writeDirectoryEntry(index, &entry);
    }

    fn readSuperblock(self: *FileSystem) FsError!void {
        var sector = [_]u8{0} ** 512;
        try ide.readSectorLba28(self.drive, FS_START_LBA, &sector);

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
        try ide.writeSectorLba28(self.drive, FS_START_LBA, &sector);
    }

    fn findFileEntry(self: *const FileSystem, name: []const u8) FsError!DirectoryEntry {
        const index = (try self.findFileIndex(name)) orelse return error.FileNotFound;
        return self.readLiveFileEntry(index);
    }

    fn findFileIndex(self: *const FileSystem, name: []const u8) FsError!?usize {
        if (!validateName(name)) return error.InvalidName;

        var index: usize = 1;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirectoryEntry(index);
            if (entry.state != ENTRY_STATE_FILE) continue;
            if (entry.name_len != @as(u8, @intCast(name.len))) continue;
            if (std.mem.eql(u8, entry.name[0..@as(usize, entry.name_len)], name)) {
                return index;
            }
        }

        return null;
    }

    fn findReusableEntryIndex(self: *const FileSystem) FsError!usize {
        var index: usize = 1;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirectoryEntry(index);
            if (entry.state == ENTRY_STATE_FREE or entry.state == ENTRY_STATE_DELETED) {
                return index;
            }
        }

        return error.DirectoryFull;
    }

    fn readLiveFileEntry(self: *const FileSystem, index: usize) FsError!DirectoryEntry {
        if (index >= DIRECTORY_ENTRY_COUNT) return error.FileNotFound;
        const entry = try self.readDirectoryEntry(index);
        if (entry.state != ENTRY_STATE_FILE) return error.FileNotFound;
        return entry;
    }

    fn replaceEntryContents(self: *FileSystem, index: usize, existing_entry: *const DirectoryEntry, data: []const u8) FsError!void {
        var entry = existing_entry.*;
        entry.state = ENTRY_STATE_FILE;

        const sector_count = sectorsForBytes(data.len);
        const start_lba = try self.allocateExtent(sector_count, index);

        try self.writeDataExtent(start_lba, sector_count, data);

        entry.start_lba = start_lba;
        entry.sector_count = sector_count;
        entry.size_bytes = @intCast(data.len);
        try self.writeDirectoryEntry(index, &entry);

        self.superblock.next_free_lba = try self.computeNextFreeLba();
        try self.writeSuperblock();
    }

    // Find a starting LBA for a new or expanded file extent that has enough space to fit sector_count contiguous sectors.
    // exclude_index is a directory slot index to ignore when checking for free space.
    fn allocateExtent(self: *const FileSystem, sector_count: u32, exclude_index: usize) FsError!u32 {
        if (sector_count == 0) return 0;

        const limit_lba = self.superblock.fs_start_lba + self.superblock.fs_sector_count;
        var candidate = DATA_START_LBA;
        while (candidate + sector_count <= limit_lba) {
            var next_candidate: ?u32 = null;

            var index: usize = 0;
            while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
                if (index == exclude_index) continue;

                const entry = try self.readDirectoryEntry(index);
                if (!entryOccupiesData(&entry)) continue;

                const entry_end = entry.start_lba + entry.sector_count;
                if (entry.start_lba < candidate + sector_count and candidate < entry_end) {
                    next_candidate = if (next_candidate) |current|
                        @max(current, entry_end)
                    else
                        entry_end;
                }
            }

            if (next_candidate) |next| {
                candidate = next;
                continue;
            }
            return candidate;
        }

        return error.NoSpace;
    }

    fn computeNextFreeLba(self: *const FileSystem) FsError!u32 {
        var highest = DATA_START_LBA;
        var index: usize = 0;
        while (index < DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = try self.readDirectoryEntry(index);
            if (!entryOccupiesData(&entry)) continue;
            highest = @max(highest, entry.start_lba + entry.sector_count);
        }
        return highest;
    }

    fn writeDataExtent(self: *FileSystem, start_lba: u32, sector_count: u32, data: []const u8) FsError!void {
        if (sector_count == 0) return;

        var sector = [_]u8{0} ** 512;
        var offset: usize = 0;
        var sector_index: u32 = 0;

        while (sector_index < sector_count) : (sector_index += 1) {
            sector = [_]u8{0} ** 512;
            const remaining = data.len - offset;
            const chunk_len: usize = @min(remaining, sector.len);
            if (chunk_len > 0) {
                @memcpy(sector[0..chunk_len], data[offset .. offset + chunk_len]);
                offset += chunk_len;
            }
            try ide.writeSectorLba28(self.drive, start_lba + sector_index, &sector);
        }
    }

    fn readDirectoryEntry(self: *const FileSystem, index: usize) FsError!DirectoryEntry {
        const sector_lba = fs_defs.DIRECTORY_START_LBA + @as(u32, @intCast(index / fs_defs.DIR_ENTRIES_PER_SECTOR));
        const entry_offset = (index % fs_defs.DIR_ENTRIES_PER_SECTOR) * @sizeOf(DirectoryEntry);

        var sector = [_]u8{0} ** 512;
        try ide.readSectorLba28(self.drive, sector_lba, &sector);

        var entry: DirectoryEntry = undefined;
        @memcpy(std.mem.asBytes(&entry), sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)]);
        if (entry.name_len > FILENAME_MAX_LEN) return error.Corrupt;
        return entry;
    }

    fn writeDirectoryEntry(self: *const FileSystem, index: usize, entry: *const DirectoryEntry) FsError!void {
        const sector_lba = fs_defs.DIRECTORY_START_LBA + @as(u32, @intCast(index / fs_defs.DIR_ENTRIES_PER_SECTOR));
        const entry_offset = (index % fs_defs.DIR_ENTRIES_PER_SECTOR) * @sizeOf(DirectoryEntry);

        var sector = [_]u8{0} ** 512;
        try ide.readSectorLba28(self.drive, sector_lba, &sector);
        @memcpy(sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)], std.mem.asBytes(entry));
        try ide.writeSectorLba28(self.drive, sector_lba, &sector);
    }
};

fn makeDefaultSuperblock(num_sectors: u32) Superblock {
    return .{
        .magic = fs_defs.MAGIC,
        .version = fs_defs.VERSION,
        .directory_entry_count = @intCast(DIRECTORY_ENTRY_COUNT),
        .fs_start_lba = FS_START_LBA,
        .fs_sector_count = num_sectors,
        .next_free_lba = DATA_START_LBA,
        .file_count = 0,
        .reserved = [_]u8{0} ** 28,
    };
}

fn zeroEntry() DirectoryEntry {
    return .{
        .state = ENTRY_STATE_FREE,
        .name_len = 0,
        .flags = 0,
        .name = [_]u8{0} ** FILENAME_MAX_LEN,
        .start_lba = 0,
        .sector_count = 0,
        .size_bytes = 0,
        .created_ticks = 0,
        .modified_ticks = 0,
        .reserved = [_]u8{0} ** 24,
    };
}

fn entryOccupiesData(entry: *const DirectoryEntry) bool {
    return (entry.state == ENTRY_STATE_FILE or entry.state == ENTRY_STATE_RESERVED) and
        entry.sector_count > 0 and
        entry.start_lba >= DATA_START_LBA;
}

fn validateDataExtent(entry: *const DirectoryEntry) FsError!void {
    if (entry.size_bytes == 0) {
        if (entry.sector_count != 0 or entry.start_lba != 0) {
            return error.Corrupt;
        }
        return;
    }
    if (entry.sector_count == 0 or entry.start_lba < DATA_START_LBA) return error.Corrupt;
    if (entry.size_bytes > entry.sector_count * 512) return error.Corrupt;
}

fn markEntryDeleted(entry: *DirectoryEntry) void {
    entry.state = ENTRY_STATE_DELETED;
    entry.name_len = 0;
    entry.flags = 0;
    entry.name = [_]u8{0} ** FILENAME_MAX_LEN;
    entry.start_lba = 0;
    entry.sector_count = 0;
    entry.size_bytes = 0;
    entry.created_ticks = 0;
    entry.modified_ticks = 0;
    entry.reserved = [_]u8{0} ** 24;
}
