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

pub const MAX_OPEN_FILES = 32;

pub const FiledescError = fs.WriteFileError || error{
    AccessDenied,
    BadFd,
    InvalidFlags,
    ProcessFileTableFull,
    SystemFileTableFull,
};

const OpenFile = struct {
    in_use: bool = false,
    entry_index: usize = 0,
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
pub fn openFile(disk_fs: *fs.FileSystem, ptask: *task.Task, path: []const u8, flags: u32) FiledescError!u32 {
    const access_mode = try validateOpenFlags(flags);
    const fd = ptask.findFreeFd() orelse return error.ProcessFileTableFull;
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;

    const entry_index = try disk_fs.getFileIndex(path) orelse blk: {
        if ((flags & O_CREAT) == 0) return error.FileNotFound;
        break :blk try disk_fs.createFile(path);
    };

    if ((flags & O_TRUNC) != 0) {
        try disk_fs.truncateFile(entry_index);
    }

    open_files[open_index] = .{
        .in_use = true,
        .entry_index = entry_index,
        .offset = 0,
        .readable = access_mode != O_WRONLY,
        .writable = access_mode != O_RDONLY,
        .append = (flags & O_APPEND) != 0,
    };
    ptask.setFileFd(fd, open_index);
    return fd;
}

/// Reads from a task-owned descriptor into a user buffer.
pub fn readFile(disk_fs: *fs.FileSystem, ptask: *task.Task, fd: u32, dest: []u8) FiledescError!usize {
    if (dest.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.kind) {
        .file => blk: {
            const open_file = getOpenFile(slot.file_index) orelse return error.BadFd;
            if (!open_file.readable) return error.AccessDenied;

            const bytes_read = try disk_fs.readFileAt(open_file.entry_index, open_file.offset, dest);
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
            console.puts(src);
            break :blk src.len;
        },
        .file => blk: {
            const open_file = getOpenFile(slot.file_index) orelse return error.BadFd;
            if (!open_file.writable) return error.AccessDenied;

            const write_offset = if (open_file.append)
                try disk_fs.getFileSize(open_file.entry_index)
            else
                open_file.offset;
            const written = try disk_fs.writeFileAt(allocator, open_file.entry_index, write_offset, src);
            open_file.offset = std.math.add(u32, write_offset, written) catch return error.NoSpace;
            break :blk written;
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
