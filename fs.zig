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

    /// Reads an entire file into allocator-owned memory.
    pub fn readFile(self: *const FileSystem, allocator: std.mem.Allocator, name: []const u8) ReadFileError![]u8 {
        const entry = try self.findFileEntry(name);
        if (entry.size_bytes == 0) {
            return allocator.alloc(u8, 0);
        }
        if (entry.sector_count == 0 or entry.size_bytes > entry.sector_count * 512) {
            return error.Corrupt;
        }

        var data = try allocator.alloc(u8, @intCast(entry.size_bytes));
        var sector = [_]u8{0} ** 512;
        var remaining: usize = @intCast(entry.size_bytes);
        var offset: usize = 0;
        var lba = entry.start_lba;

        while (remaining > 0) : (lba += 1) {
            try ide.readSectorLba28(self.drive, lba, &sector);
            const chunk_len: usize = @min(remaining, sector.len);
            @memcpy(data[offset .. offset + chunk_len], sector[0..chunk_len]);
            remaining -= chunk_len;
            offset += chunk_len;
        }

        return data;
    }

    /// Creates or overwrites a file with the provided full contents.
    pub fn writeFile(self: *FileSystem, name: []const u8, data: []const u8) FsError!void {
        if (!validateName(name)) return error.InvalidName;

        const existing_index = try self.findFileIndex(name);
        const target_index = existing_index orelse (try self.findReusableEntryIndex());
        const sector_count = sectorsForBytes(data.len);
        const start_lba = try self.allocateExtent(sector_count);

        try self.writeDataExtent(start_lba, sector_count, data);

        var entry = zeroEntry();
        entry.state = ENTRY_STATE_FILE;
        entry.name_len = @intCast(name.len);
        @memcpy(entry.name[0..name.len], name);
        entry.start_lba = start_lba;
        entry.sector_count = sector_count;
        entry.size_bytes = @intCast(data.len);

        try self.writeDirectoryEntry(target_index, &entry);

        if (existing_index == null) {
            self.superblock.file_count += 1;
        }
        self.superblock.next_free_lba = start_lba + sector_count;
        try self.writeSuperblock();
    }

    /// Deletes a file from the directory without reclaiming its data extent.
    pub fn deleteFile(self: *FileSystem, name: []const u8) FsError!void {
        const index = (try self.findFileIndex(name)) orelse return error.FileNotFound;
        var entry = try self.readDirectoryEntry(index);
        entry.state = ENTRY_STATE_DELETED;
        entry.name_len = 0;
        entry.name = [_]u8{0} ** FILENAME_MAX_LEN;
        entry.start_lba = 0;
        entry.sector_count = 0;
        entry.size_bytes = 0;
        entry.created_ticks = 0;
        entry.modified_ticks = 0;
        entry.flags = 0;
        entry.reserved = [_]u8{0} ** 20;
        try self.writeDirectoryEntry(index, &entry);

        self.superblock.file_count -= 1;
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
        return self.readDirectoryEntry(index);
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

    fn allocateExtent(self: *const FileSystem, sector_count: u32) FsError!u32 {
        if (sector_count == 0) return 0;

        const start_lba = self.superblock.next_free_lba;
        const limit_lba = self.superblock.fs_start_lba + self.superblock.fs_sector_count;
        if (start_lba < self.superblock.data_start_lba or start_lba + sector_count > limit_lba) {
            return error.NoSpace;
        }

        return start_lba;
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
        const sector_lba = self.superblock.directory_start_lba + @as(u32, @intCast(index / 8));
        const entry_offset = (index % 8) * @sizeOf(DirectoryEntry);

        var sector = [_]u8{0} ** 512;
        try ide.readSectorLba28(self.drive, sector_lba, &sector);

        var entry: DirectoryEntry = undefined;
        @memcpy(std.mem.asBytes(&entry), sector[entry_offset .. entry_offset + @sizeOf(DirectoryEntry)]);
        if (entry.name_len > FILENAME_MAX_LEN) return error.Corrupt;
        return entry;
    }

    fn writeDirectoryEntry(self: *const FileSystem, index: usize, entry: *const DirectoryEntry) FsError!void {
        const sector_lba = self.superblock.directory_start_lba + @as(u32, @intCast(index / 8));
        const entry_offset = (index % 8) * @sizeOf(DirectoryEntry);

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
        .directory_start_lba = FS_START_LBA + SUPERBLOCK_SECTORS,
        .directory_sector_count = DIRECTORY_SECTORS,
        .data_start_lba = DATA_START_LBA,
        .next_free_lba = DATA_START_LBA,
        .file_count = 0,
        .reserved = [_]u8{0} ** 28,
    };
}

fn zeroEntry() DirectoryEntry {
    return .{
        .state = ENTRY_STATE_FREE,
        .name_len = 0,
        .reserved0 = 0,
        .name = [_]u8{0} ** FILENAME_MAX_LEN,
        .start_lba = 0,
        .sector_count = 0,
        .size_bytes = 0,
        .created_ticks = 0,
        .modified_ticks = 0,
        .flags = 0,
        .reserved = [_]u8{0} ** 20,
    };
}
