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
const Stat = abi.Stat;

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
        if (filedesc.isInodeOpen(dst_entry.inode_index)) return error.FileInUse;
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

    if (filedesc.isInodeOpen(entry.inode_index)) return error.FileInUse;
    try root_fs.deleteDirectory(parent_inode, index);
}

/// Unlinks a filesystem path unless it is still referenced by an open descriptor.
pub fn unlink(path: []const u8) FsError!void {
    const parent_inode, const index, const entry = try root_fs.walkPathToDirEntry(zodfs.ROOT_INODE_INDEX, path);

    // TODO: should no longer be necessary once we have inode cache
    if (filedesc.isInodeOpen(entry.inode_index)) return error.FileInUse;
    try root_fs.deleteFile(parent_inode, index);
}
