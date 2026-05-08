const console = @import("console.zig");
const fs = @import("fs.zig");
const std = @import("std");
const task = @import("task.zig");
const pipe = @import("pipe.zig");
const kernel = @import("kernel.zig");

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

pub const FdKind = enum(u8) {
    empty,
    stdin,
    stdout,
    stderr,
    file,
    pipe,
};

pub const FileDesc = union(FdKind) {
    empty: void,
    stdin: void,
    stdout: *task.Task,
    stderr: *task.Task,
    file: u8, // Always refers to a valid index in the global open_files table
    pipe: struct { handle: *pipe.Pipe, writable: bool },

    /// Closes a descriptor and releases any backing pipe or open-file state.
    pub fn close(self: *FileDesc) error{BadFd}!void {
        switch (self.*) {
            .stdin => {},
            .stdout => {},
            .stderr => {},
            .file => |file_index| {
                closeOpenFile(file_index);
            },
            .pipe => |pipe_info| {
                const pp = pipe_info.handle;
                const is_writer = pipe_info.writable;
                if (is_writer) {
                    if (pp.num_writers == 0) @panic("invalid pipe state: no writers");
                    pp.num_writers -= 1;
                } else {
                    if (pp.num_readers == 0) @panic("invalid pipe state: no readers");
                    pp.num_readers -= 1;
                }
                if (pp.num_readers == 0 and pp.num_writers == 0) {
                    pp.deinit(kernel.getAllocator());
                    kernel.getAllocator().destroy(pp);
                }
            },
            else => return error.BadFd,
        }
        self.* = .empty;
    }

    /// Closes a descriptor if it is open and always leaves the slot empty.
    pub fn closeIfOpen(self: *FileDesc) void {
        self.close() catch {};
        self.* = .empty;
    }

    /// Reads bytes from a descriptor into the provided buffer.
    pub fn read(self: *FileDesc, dest: []u8) (fs.FsError || error{ BadFd, AccessDenied })!usize {
        switch (self.*) {
            .file => |file_index| {
                const open_file = getOpenFile(file_index);
                if (!open_file.readable) return error.AccessDenied;

                const inode = try open_file.disk_fs.readFileInode(open_file.inode_index);
                const bytes_read = try open_file.disk_fs.readInodeAt(&inode, open_file.offset, dest);
                open_file.offset = std.math.add(u32, open_file.offset, bytes_read) catch return error.NoSpace;
                return bytes_read;
            },
            .pipe => |pipe_info| {
                const pp = pipe_info.handle;
                const is_writer = pipe_info.writable;
                if (is_writer) return error.AccessDenied;
                const bytes_read = pp.read(dest);
                if (bytes_read == 0) {
                    if (pp.num_writers == 0) {
                        return 0; // EOF
                    } else {
                        return error.BadFd; // TODO: should block on empty pipe with writers
                    }
                }
                return bytes_read;
            },
            else => return error.BadFd,
        }
    }

    /// Writes bytes from the provided buffer to a descriptor.
    pub fn write(self: *FileDesc, src: []const u8) !usize {
        switch (self.*) {
            .stdout, .stderr => |ptask| {
                const con = ptask.stdout_console orelse &console.primary;
                con.puts(src);
                return src.len;
            },
            .file => |file_index| {
                const open_file = getOpenFile(file_index);
                if (!open_file.writable) return error.AccessDenied;

                const write_offset = if (open_file.append)
                    try open_file.disk_fs.getInodeSize(open_file.inode_index)
                else
                    open_file.offset;
                const written = try open_file.disk_fs.writeInodeAt(open_file.inode_index, write_offset, src);
                open_file.offset = std.math.add(u32, write_offset, written) catch return error.NoSpace;
                return written;
            },
            .pipe => |pipe_info| {
                const pp = pipe_info.handle;
                const is_writer = pipe_info.writable;
                if (!is_writer) return error.AccessDenied;
                if (pp.num_readers == 0) return error.BrokenPipe;
                const written = pp.write(src);
                if (written == 0) {
                    return error.BadFd; // TODO: should block on full pipe with readers
                }
                return written;
            },
            else => return error.BadFd,
        }
    }
};

/// Creates a fresh pipe and returns descriptors for its read and write ends.
pub fn makePipe(capacity: usize) error{OutOfMemory}!struct { FileDesc, FileDesc } {
    const pp = try kernel.getAllocator().create(pipe.Pipe);
    errdefer kernel.getAllocator().destroy(pp);
    pp.* = try pipe.Pipe.init(kernel.getAllocator(), capacity);
    pp.num_readers = 1;
    pp.num_writers = 1;
    return .{
        FileDesc{ .pipe = .{ .handle = pp, .writable = false } },
        FileDesc{ .pipe = .{ .handle = pp, .writable = true } },
    };
}

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
    disk_fs: *fs.FileSystem = undefined,
    inode_index: fs.InodeT = 0,
    offset: u32 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,
};

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;

/// Opens or creates a filesystem-backed descriptor for a task.
pub fn openFile(disk_fs: *fs.FileSystem, ptask: *task.Task, path: []const u8, flags: u32) FiledescError!u32 {
    const access_mode = try validateOpenFlags(flags);
    const fd = ptask.findFreeFd() orelse return error.ProcessFileTableFull;
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;

    const split = fs.splitPath(path);
    const parent_inode = try disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, split.dir);

    const inode_index = try disk_fs.findFileInodeIndex(parent_inode, split.name) orelse blk: {
        if ((flags & O_CREAT) == 0) return error.FileNotFound;
        break :blk try disk_fs.createFile(parent_inode, split.name);
    };

    if ((flags & O_TRUNC) != 0) {
        try disk_fs.resizeInode(inode_index, 0);
    }

    open_files[open_index] = .{
        .in_use = true,
        .disk_fs = disk_fs,
        .inode_index = inode_index,
        .offset = 0,
        .readable = access_mode != O_WRONLY,
        .writable = access_mode != O_RDONLY,
        .append = (flags & O_APPEND) != 0,
    };
    ptask.setFdSlot(fd, FileDesc{ .file = @truncate(open_index) });
    return fd;
}

/// Unlinks a filesystem path unless it is still referenced by an open descriptor.
pub fn unlinkFile(disk_fs: *fs.FileSystem, path: []const u8) FiledescError!void {
    const parent_inode, const index, const entry = try disk_fs.walkPathToDirEntry(fs.ROOT_INODE_INDEX, path);

    if (isInodeOpen(entry.inode_index)) return error.FileInUse;
    try disk_fs.deleteFile(parent_inode, index);
}

/// Removes a directory unless it is still referenced by an open descriptor or is not empty.
pub fn removeDirectory(disk_fs: *fs.FileSystem, path: []const u8) FiledescError!void {
    const parent_inode, const index, const entry = try disk_fs.walkPathToDirEntry(fs.ROOT_INODE_INDEX, path);

    if (isInodeOpen(entry.inode_index)) return error.FileInUse;
    try disk_fs.deleteDirectory(parent_inode, index);
}

/// Reads from a task-owned descriptor into a user buffer.
pub fn readFromFd(ptask: *task.Task, fd: u32, dest: []u8) FiledescError!usize {
    if (dest.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return slot.read(dest);
}

const WriteError = FiledescError || error{BrokenPipe};

/// Writes to a task-owned descriptor from a user buffer.
pub fn writeToFd(ptask: *task.Task, fd: u32, src: []const u8) WriteError!usize {
    if (src.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return slot.write(src);
}

/// Repositions a task-owned file descriptor and returns the resulting byte offset.
pub fn seekFile(disk_fs: *fs.FileSystem, ptask: *task.Task, fd: u32, offset: i32, whence_raw: u32) FiledescError!u32 {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.*) {
        .file => |file_index| blk: {
            const open_file = getOpenFile(file_index);
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

/// Resizes a task-owned filesystem-backed descriptor without changing its current offset.
pub fn truncateFile(disk_fs: *fs.FileSystem, ptask: *task.Task, fd: u32, size: u32) FiledescError!void {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    switch (slot.*) {
        .file => |file_index| {
            const open_file = getOpenFile(file_index);
            if (!open_file.writable) return error.AccessDenied;
            try disk_fs.resizeInode(open_file.inode_index, size);
        },
        else => return error.BadFd,
    }
}

/// Closes a task-local descriptor and releases any backing open-file slot.
pub fn closeFile(ptask: *task.Task, fd: u32) FiledescError!void {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    try slot.close(); // will also set the slot to empty
}

/// Closes all descriptors owned by a task before the task slot is recycled.
pub fn closeTaskFiles(ptask: *task.Task) void {
    for (&ptask.fd_table) |*slot| {
        slot.closeIfOpen();
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

fn getOpenFile(index: u8) *OpenFile {
    if (index >= open_files.len) @panic("invalid open file index");
    if (!open_files[index].in_use) @panic("open file index not in use");
    return &open_files[index];
}

fn closeOpenFile(index: u8) void {
    // TODO: should track reference count
    if (index >= open_files.len) @panic("invalid open file index");
    if (!open_files[index].in_use) @panic("open file index not in use");
    open_files[index] = .{};
}

fn isInodeOpen(inode_index: fs.InodeT) bool {
    for (&open_files) |open_file| {
        if (open_file.in_use and open_file.inode_index == inode_index) {
            return true;
        }
    }
    return false;
}
