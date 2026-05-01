const console = @import("console.zig");
const fs = @import("fs.zig");
const std = @import("std");
const task = @import("task.zig");

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_ACCMODE: u32 = 3;
pub const O_CREAT: u32 = 1 << 6;
pub const O_TRUNC: u32 = 1 << 9;
pub const O_APPEND: u32 = 1 << 10;
pub const SEEK_SET: u32 = 0;
pub const SEEK_CUR: u32 = 1;
pub const SEEK_END: u32 = 2;

pub const MAX_OPEN_FILES = 32;

pub const FiledescError = fs.WriteFileError || error{
    AccessDenied,
    BadFd,
    FileInUse,
    InvalidFlags,
    InvalidSeek,
    ProcessFileTableFull,
    SystemFileTableFull,
};

const SeekWhence = enum(u32) {
    Set = SEEK_SET,
    Cur = SEEK_CUR,
    End = SEEK_END,
};

const OpenFile = struct {
    in_use: bool = false,
    inode_index: u16 = 0,
    offset: u32 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,
};

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;

/// Initializes the global kernel open-file table.
pub fn init() void {
    for (&open_files) |*open_file| {
        open_file.* = .{};
    }
}

/// Opens or creates a filesystem-backed descriptor for a task.
pub fn openFile(disk_fs: *fs.FileSystem, allocator: std.mem.Allocator, ptask: *task.Task, path: []const u8, flags: u32) FiledescError!u32 {
    const access_mode = try validateOpenFlags(flags);
    const fd = ptask.findFreeFd() orelse return error.ProcessFileTableFull;
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;

    const inode_index = try disk_fs.findFileInodeIndex(path) orelse blk: {
        if ((flags & O_CREAT) == 0) return error.FileNotFound;
        break :blk try disk_fs.createFile(path);
    };

    if ((flags & O_TRUNC) != 0) {
        try disk_fs.truncateInode(allocator, inode_index);
    }

    open_files[open_index] = .{
        .in_use = true,
        .inode_index = inode_index,
        .offset = 0,
        .readable = access_mode != O_WRONLY,
        .writable = access_mode != O_RDONLY,
        .append = (flags & O_APPEND) != 0,
    };
    ptask.setFileFd(fd, open_index);
    return fd;
}

/// Unlinks a filesystem path unless it is still referenced by an open descriptor.
pub fn unlinkFile(disk_fs: *fs.FileSystem, allocator: std.mem.Allocator, path: []const u8) FiledescError!void {
    const inode_index = (try disk_fs.findFileInodeIndex(path)) orelse return error.FileNotFound;
    if (isInodeOpen(inode_index)) return error.FileInUse;
    try disk_fs.deleteFile(allocator, path);
}

/// Reads from a task-owned descriptor into a user buffer.
pub fn readFile(disk_fs: *fs.FileSystem, ptask: *task.Task, fd: u32, dest: []u8) FiledescError!usize {
    if (dest.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.kind) {
        .file => blk: {
            const open_file = getOpenFile(slot.file_index) orelse return error.BadFd;
            if (!open_file.readable) return error.AccessDenied;

            const bytes_read = try disk_fs.readInodeAt(open_file.inode_index, open_file.offset, dest);
            open_file.offset = std.math.add(u32, open_file.offset, bytes_read) catch return error.NoSpace;
            break :blk bytes_read;
        },
        else => error.BadFd,
    };
}

/// Writes to a task-owned descriptor from a user buffer.
pub fn writeFile(disk_fs: *fs.FileSystem, allocator: std.mem.Allocator, ptask: *task.Task, fd: u32, src: []const u8) FiledescError!usize {
    if (src.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.kind) {
        .stdout, .stderr => blk: {
            const con = ptask.stdout_console orelse &console.primary;
            con.puts(src);
            break :blk src.len;
        },
        .file => blk: {
            const open_file = getOpenFile(slot.file_index) orelse return error.BadFd;
            if (!open_file.writable) return error.AccessDenied;

            const write_offset = if (open_file.append)
                try disk_fs.getInodeSize(open_file.inode_index)
            else
                open_file.offset;
            const written = try disk_fs.writeInodeAt(allocator, open_file.inode_index, write_offset, src);
            open_file.offset = std.math.add(u32, write_offset, written) catch return error.NoSpace;
            break :blk written;
        },
        else => error.BadFd,
    };
}

/// Repositions a task-owned file descriptor and returns the resulting byte offset.
pub fn seekFile(disk_fs: *fs.FileSystem, ptask: *task.Task, fd: u32, offset: i32, whence_raw: u32) FiledescError!u32 {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.kind) {
        .file => blk: {
            const open_file = getOpenFile(slot.file_index) orelse return error.BadFd;
            const whence = switch (whence_raw) {
                SEEK_SET => SeekWhence.Set,
                SEEK_CUR => SeekWhence.Cur,
                SEEK_END => SeekWhence.End,
                else => return error.InvalidSeek,
            };
            const base: i64 = switch (whence) {
                .Set => 0,
                .Cur => open_file.offset,
                .End => try disk_fs.getInodeSize(open_file.inode_index),
            };
            const next_offset = std.math.add(i64, base, @as(i64, offset)) catch return error.InvalidSeek;
            if (next_offset < 0 or next_offset > std.math.maxInt(u32)) return error.InvalidSeek;
            open_file.offset = @intCast(next_offset);
            break :blk open_file.offset;
        },
        else => error.BadFd,
    };
}

/// Closes a task-local descriptor and releases any backing open-file slot.
pub fn closeFile(ptask: *task.Task, fd: u32) FiledescError!void {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    switch (slot.kind) {
        .empty => return error.BadFd,
        .file => {
            if (getOpenFile(slot.file_index)) |_| {
                open_files[slot.file_index] = .{};
            } else {
                return error.BadFd;
            }
        },
        else => {},
    }
    ptask.clearFd(fd);
}

/// Closes all descriptors owned by a task before the task slot is recycled.
pub fn closeTaskFiles(ptask: *task.Task) void {
    for (&ptask.fd_table, 0..) |slot, fd| {
        switch (slot.kind) {
            .file => {
                open_files[slot.file_index] = .{};
            },
            else => {},
        }
        ptask.fd_table[fd] = .{};
    }
}

fn validateOpenFlags(flags: u32) FiledescError!u32 {
    const known_flags = O_ACCMODE | O_CREAT | O_TRUNC | O_APPEND;
    if ((flags & ~known_flags) != 0) return error.InvalidFlags;

    const access_mode = flags & O_ACCMODE;
    switch (access_mode) {
        O_RDONLY, O_WRONLY, O_RDWR => {},
        else => return error.InvalidFlags,
    }

    if ((flags & O_TRUNC) != 0 and access_mode == O_RDONLY) return error.InvalidFlags;
    if ((flags & O_APPEND) != 0 and access_mode == O_RDONLY) return error.InvalidFlags;
    return access_mode;
}

fn findFreeOpenFileIndex() ?usize {
    for (&open_files, 0..) |open_file, index| {
        if (!open_file.in_use) return index;
    }
    return null;
}

fn getOpenFile(index: u8) ?*OpenFile {
    if (index >= open_files.len) return null;
    if (!open_files[index].in_use) return null;
    return &open_files[index];
}

fn isInodeOpen(inode_index: u16) bool {
    for (&open_files) |open_file| {
        if (open_file.in_use and open_file.inode_index == inode_index) {
            return true;
        }
    }
    return false;
}
