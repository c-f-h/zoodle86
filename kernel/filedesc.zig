const console = @import("console.zig");
const fs = @import("fs.zig");
const std = @import("std");
const task = @import("task.zig");
const pipe = @import("pipe.zig");
const keyboard = @import("keyboard.zig");
const kernel = @import("kernel.zig");
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

    pub fn dupe(self: *FileDesc) FileDesc {
        switch (self.*) {
            .empty => return .{ .empty = {} },
            .stdin => return self.*,
            .stdout => return self.*,
            .stderr => return self.*,
            .file => |file_index| {
                const open_file = getOpenFile(file_index);
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
        }
    }

    /// Closes a descriptor if it is open and always leaves the slot empty.
    pub fn closeIfOpen(self: *FileDesc) void {
        self.close() catch {};
        self.* = .empty;
    }

    /// Reads bytes from a descriptor into the provided buffer.
    pub fn read(self: *FileDesc, dest: []u8) (fs.FsError || error{ BadFd, AccessDenied, OutOfMemory })!usize {
        switch (self.*) {
            .stdin => {
                // Each read delivers exactly one 4-byte StdinKeyEvent; block until one is available.
                if (dest.len < @sizeOf(keyboard.StdinKeyEvent)) return error.BadFd;
                var ev: keyboard.StdinKeyEvent = undefined;
                while (!keyboard.tryPopStdinKeyEvent(&ev)) {
                    try task.getCurrentTask().waitInQueue(kernel.getStdinWaiters());
                    _ = kernel.kernel_yield();
                }
                @memcpy(dest[0..@sizeOf(keyboard.StdinKeyEvent)], std.mem.asBytes(&ev));
                return @sizeOf(keyboard.StdinKeyEvent);
            },
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
                if (pp.full()) {
                    try task.getCurrentTask().waitInQueue(&pp.write_waiters);
                    _ = kernel.kernel_yield();
                }
                return pp.write(src);
            },
            else => return error.BadFd,
        }
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

pub const FiledescError = fs.WriteFileError || error{
    AccessDenied,
    BadFd,
    FileInUse,
    InvalidFlags,
    InvalidSeek,
    ProcessFileTableFull,
    SystemFileTableFull,
};

pub const Stat = abi.Stat;
const DirEntry = abi.DirEntry;
const SeekWhence = abi.SeekWhence;

const OpenFile = struct {
    in_use: u8 = 0, // Reference counter
    disk_fs: *fs.FileSystem = undefined,
    inode_index: fs.InodeT = 0,
    offset: u32 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,
};

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;

/// Opens or creates a filesystem-backed descriptor, not bound to a particular task.
pub fn openFileDesc(disk_fs: *fs.FileSystem, path: []const u8, flags: u32) FiledescError!FileDesc {
    const access_mode = try validateOpenFlags(flags);
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;
    const inode_index = if (path.len == 0 or std.mem.eql(u8, path, "/"))
        fs.ROOT_INODE_INDEX
    else blk: {
        break :blk disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, path) catch |err| switch (err) {
            error.FileNotFound => blk2: {
                if ((flags & O_CREAT) == 0) return error.FileNotFound;

                const split = fs.splitPath(path);
                const parent_inode = try disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, split.dir);
                break :blk2 try disk_fs.createFile(parent_inode, split.name);
            },
            else => return err,
        };
    };

    if ((flags & O_TRUNC) != 0) {
        try disk_fs.resizeInode(inode_index, 0);
    }

    open_files[open_index] = .{
        .in_use = 1,
        .disk_fs = disk_fs,
        .inode_index = inode_index,
        .offset = 0,
        .readable = access_mode != O_WRONLY,
        .writable = access_mode != O_RDONLY,
        .append = (flags & O_APPEND) != 0,
    };
    return FileDesc{ .file = @truncate(open_index) };
}

/// Opens or creates a filesystem-backed descriptor for a task.
pub fn openFile(disk_fs: *fs.FileSystem, ptask: *task.Task, path: []const u8, flags: u32) FiledescError!u32 {
    const fd = ptask.findFreeFd() orelse return error.ProcessFileTableFull;
    const filedesc = try openFileDesc(disk_fs, path, flags);
    ptask.setFdSlot(fd, filedesc);
    return fd;
}

/// Returns stat-like metadata for a filesystem path.
pub fn statPath(disk_fs: *const fs.FileSystem, path: []const u8) FiledescError!Stat {
    return try disk_fs.statPath(path);
}

/// Returns stat-like metadata for a task-owned file descriptor.
pub fn statFd(ptask: *task.Task, fd: u32) FiledescError!Stat {
    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.*) {
        .stdin => syntheticCharStat(fs.STAT_FLAG_READABLE),
        .stdout, .stderr => syntheticCharStat(fs.STAT_FLAG_WRITABLE),
        .file => |file_index| blk: {
            const open_file = getOpenFile(file_index);
            var stat = try open_file.disk_fs.statInode(open_file.inode_index);
            stat.flags = buildOpenFileStatFlags(open_file);
            break :blk stat;
        },
        .pipe => |pipe_info| blk: {
            const pp = pipe_info.handle;
            var flags = fs.STAT_FLAG_SYNTHETIC;
            if (pipe_info.writable) {
                flags |= fs.STAT_FLAG_WRITABLE;
            } else {
                flags |= fs.STAT_FLAG_READABLE;
            }
            break :blk .{
                .inode = 0,
                .size = @intCast(pp.buffer.size),
                .blocks = 0,
                .blksize = @intCast(pp.buffer.buf.len),
                .nlink = 1,
                .kind = .Pipe,
                .flags = flags,
            };
        },
        else => error.BadFd,
    };
}

/// Unlinks a filesystem path unless it is still referenced by an open descriptor.
pub fn unlinkFile(disk_fs: *fs.FileSystem, path: []const u8) FiledescError!void {
    const parent_inode, const index, const entry = try disk_fs.walkPathToDirEntry(fs.ROOT_INODE_INDEX, path);

    if (isInodeOpen(entry.inode_index)) return error.FileInUse;
    try disk_fs.deleteFile(parent_inode, index);
}

/// Creates a new hard link to an existing regular file.
pub fn linkFile(disk_fs: *fs.FileSystem, old_path: []const u8, new_path: []const u8) FiledescError!void {
    const target_inode_index = try disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, old_path);
    const split = fs.splitPath(new_path);
    const parent_inode_index = try disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, split.dir);
    try disk_fs.createLink(parent_inode_index, split.name, target_inode_index);
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

/// Enumerates directory entries from a task-owned directory descriptor into a fixed-size ABI buffer.
pub fn readDirEntries(ptask: *task.Task, fd: u32, dest: []DirEntry) FiledescError!usize {
    if (dest.len == 0) return 0;

    const slot = ptask.getFdSlot(fd) orelse return error.BadFd;
    return switch (slot.*) {
        .file => |file_index| blk: {
            const open_file = getOpenFile(file_index);
            const dir_stat = try open_file.disk_fs.statInode(open_file.inode_index);
            if (dir_stat.kind != .Directory) return error.NotADirectory;

            const raw_entry_size = @sizeOf(fs.DirectoryEntry);
            if (open_file.offset % raw_entry_size != 0) return error.InvalidSeek;

            var dir_index: usize = @intCast(open_file.offset / raw_entry_size);
            var out_count: usize = 0;

            while (dir_index < fs.DIRECTORY_ENTRY_COUNT and out_count < dest.len) : (dir_index += 1) {
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

            break :blk out_count;
        },
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
        if (open_file.in_use == 0) return index;
    }
    return null;
}

fn getOpenFile(index: u8) *OpenFile {
    if (index >= open_files.len) @panic("invalid open file index");
    if (open_files[index].in_use == 0) @panic("open file index not in use");
    return &open_files[index];
}

fn closeOpenFile(index: u8) void {
    if (index >= open_files.len) @panic("invalid open file index");
    if (open_files[index].in_use == 0) @panic("open file index not in use");
    open_files[index].in_use -= 1;
    if (open_files[index].in_use == 0) {
        open_files[index] = .{};
    }
}

fn syntheticCharStat(access_flags: u32) Stat {
    return .{
        .inode = 0,
        .size = 0,
        .blocks = 0,
        .blksize = 1,
        .nlink = 1,
        .kind = .CharDevice,
        .flags = access_flags | fs.STAT_FLAG_SYNTHETIC,
    };
}

fn buildOpenFileStatFlags(open_file: *const OpenFile) u32 {
    var flags: u32 = 0;
    if (open_file.readable) flags |= fs.STAT_FLAG_READABLE;
    if (open_file.writable) flags |= fs.STAT_FLAG_WRITABLE;
    if (open_file.append) flags |= fs.STAT_FLAG_APPEND;
    return flags;
}

fn isInodeOpen(inode_index: fs.InodeT) bool {
    for (&open_files) |open_file| {
        if (open_file.in_use != 0 and open_file.inode_index == inode_index) {
            return true;
        }
    }
    return false;
}
