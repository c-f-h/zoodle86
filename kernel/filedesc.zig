const std = @import("std");

const console = @import("console.zig");
const char_device = @import("char_device.zig");
const vfs = @import("fs/vfs.zig");
const framebuf = @import("gfx/framebuf.zig");
const task = @import("task.zig");
const pipe = @import("pipe.zig");
const kernel = @import("kernel.zig");
const tty = @import("tty.zig");
const abi = @import("abi");

pub const O_RDONLY = abi.O_RDONLY;
pub const O_WRONLY = abi.O_WRONLY;
pub const O_RDWR = abi.O_RDWR;
pub const O_ACCMODE = abi.O_ACCMODE;
pub const O_CREAT = abi.O_CREAT;
pub const O_TRUNC = abi.O_TRUNC;
pub const O_APPEND = abi.O_APPEND;
pub const SEEK_SET = abi.SEEK_SET;
pub const SEEK_CUR = abi.SEEK_CUR;
pub const SEEK_END = abi.SEEK_END;

pub const FileDesc = union(enum) {
    empty: void,
    file: u8, // Always refers to a valid index in the global open_files table
    pipe: struct { handle: *pipe.Pipe, writable: bool },
    char_device: struct { handle: *char_device.CharDevice, readable: bool, writable: bool, offset: u32 = 0 },

    /// Closes a descriptor and releases any backing pipe or open-file state.
    pub fn close(self: *FileDesc) error{BadFd}!void {
        switch (self.*) {
            .file => |file_index| {
                vfs.closeOpenFile(file_index);
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
            .char_device => {},
            else => return error.BadFd,
        }
        self.* = .empty;
    }

    pub fn dupe(self: *FileDesc) FileDesc {
        switch (self.*) {
            .empty => return .{ .empty = {} },
            .file => |file_index| {
                const open_file = vfs.getOpenFile(file_index);
                open_file.in_use += 1;
                if (open_file.in_use == 0) @panic("file reference count overflow");
                return .{ .file = file_index };
            },
            .pipe => |pipe_info| {
                const pp = pipe_info.handle;
                const is_writer = pipe_info.writable;
                if (is_writer) {
                    pp.num_writers += 1;
                    return .{ .pipe = .{ .handle = pp, .writable = true } };
                } else {
                    pp.num_readers += 1;
                    return .{ .pipe = .{ .handle = pp, .writable = false } };
                }
            },
            .char_device => return self.*,
        }
    }

    /// Closes a descriptor if it is open and always leaves the slot empty.
    pub fn closeIfOpen(self: *FileDesc) void {
        self.close() catch {};
        self.* = .empty;
    }

    /// Reads bytes from a descriptor into the provided buffer.
    pub fn read(self: *FileDesc, dest: []u8) FiledescError!usize {
        switch (self.*) {
            .file => |file_index| return vfs.readOpenFile(file_index, dest),
            .pipe => |pipe_info| {
                const pp = pipe_info.handle;
                const is_writer = pipe_info.writable;
                if (is_writer) return error.AccessDenied;
                if (pp.empty()) {
                    if (pp.num_writers == 0) {
                        return 0; // EOF
                    } else {
                        try task.getCurrentTask().waitInQueue(&pp.read_waiters);
                        _ = kernel.kernel_yield();
                    }
                }
                return pp.read(dest);
            },
            .char_device => |*char_info| {
                if (!char_info.readable) return error.AccessDenied;
                const bytes_read = try char_info.handle.read(char_info.offset, dest);
                if (char_info.handle.seekable()) {
                    char_info.offset = std.math.add(u32, char_info.offset, @intCast(bytes_read)) catch return error.InvalidSeek;
                }
                return bytes_read;
            },
            else => return error.BadFd,
        }
    }

    /// Writes bytes from the provided buffer to a descriptor.
    pub fn write(self: *FileDesc, src: []const u8) !usize {
        switch (self.*) {
            .file => |file_index| return vfs.writeOpenFile(file_index, src),
            .pipe => |pipe_info| {
                const pp = pipe_info.handle;
                const is_writer = pipe_info.writable;
                if (!is_writer) return error.AccessDenied;
                if (pp.num_readers == 0) return error.BrokenPipe;
                if (pp.full()) {
                    try task.getCurrentTask().waitInQueue(&pp.write_waiters);
                    _ = kernel.kernel_yield();
                }
                return pp.write(src);
            },
            .char_device => |*char_info| {
                if (!char_info.writable) return error.AccessDenied;
                const bytes_written = try char_info.handle.write(char_info.offset, src);
                if (char_info.handle.seekable()) {
                    char_info.offset = std.math.add(u32, char_info.offset, @intCast(bytes_written)) catch return error.InvalidSeek;
                }
                return bytes_written;
            },
            else => return error.BadFd,
        }
    }

    /// Returns stat-like metadata for the descriptor.
    pub fn stat(self: *FileDesc) FiledescError!vfs.Stat {
        return switch (self.*) {
            .file => |file_index| blk: {
                const open_file = vfs.getOpenFile(file_index);
                var st = try open_file.disk_fs.statInode(open_file.inode);
                st.flags = buildOpenFileStatFlags(open_file);
                break :blk st;
            },
            .pipe => |pipe_info| blk: {
                const pp = pipe_info.handle;
                var flags = abi.STAT_FLAG_SYNTHETIC;
                if (pipe_info.writable) {
                    flags |= abi.STAT_FLAG_WRITABLE;
                } else {
                    flags |= abi.STAT_FLAG_READABLE;
                }
                break :blk .{
                    .inode = 0,
                    .size = @intCast(pp.buffer.size),
                    .blocks = 0,
                    .blksize = @intCast(pp.buffer.buf.len),
                    .nlink = 1,
                    .kind = .Pipe,
                    .flags = flags,
                    .on_device = .{},
                    .device = .{},
                };
            },
            .char_device => |char_info| blk: {
                var flags = abi.STAT_FLAG_SYNTHETIC;
                if (char_info.readable) flags |= abi.STAT_FLAG_READABLE;
                if (char_info.writable) flags |= abi.STAT_FLAG_WRITABLE;
                break :blk .{
                    .inode = 0,
                    .size = char_info.handle.size(),
                    .blocks = 0,
                    .blksize = @intCast(char_info.handle.bufferSize()),
                    .nlink = 1,
                    .kind = .CharDevice,
                    .flags = flags,
                    .on_device = .{},
                    .device = char_info.handle.device,
                };
            },
            else => error.BadFd,
        };
    }

    /// Applies a device-specific ioctl request to this descriptor.
    pub fn ioctl(self: *FileDesc, command: u32, arg: u32) FiledescError!u32 {
        return switch (self.*) {
            .char_device => |char_info| try char_info.handle.ioctl(command, arg),
            else => error.InvalidArgument,
        };
    }
};

/// Creates a fresh pipe and returns descriptors for its read and write ends.
pub fn makePipeWithSize(capacity: usize) error{OutOfMemory}!struct { FileDesc, FileDesc } {
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

pub fn makePipe() error{OutOfMemory}!struct { FileDesc, FileDesc } {
    return makePipeWithSize(4096);
}

/// Attaches a new reader descriptor to an existing pipe.
pub fn newPipeReader(pp: *pipe.Pipe) FileDesc {
    pp.num_readers += 1;
    return FileDesc{ .pipe = .{ .handle = pp, .writable = false } };
}

pub const FiledescError = vfs.FsError || error{
    AccessViolation,
    AccessDenied,
    BadFd,
    FileInUse,
    InvalidArgument,
    InvalidFlags,
    InvalidSeek,
    NoDevice,
    ProcessFileTableFull,
    SystemFileTableFull,
    OutOfMemory,
};

pub const Stat = abi.Stat;
const DirEntry = abi.DirEntry;
const SeekWhence = abi.SeekWhence;

pub fn openFileDesc(path: []const u8, flags: u32) vfs.FsError!FileDesc {
    return FileDesc{ .file = try vfs.createOpenFileEntry(path, flags) };
}

fn openTty(index: u8, access_mode: u32) ?FileDesc {
    if (kernel.getTty(index)) |ptty| {
        return .{ .char_device = .{
            .handle = ptty.charDevice(),
            .readable = access_mode != O_WRONLY,
            .writable = access_mode != O_RDONLY,
            .offset = 0,
        } };
    }
    return null;
}

fn openFramebuf(minor: u8, access_mode: u32) vfs.FsError!?FileDesc {
    if (minor != 0) return error.FileNotFound;
    const dev = framebuf.getCharDevice() orelse return error.NoDevice;
    return .{ .char_device = .{
        .handle = dev,
        .readable = access_mode != O_WRONLY,
        .writable = access_mode != O_RDONLY,
        .offset = 0,
    } };
}

/// Open a special device inode and map it to a device descriptor.
fn tryOpenSpecialInode(path: []const u8, flags: u32) vfs.FsError!?FileDesc {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;

    const access_mode = try validateOpenFlags(flags);
    const st = vfs.stat(path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return switch (st.kind) {
        .CharDevice => switch (st.device.major) {
            .Tty => openTty(st.device.minor, access_mode) orelse error.FileNotFound,
            .FrameBuffer => try openFramebuf(st.device.minor, access_mode),
            else => error.NoDevice,
        },
        .BlockDevice => error.NoDevice,
        else => null,
    };
}

/// Opens or creates a filesystem-backed descriptor for a task.
pub fn openFile(ptask: *task.Task, path: []const u8, flags: u32) FiledescError!u32 {
    const fd = ptask.findFreeFd() orelse return error.ProcessFileTableFull;
    const filedesc =
        try tryOpenSpecialInode(path, flags) orelse
        try openFileDesc(path, flags);
    ptask.setFdSlot(fd, filedesc);
    return fd;
}

/// Returns stat-like metadata for a task-owned file descriptor.
pub fn statFd(ptask: *task.Task, fd: u32) FiledescError!Stat {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return slot.stat();
}

/// Reads from a task-owned descriptor into a user buffer.
pub fn readFromFd(ptask: *task.Task, fd: u32, dest: []u8) FiledescError!usize {
    if (dest.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return slot.read(dest);
}

/// Enumerates directory entries from a task-owned directory descriptor into a fixed-size ABI buffer.
pub fn readDirEntries(ptask: *task.Task, fd: u32, dest: []DirEntry) FiledescError!usize {
    if (dest.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.*) {
        .file => |file_index| vfs.readDirEntries(file_index, dest),
        else => error.NotADirectory,
    };
}

const WriteError = FiledescError || error{BrokenPipe};

/// Writes to a task-owned descriptor from a user buffer.
pub fn writeToFd(ptask: *task.Task, fd: u32, src: []const u8) WriteError!usize {
    if (src.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return slot.write(src);
}

/// Applies an ioctl request to a task-owned descriptor.
pub fn ioctlFd(ptask: *task.Task, fd: u32, command: u32, arg: u32) FiledescError!u32 {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return slot.ioctl(command, arg);
}

/// Repositions a task-owned file descriptor and returns the resulting byte offset.
pub fn seekFile(ptask: *task.Task, fd: u32, offset: i32, whence_raw: u32) FiledescError!u32 {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.*) {
        .file => |file_index| blk: {
            const open_file = vfs.getOpenFile(file_index);
            const whence = switch (whence_raw) {
                SEEK_SET => SeekWhence.Set,
                SEEK_CUR => SeekWhence.Cur,
                SEEK_END => SeekWhence.End,
                else => return error.InvalidSeek,
            };
            const base: i64 = switch (whence) {
                .Set => 0,
                .Cur => open_file.offset,
                .End => open_file.getSize(),
            };
            const next_offset = std.math.add(i64, base, @as(i64, offset)) catch return error.InvalidSeek;
            if (next_offset < 0 or next_offset > std.math.maxInt(u32)) return error.InvalidSeek;
            open_file.offset = @intCast(next_offset);
            break :blk open_file.offset;
        },
        .char_device => |*char_info| blk: {
            if (!char_info.handle.seekable()) return error.BadFd;
            const whence = switch (whence_raw) {
                SEEK_SET => SeekWhence.Set,
                SEEK_CUR => SeekWhence.Cur,
                SEEK_END => SeekWhence.End,
                else => return error.InvalidSeek,
            };
            const base: i64 = switch (whence) {
                .Set => 0,
                .Cur => char_info.offset,
                .End => char_info.handle.size(),
            };
            const next_offset = std.math.add(i64, base, @as(i64, offset)) catch return error.InvalidSeek;
            if (next_offset < 0 or next_offset > char_info.handle.size()) return error.InvalidSeek;
            char_info.offset = @intCast(next_offset);
            break :blk char_info.offset;
        },
        else => error.BadFd,
    };
}

/// Resizes a task-owned filesystem-backed descriptor without changing its current offset.
pub fn truncateFile(ptask: *task.Task, fd: u32, size: u32) FiledescError!void {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    switch (slot.*) {
        .file => |file_index| {
            const open_file = vfs.getOpenFile(file_index);
            if (!open_file.writable) return error.AccessDenied;
            try open_file.disk_fs.resizeInode(open_file.inode_index, size);
        },
        else => return error.BadFd,
    }
}

/// Closes a task-local descriptor and releases any backing open-file slot.
pub fn closeFile(ptask: *task.Task, fd: u32) FiledescError!void {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    try slot.close(); // will also set the slot to empty
}

pub fn validateOpenFlags(flags: u32) vfs.FsError!u32 {
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

fn syntheticCharStat(access_flags: u32) Stat {
    return .{
        .inode = 0,
        .size = 0,
        .blocks = 0,
        .blksize = 1,
        .nlink = 1,
        .kind = .CharDevice,
        .flags = access_flags | abi.STAT_FLAG_SYNTHETIC,
    };
}

fn buildOpenFileStatFlags(open_file: *const vfs.OpenFile) u8 {
    var flags: u8 = 0;
    if (open_file.readable) flags |= abi.STAT_FLAG_READABLE;
    if (open_file.writable) flags |= abi.STAT_FLAG_WRITABLE;
    if (open_file.append) flags |= abi.STAT_FLAG_APPEND;
    return flags;
}
