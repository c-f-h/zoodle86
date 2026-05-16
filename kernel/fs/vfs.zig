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
    root_fs = try zodfs.FileSystem.mount(&root_block_device.block_dev, kernel.getAllocator());
    try root_fs.initCache();
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
    const src_inode = try root_fs.getInodeAtPath(old_path);
    defer root_fs.drop(src_inode);
    if (src_inode.kind == .Directory) return error.NotAFile;

    // Resolve destination parent directory (must exist).
    const new_split = splitPath(new_path);
    const dst_parent_inode = try root_fs.getInodeAtPath(new_split.dir);
    defer root_fs.drop(dst_parent_inode);

    const existing = try root_fs.findDirEntryAndIndex(dst_parent_inode, new_split.name);
    // If destination already exists remove it, provided it is a non-open file.
    if (existing) |existing_index_and_direntry| {
        const ex_index, const ex_direntry = existing_index_and_direntry;
        if (ex_direntry.kind == .Directory) return error.NotAFile;
        if (root_fs.isInodeOpen(ex_direntry.inode_index)) return error.FileInUse;
        try root_fs.deleteFile(dst_parent_inode, ex_index);
    }

    // Add the new directory entry, then remove the old one.
    try root_fs.createLink(dst_parent_inode, new_split.name, src_inode);
    const src_parent_inode, const src_idx, _ =
        try root_fs.walkPathToDirEntry(root_fs.getRootInode(), old_path);
    defer root_fs.drop(src_parent_inode);
    try root_fs.deleteFile(src_parent_inode, src_idx);
}

/// Creates a new hard link to an existing regular file.
pub fn linkFile(old_path: []const u8, new_path: []const u8) FsError!void {
    const target_inode = try root_fs.getInodeAtPath(old_path);
    defer root_fs.drop(target_inode);

    const split = splitPath(new_path);
    const parent_inode = try root_fs.getInodeAtPath(split.dir);
    defer root_fs.drop(parent_inode);

    try root_fs.createLink(parent_inode, split.name, target_inode);
}

pub fn createDirectory(path: []const u8) FsError!void {
    _ = try root_fs.createDirectory(path);
}

/// Removes a directory unless it is still referenced by an open descriptor or is not empty.
pub fn removeDirectory(path: []const u8) FsError!void {
    const parent_inode, const index, const entry =
        try root_fs.walkPathToDirEntry(root_fs.getRootInode(), path);
    defer root_fs.drop(parent_inode);

    if (root_fs.isInodeOpen(entry.inode_index)) return error.FileInUse;
    try root_fs.deleteDirectory(parent_inode, index);
}

/// Unlinks a filesystem path unless it is still referenced by an open descriptor.
pub fn unlink(path: []const u8) FsError!void {
    const parent_inode, const index, const entry =
        try root_fs.walkPathToDirEntry(root_fs.getRootInode(), path);
    defer root_fs.drop(parent_inode);

    // TODO: should no longer be necessary once we have inode cache
    if (root_fs.isInodeOpen(entry.inode_index)) return error.FileInUse;
    try root_fs.deleteFile(parent_inode, index);
}

/////////////////////////// Open file handling ///////////////////////////

pub const OpenFile = struct {
    in_use: u8 = 0, // Reference counter
    disk_fs: *zodfs.FileSystem = undefined,
    inode_index: zodfs.InodeT = 0, // TODO: redundant due to cached inodes storing their own index
    inode: *zodfs.DiskInode = undefined,
    offset: u32 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,

    pub fn getSize(self: *const OpenFile) u32 {
        return self.inode.size_bytes;
    }
};

pub const MAX_OPEN_FILES = 32;

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;

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

/// Opens or creates a filesystem-backed descriptor, not bound to a particular task.
pub fn createOpenFileEntry(path: []const u8, flags: u32) FsError!u8 {
    const access_mode = try filedesc.validateOpenFlags(flags);
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;
    const inode = if (path.len == 0 or std.mem.eql(u8, path, "/"))
        root_fs.dup(root_fs.getRootInode())
    else
        // try to find an existing file at this path
        root_fs.getInodeAtPath(path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if ((flags & abi.O_CREAT) == 0) return error.FileNotFound;

                // not found, but creation requested: create the file and return its inode index
                const split = splitPath(path);
                const parent_inode = try root_fs.getInodeAtPath(split.dir);
                defer root_fs.drop(parent_inode);
                break :blk try root_fs.createFile(parent_inode, split.name);
            },
            else => return err,
        };
    defer root_fs.drop(inode);

    if ((flags & abi.O_TRUNC) != 0) {
        try root_fs.resizeInodeToSize(inode, 0);
    }

    open_files[open_index] = .{
        .in_use = 1,
        .disk_fs = &root_fs,
        .inode_index = root_fs.getInodeIndex(inode),
        .inode = inode,
        .offset = 0,
        .readable = access_mode != abi.O_WRONLY,
        .writable = access_mode != abi.O_RDONLY,
        .append = (flags & abi.O_APPEND) != 0,
    };
    return @truncate(open_index);
}

pub fn readOpenFile(index: u8, dest: []u8) FsError!usize {
    const open_file = getOpenFile(index);
    if (!open_file.readable) return error.AccessDenied;

    const bytes_read = try open_file.disk_fs.readInodeAt(open_file.inode, open_file.offset, dest);
    open_file.offset = std.math.add(u32, open_file.offset, bytes_read) catch return error.NoSpace;
    return bytes_read;
}

pub fn writeOpenFile(index: u8, src: []const u8) FsError!usize {
    const open_file = getOpenFile(index);
    if (!open_file.writable) return error.AccessDenied;

    const write_offset = if (open_file.append)
        open_file.inode.size_bytes
    else
        open_file.offset;
    const written = try open_file.disk_fs.writeInodeAt(open_file.inode, write_offset, src);
    open_file.offset = std.math.add(u32, write_offset, written) catch return error.NoSpace;
    return written;
}

pub fn closeOpenFile(index: u8) void {
    const open_file = getOpenFile(index);
    open_file.in_use -= 1;
    if (open_file.in_use == 0) {
        open_file.disk_fs.drop(open_file.inode);
        open_file.* = .{};
    }
}

/// Enumerates directory entries from an open directory file into an ABI buffer.
pub fn readDirEntries(file_index: u8, dest: []abi.DirEntry) FsError!usize {
    if (dest.len == 0) return 0;

    const open_file = getOpenFile(file_index);
    const dir_stat = try open_file.disk_fs.statInode(open_file.inode);
    if (dir_stat.kind != .Directory) return error.NotADirectory;

    const raw_entry_size = @sizeOf(zodfs.DirectoryEntry);
    if (open_file.offset % raw_entry_size != 0) return error.InvalidSeek;

    var dir_index: usize = @intCast(open_file.offset / raw_entry_size);
    var out_count: usize = 0;

    while (dir_index < zodfs.DIRECTORY_ENTRY_COUNT and out_count < dest.len) : (dir_index += 1) {
        open_file.offset = @intCast((dir_index + 1) * raw_entry_size);
        const raw_entry = try open_file.disk_fs.readDirEntry(open_file.inode, dir_index);
        if (raw_entry.kind == .Free) continue;
        const inode = try root_fs.getInode(raw_entry.inode_index);
        defer root_fs.drop(inode);
        const inode_stat = try open_file.disk_fs.statInode(inode);
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
