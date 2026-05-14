// Virtual filesystem layer
//
// For now forwards to a single ZODFS instance

const zodfs = @import("zodfs.zig");
const block_device = @import("../block_device.zig");
const kernel = @import("../kernel.zig");
const ide = @import("../ide.zig");
const console = @import("../console.zig");
const filedesc = @import("../filedesc.zig");
const abi = @import("abi");
const std = @import("std");

pub const FsError = zodfs.FsError;
pub const Stat = abi.Stat;

var root_fs: zodfs.FileSystem = undefined;
var root_block_device: ide.IdeBlockDevice = undefined;

pub fn mountRootFs() !void {
    const kernel_console = &console.primary;
    const drive = ide.Drive.master;
    ide.selectDrive(drive);

    const drive_info = try ide.identifyDrive(drive);
    kernel_console.puts("Drive model:     ");
    kernel_console.puts(&drive_info.model);
    kernel_console.puts("\nDrive serial:    ");
    kernel_console.puts(&drive_info.serial);
    kernel_console.puts("\nSectors (LBA28): ");
    kernel_console.putDecU32(drive_info.max_lba28);
    kernel_console.newline();

    root_block_device = ide.IdeBlockDevice.init(drive, drive_info.max_lba28);
    root_fs = try zodfs.FileSystem.mountOrFormat(&root_block_device.block_dev);
}

pub fn getRootFs() *zodfs.FileSystem {
    return &root_fs;
}

pub const splitPath = zodfs.splitPath;

/// Returns stat-like metadata for a filesystem path.
pub fn stat(path: []const u8) FsError!Stat {
    return try root_fs.statPath(path);
}

/// Returns true if a file or directory exists at the given path, false if not found.
pub fn pathExists(path: []const u8) FsError!bool {
    return try root_fs.pathExists(path);
}

/// Reads an entire regular file, given by its full path, into allocator-owned memory.
pub fn getFileContents(allocator: std.mem.Allocator, path: []const u8) (FsError || error{OutOfMemory})![]u8 {
    return root_fs.getFileContents(allocator, path);
}

/// Creates or overwrites a file with the given path with the provided full contents.
pub fn writeFileContents(path: []const u8, data: []const u8) FsError!void {
    return root_fs.writeFileContents(path, data);
}

/// Moves (renames) old_path to new_path, atomically replacing any existing regular file at
/// new_path. Directories cannot be moved. If new_path names an existing regular file it is
/// replaced, but only when no task has it open.
pub fn moveFile(old_path: []const u8, new_path: []const u8) FsError!void {
    if (std.mem.eql(u8, old_path, new_path)) return;

    // Resolve source; it must be a regular file.
    const src_inode_index = try root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, old_path);
    const src_stat = try root_fs.statInode(src_inode_index);
    if (src_stat.kind == .Directory) return error.NotAFile;

    // Resolve destination parent directory (must exist).
    const new_split = splitPath(new_path);
    const dst_parent_inode = try root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, new_split.dir);

    // If destination already exists remove it, provided it is a non-open file.
    if (root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, new_path)) |dst_inode_index| {
        const dst_stat = try root_fs.statInode(dst_inode_index);
        if (dst_stat.kind == .Directory) return error.NotAFile;
        const dst_par, const dst_idx, const dst_entry =
            try root_fs.walkPathToDirEntry(zodfs.ROOT_INODE_INDEX, new_path);
        if (isInodeOpen(dst_entry.inode_index)) return error.FileInUse;
        try root_fs.deleteFile(dst_par, dst_idx);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Add the new directory entry, then remove the old one.
    try root_fs.createLink(dst_parent_inode, new_split.name, src_inode_index);
    const src_par, const src_idx, _ =
        try root_fs.walkPathToDirEntry(zodfs.ROOT_INODE_INDEX, old_path);
    try root_fs.deleteFile(src_par, src_idx);
}

/// Creates a new hard link to an existing regular file.
pub fn linkFile(old_path: []const u8, new_path: []const u8) FsError!void {
    const target_inode_index = try root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, old_path);
    const split = splitPath(new_path);
    const parent_inode_index = try root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, split.dir);
    try root_fs.createLink(parent_inode_index, split.name, target_inode_index);
}

pub fn createDirectory(path: []const u8) FsError!void {
    _ = try root_fs.createDirectory(path);
}

/// Removes a directory unless it is still referenced by an open descriptor or is not empty.
pub fn removeDirectory(path: []const u8) FsError!void {
    const parent_inode, const index, const entry = try root_fs.walkPathToDirEntry(zodfs.ROOT_INODE_INDEX, path);

    if (isInodeOpen(entry.inode_index)) return error.FileInUse;
    try root_fs.deleteDirectory(parent_inode, index);
}

/// Unlinks a filesystem path unless it is still referenced by an open descriptor.
pub fn unlink(path: []const u8) FsError!void {
    const parent_inode, const index, const entry = try root_fs.walkPathToDirEntry(zodfs.ROOT_INODE_INDEX, path);

    // TODO: should no longer be necessary once we have inode cache
    if (isInodeOpen(entry.inode_index)) return error.FileInUse;
    try root_fs.deleteFile(parent_inode, index);
}

/////////////////////////// Open file handling ///////////////////////////

pub const OpenFile = struct {
    in_use: u8 = 0, // Reference counter
    disk_fs: *zodfs.FileSystem = undefined,
    inode_index: zodfs.InodeT = 0,
    offset: u32 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,

    pub fn getSize(self: *const OpenFile) FsError!u32 {
        return try self.disk_fs.getInodeSize(self.inode_index);
    }
};

pub const MAX_OPEN_FILES = 32;

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;

/// Opens or creates a filesystem-backed descriptor, not bound to a particular task.
pub fn createOpenFileEntry(path: []const u8, flags: u32) FsError!u8 {
    const access_mode = try filedesc.validateOpenFlags(flags);
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;
    const inode_index = if (path.len == 0 or std.mem.eql(u8, path, "/"))
        zodfs.ROOT_INODE_INDEX
    else
        // try to find an existing file at this path
        root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if ((flags & abi.O_CREAT) == 0) return error.FileNotFound;

                // not found, but creation requested: create the file and return its inode index
                const split = splitPath(path);
                const parent_inode = try root_fs.walkPathToInode(zodfs.ROOT_INODE_INDEX, split.dir);
                break :blk try root_fs.createFile(parent_inode, split.name);
            },
            else => return err,
        };

    if ((flags & abi.O_TRUNC) != 0) {
        try root_fs.resizeInode(inode_index, 0);
    }

    open_files[open_index] = .{
        .in_use = 1,
        .disk_fs = &root_fs,
        .inode_index = inode_index,
        .offset = 0,
        .readable = access_mode != abi.O_WRONLY,
        .writable = access_mode != abi.O_RDONLY,
        .append = (flags & abi.O_APPEND) != 0,
    };
    return @truncate(open_index);
}

fn findFreeOpenFileIndex() ?usize {
    for (&open_files, 0..) |open_file, index| {
        if (open_file.in_use == 0) return index;
    }
    return null;
}

pub fn getOpenFile(index: u8) *OpenFile {
    if (index >= open_files.len) @panic("invalid open file index");
    if (open_files[index].in_use == 0) @panic("open file index not in use");
    return &open_files[index];
}

pub fn closeOpenFile(index: u8) void {
    if (index >= open_files.len) @panic("invalid open file index");
    if (open_files[index].in_use == 0) @panic("open file index not in use");
    open_files[index].in_use -= 1;
    if (open_files[index].in_use == 0) {
        open_files[index] = .{};
    }
}

/// Check if any open file references the given inode index.
fn isInodeOpen(inode_index: zodfs.InodeT) bool {
    for (&open_files) |open_file| {
        if (open_file.in_use != 0 and open_file.inode_index == inode_index) {
            return true;
        }
    }
    return false;
}

/// Enumerates directory entries from an open directory file into an ABI buffer.
pub fn readDirEntries(file_index: u8, dest: []abi.DirEntry) FsError!usize {
    if (dest.len == 0) return 0;

    const open_file = getOpenFile(file_index);
    const dir_stat = try open_file.disk_fs.statInode(open_file.inode_index);
    if (dir_stat.kind != .Directory) return error.NotADirectory;

    const raw_entry_size = @sizeOf(zodfs.DirectoryEntry);
    if (open_file.offset % raw_entry_size != 0) return error.InvalidSeek;

    var dir_index: usize = @intCast(open_file.offset / raw_entry_size);
    var out_count: usize = 0;

    while (dir_index < zodfs.DIRECTORY_ENTRY_COUNT and out_count < dest.len) : (dir_index += 1) {
        open_file.offset = @intCast((dir_index + 1) * raw_entry_size);
        const raw_entry = (try open_file.disk_fs.getDirectoryEntry(open_file.inode_index, dir_index)) orelse continue;
        const inode_stat = try open_file.disk_fs.statInode(raw_entry.inode_index);
        dest[out_count] = .{
            .inode = raw_entry.inode_index,
            .size = inode_stat.size,
            .kind = inode_stat.kind,
            .name_len = raw_entry.name_len,
            .name = raw_entry.name,
        };
        out_count += 1;
    }
    return out_count;
}
