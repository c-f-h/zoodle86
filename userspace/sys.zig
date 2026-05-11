const abi = @import("abi");

pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;
pub const INVALID_FD: u32 = 0xFFFF_FFFF;

pub const AbiSlice = abi.AbiSlice;
pub const MAX_ARGV_COUNT = abi.MAX_ARGV_COUNT;
pub const Errno = abi.Errno;
pub const FileOpenMode = abi.FileOpenMode;
pub const FileOpenFlags = abi.FileOpenFlags;
pub const SeekWhence = abi.SeekWhence;
pub const FileKind = abi.FileKind;
pub const DirEntry = abi.DirEntry;
pub const STAT_FLAG_READABLE = abi.STAT_FLAG_READABLE;
pub const STAT_FLAG_WRITABLE = abi.STAT_FLAG_WRITABLE;
pub const STAT_FLAG_APPEND = abi.STAT_FLAG_APPEND;
pub const STAT_FLAG_SYNTHETIC = abi.STAT_FLAG_SYNTHETIC;
pub const Stat = abi.Stat;
pub const DIRENT_NAME_MAX = abi.DIRENT_NAME_MAX;
const Syscall = abi.Syscall;
pub const VK_BACKSPACE = abi.VK_BACKSPACE;
pub const VK_TAB = abi.VK_TAB;
pub const VK_ENTER = abi.VK_ENTER;
pub const VK_LCTRL = abi.VK_LCTRL;
pub const VK_LSHIFT = abi.VK_LSHIFT;
pub const VK_RSHIFT = abi.VK_RSHIFT;
pub const VK_LALT = abi.VK_LALT;
pub const VK_ESC = abi.VK_ESC;
pub const VK_SPACE = abi.VK_SPACE;
pub const VK_A = abi.VK_A;
pub const VK_B = abi.VK_B;
pub const VK_C = abi.VK_C;
pub const VK_D = abi.VK_D;
pub const VK_E = abi.VK_E;
pub const VK_F = abi.VK_F;
pub const VK_G = abi.VK_G;
pub const VK_H = abi.VK_H;
pub const VK_I = abi.VK_I;
pub const VK_J = abi.VK_J;
pub const VK_K = abi.VK_K;
pub const VK_L = abi.VK_L;
pub const VK_M = abi.VK_M;
pub const VK_N = abi.VK_N;
pub const VK_O = abi.VK_O;
pub const VK_P = abi.VK_P;
pub const VK_Q = abi.VK_Q;
pub const VK_R = abi.VK_R;
pub const VK_S = abi.VK_S;
pub const VK_T = abi.VK_T;
pub const VK_U = abi.VK_U;
pub const VK_V = abi.VK_V;
pub const VK_W = abi.VK_W;
pub const VK_X = abi.VK_X;
pub const VK_Y = abi.VK_Y;
pub const VK_Z = abi.VK_Z;
pub const VK_EXTENDED = abi.VK_EXTENDED;
pub const VK_UP = abi.VK_UP;
pub const VK_DOWN = abi.VK_DOWN;
pub const VK_LEFT = abi.VK_LEFT;
pub const VK_RIGHT = abi.VK_RIGHT;
pub const VK_HOME = abi.VK_HOME;
pub const VK_END = abi.VK_END;
pub const VK_DELETE = abi.VK_DELETE;
pub const MOD_SHIFT = abi.MOD_SHIFT;
pub const MOD_ALT = abi.MOD_ALT;
pub const MOD_CTRL = abi.MOD_CTRL;
pub const KeyEvent = abi.KeyEvent;
pub const IOCTL_TTY_SET_MODE = abi.IOCTL_TTY_SET_MODE;
pub const TTY_MODE_CANONICAL = abi.TTY_MODE_CANONICAL;
pub const TTY_MODE_RAW = abi.TTY_MODE_RAW;

pub const SyscallError = error{
    ENOENT,
    EIO,
    E2BIG,
    EBADF,
    EAGAIN,
    ENOMEM,
    EACCES,
    EFAULT,
    EBUSY,
    EEXIST,
    ENOTDIR,
    EISDIR,
    EINVAL,
    ENFILE,
    EMFILE,
    ENOSPC,
    ENOTEMPTY,
};

pub const WriteAllError = SyscallError || error{WriteZero};

/// Provides the freestanding memcpy symbol expected by the userspace binary.
pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

/// Provides the freestanding memset symbol expected by the userspace binary.
pub export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = val;
    }
    return dest;
}

fn mapErrno(errno: Errno) SyscallError {
    return switch (errno) {
        .ENOENT => error.ENOENT,
        .EIO => error.EIO,
        .E2BIG => error.E2BIG,
        .EBADF => error.EBADF,
        .EAGAIN => error.EAGAIN,
        .ENOMEM => error.ENOMEM,
        .EACCES => error.EACCES,
        .EFAULT => error.EFAULT,
        .EBUSY => error.EBUSY,
        .EEXIST => error.EEXIST,
        .ENOTDIR => error.ENOTDIR,
        .EISDIR => error.EISDIR,
        .EINVAL => error.EINVAL,
        .ENFILE => error.ENFILE,
        .EMFILE => error.EMFILE,
        .ENOSPC => error.ENOSPC,
        .ENOTEMPTY => error.ENOTEMPTY,
        .Success, _ => error.EIO,
    };
}

inline fn rawSyscall(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) struct { value: u32, errno: u32 } {
    var errno: u32 = 0;
    const value = asm volatile (
        \\int $0x80
        \\mov %%ecx, (%[errno_ptr])
        : [ret] "={eax}" (-> u32),
        : [nr] "{eax}" (@intFromEnum(nr)),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
          [errno_ptr] "{edi}" (@intFromPtr(&errno)),
        : .{ .memory = true, .eax = true, .ebx = true, .ecx = true, .edx = true, .edi = true });
    return .{ .value = value, .errno = errno };
}

inline fn syscall(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) SyscallError!u32 {
    const result = rawSyscall(nr, arg1, arg2, arg3);
    const errno: Errno = @enumFromInt(result.errno);
    if (errno != .Success) return mapErrno(errno);
    return result.value;
}

/// Emits a Bochs magic breakpoint instruction for low-level debugging.
pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

/// Writes a byte slice to a userspace-visible file descriptor.
pub fn write(fd: u32, buf: []const u8) SyscallError!u32 {
    return syscall(.Write, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

/// Writes the full slice to a userspace-visible file descriptor.
/// Returns `error.WriteZero` if the writer makes no forward progress.
pub fn writeAll(fd: u32, data: []const u8) WriteAllError!void {
    var written: usize = 0;
    while (written < data.len) {
        const chunk = try write(fd, data[written..]);
        if (chunk == 0) return error.WriteZero;
        written += @intCast(chunk);
    }
}

/// Reads bytes from a userspace-visible file descriptor into a buffer.
pub fn read(fd: u32, buf: []u8) SyscallError!u32 {
    return syscall(.Read, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

/// Opens a filesystem path with the provided userspace flags.
pub fn open(path: []const u8, flags: FileOpenFlags) SyscallError!u32 {
    return syscall(.Open, @intFromPtr(path.ptr), @intCast(path.len), @bitCast(flags));
}

/// Closes a userspace-visible file descriptor.
pub fn close(fd: u32) SyscallError!void {
    _ = try syscall(.Close, fd, 0, 0);
}

/// Reads metadata for a filesystem path into `out`.
pub fn stat(path: []const u8, out: *Stat) SyscallError!void {
    _ = try syscall(.Stat, @intFromPtr(&AbiSlice.fromSlice(u8, path)), @intFromPtr(out), 0);
}

/// Reads metadata for an open file descriptor into `out`.
pub fn fstat(fd: u32, out: *Stat) SyscallError!void {
    _ = try syscall(.Fstat, fd, @intFromPtr(out), 0);
}

/// Repositions a userspace-visible file descriptor and returns the new offset.
pub fn lseek(fd: u32, offset: i32, whence: SeekWhence) SyscallError!u32 {
    return syscall(.Lseek, fd, @bitCast(offset), @intFromEnum(whence));
}

/// Resizes a filesystem-backed file descriptor to the requested byte length.
pub fn ftruncate(fd: u32, length: u32) SyscallError!void {
    _ = try syscall(.Ftruncate, fd, length, 0);
}

/// Reads a batch of fixed-size directory entries from an open directory descriptor.
pub fn getdents(fd: u32, entries: []DirEntry) SyscallError!u32 {
    const entry_slice = AbiSlice.fromSlice(DirEntry, entries);
    return syscall(.GetDents, fd, @intFromPtr(&entry_slice), 0);
}

/// Reads the next directory entry from an open directory descriptor.
/// Returns `false` on end-of-directory.
pub fn readdir(fd: u32, out: *DirEntry) SyscallError!bool {
    var entry_buf: [1]DirEntry = undefined;
    const count = try getdents(fd, &entry_buf);
    if (count == 0) return false;
    out.* = entry_buf[0];
    return true;
}

/// Unlinks a filesystem path by name.
pub fn unlink(path: []const u8) SyscallError!void {
    _ = try syscall(.Unlink, @intFromPtr(path.ptr), @intCast(path.len), 0);
}

/// Returns the current process identifier.
pub fn getpid() u32 {
    return syscall(.GetPid, 0, 0, 0) catch unreachable;
}

/// Returns the stdout console cursor position packed as (row << 16) | col (both 0-indexed).
pub fn getCursor() struct { row: u32, col: u32 } {
    const packed_pos = syscall(.GetCursor, 0, 0, 0) catch unreachable;
    return .{ .row = packed_pos >> 16, .col = packed_pos & 0xFFFF };
}

/// Applies a device-specific ioctl request to an open file descriptor.
pub fn ioctl(fd: u32, command: u32, arg: u32) SyscallError!u32 {
    return syscall(.Ioctl, fd, command, arg);
}

pub const FdRemap = abi.FdRemap;
pub const SpawnOpts = abi.SpawnOpts;

/// Spawns a userspace executable from a full argv slice where argv[0] names the program.
pub fn spawnv(argv: []const []const u8) !u32 {
    if (argv.len > MAX_ARGV_COUNT) return error.TooManyArgs;

    var argv_abi_storage: [MAX_ARGV_COUNT]AbiSlice = undefined;
    for (argv, 0..) |arg, i| {
        argv_abi_storage[i] = .{
            .ptr = @intFromPtr(arg.ptr),
            .len = @intCast(arg.len),
        };
    }

    const argv_abi = AbiSlice{
        .ptr = if (argv.len == 0) 0 else @intFromPtr(&argv_abi_storage[0]),
        .len = @intCast(argv.len),
    };
    return try syscall(.Spawn, @intFromPtr(&argv_abi), 0, 0);
}

/// Spawns a userspace executable, prepending the command name as argv[0].
pub fn spawn(path: []const u8, args: []const []const u8) !u32 {
    if (args.len + 1 > MAX_ARGV_COUNT) return error.TooManyArgs;

    var argv_buf: [MAX_ARGV_COUNT][]const u8 = undefined;
    argv_buf[0] = path;
    for (args, 0..) |arg, i| {
        argv_buf[i + 1] = arg;
    }
    return spawnv(argv_buf[0 .. args.len + 1]);
}

/// Spawns an executable from a full argv slice with optional fd remapping.
/// `fd_remaps` is a slice of (dst, src) pairs; for each pair, `child.fd[dst]`
/// is set to a copy of the calling process's `fd[src]`.
pub fn spawnvOpts(argv: []const []const u8, fd_remaps: []const FdRemap) !u32 {
    if (argv.len > MAX_ARGV_COUNT) return error.TooManyArgs;

    var argv_abi_storage: [MAX_ARGV_COUNT]AbiSlice = undefined;
    for (argv, 0..) |arg, i| {
        argv_abi_storage[i] = .{
            .ptr = @intFromPtr(arg.ptr),
            .len = @intCast(arg.len),
        };
    }

    const argv_abi = AbiSlice{
        .ptr = if (argv.len == 0) 0 else @intFromPtr(&argv_abi_storage[0]),
        .len = @intCast(argv.len),
    };
    const opts = SpawnOpts{
        .fd_remaps = .{
            .ptr = if (fd_remaps.len == 0) 0 else @intFromPtr(fd_remaps.ptr),
            .len = @intCast(fd_remaps.len),
        },
    };
    return try syscall(.Spawn, @intFromPtr(&argv_abi), @intFromPtr(&opts), 0);
}

/// Spawns an executable, prepending the command name as argv[0], with optional fd remapping.
pub fn spawnOpts(path: []const u8, args: []const []const u8, fd_remaps: []const FdRemap) !u32 {
    if (args.len + 1 > MAX_ARGV_COUNT) return error.TooManyArgs;

    var argv_buf: [MAX_ARGV_COUNT][]const u8 = undefined;
    argv_buf[0] = path;
    for (args, 0..) |arg, i| {
        argv_buf[i + 1] = arg;
    }
    return spawnvOpts(argv_buf[0 .. args.len + 1], fd_remaps);
}

/// Creates a unidirectional pipe and returns `{ read_fd, write_fd }`.
pub fn pipe() !struct { u32, u32 } {
    var fds: [2]u32 = undefined;
    const fds_slice = AbiSlice.fromSlice(u32, &fds);
    _ = try syscall(.Pipe, @intFromPtr(&fds_slice), 0, 0);
    return .{ fds[0], fds[1] };
}

/// Voluntarily yields execution to the scheduler.
pub fn yield() void {
    _ = syscall(.Yield, 0, 0, 0) catch unreachable;
}

/// Duplicates a file descriptor, returning the new fd number.
pub fn dupFd(old_fd: u32) !u32 {
    return try syscall(.DupFd, old_fd, INVALID_FD, 0);
}

// Replace the calling process's file descriptor `new_fd` with a copy of `old_fd`.
pub fn dupFdTo(old_fd: u32, new_fd: u32) !u32 {
    return try syscall(.DupFd, old_fd, new_fd, 0);
}

/// Waits for the child with the given PID to exit and returns its exit status.
pub fn waitpid(pid: u32) SyscallError!u32 {
    return syscall(.WaitPid, pid, 0, 0);
}

/// Creates a directory by name.
pub fn mkdir(path: []const u8) SyscallError!void {
    const path_abi = AbiSlice.fromSlice(u8, path);
    _ = try syscall(.Mkdir, @intFromPtr(&path_abi), 0, 0);
}

/// Removes a directory by name.
pub fn rmdir(path: []const u8) SyscallError!void {
    const path_abi = AbiSlice.fromSlice(u8, path);
    _ = try syscall(.Rmdir, @intFromPtr(&path_abi), 0, 0);
}

/// Renames or moves a file from old_path to new_path, replacing any existing regular file there.
pub fn rename(old_path: []const u8, new_path: []const u8) SyscallError!void {
    const old_path_abi = AbiSlice.fromSlice(u8, old_path);
    const new_path_abi = AbiSlice.fromSlice(u8, new_path);
    _ = try syscall(.Rename, @intFromPtr(&old_path_abi), @intFromPtr(&new_path_abi), 0);
}

/// Creates a new hard link from `new_path` to the existing regular file at `old_path`.
pub fn link(old_path: []const u8, new_path: []const u8) SyscallError!void {
    const old_path_abi = AbiSlice.fromSlice(u8, old_path);
    const new_path_abi = AbiSlice.fromSlice(u8, new_path);
    _ = try syscall(.Link, @intFromPtr(&old_path_abi), @intFromPtr(&new_path_abi), 0);
}

/// Marks the calling process so all its children are auto-reaped on exit
/// instead of becoming zombies. After this call, waitpid on children will fail.
pub fn setChildReap() void {
    _ = syscall(.SetChildReap, 0, 0, 0) catch unreachable;
}

/// Executes a kernel shell command using the calling task's console.
/// The command string is passed as a slice and will be interpreted by the kernel shell.
pub fn kshell(cmdline: []const u8) SyscallError!void {
    const cmdline_abi = AbiSlice.fromSlice(u8, cmdline);
    _ = try syscall(.KShell, @intFromPtr(&cmdline_abi), 0, 0);
}

/// Terminates the current process with the provided exit code.
pub fn exit(exitcode: u32) noreturn {
    _ = syscall(.Exit, exitcode, 0, 0) catch unreachable;
    unreachable;
}

///////////////////////////////////////////////////////////////////////////////

fn sys_brk(addr: usize) usize {
    return @intCast(syscall(.Brk, @intCast(addr), 0, 0) catch unreachable);
}

var old_brk: usize = 0;

fn cachedHeapBreak() usize {
    if (old_brk == 0) {
        old_brk = sys_brk(0);
    }
    return old_brk;
}

/// Returns the current process break without changing the heap size.
pub fn getHeapBreak() usize {
    return cachedHeapBreak();
}

/// Sets the process break to an absolute address and returns the previous break.
pub fn setHeapBreak(new_brk: usize) ![*]u8 {
    const orig_brk = cachedHeapBreak();
    const result = try syscall(.Brk, @intCast(new_brk), 0, 0);
    old_brk = result;
    return @ptrFromInt(orig_brk);
}

/// Adjust the process break by `diff` bytes and return the previous break.
pub fn changeHeapSize(diff: i32) ![*]u8 {
    const orig_brk = cachedHeapBreak();

    const new_brk = if (diff >= 0)
        old_brk + @as(usize, @intCast(diff))
    else
        old_brk - @as(usize, @intCast(-diff));

    _ = try setHeapBreak(new_brk);
    return @ptrFromInt(orig_brk);
}

///////////////////////////////////////////////////////////////////////////////

const root = @import("root"); // import the program being compiled, which must define a `main` function

/// Entry point for userspace processes.
/// The initial stack pointer points to the argv AbiSlice pointer when entering userspace.
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ push %%esp        // pointer to argv AbiSlice
        \\ call argvStartup
        ::: .{ .memory = true });
    unreachable;
}

/// Reconstructs Zig slices from the ABI argv layout placed by the kernel on the
/// initial stack, then calls the root module's main(argv) function.
export fn argvStartup(argv: *const AbiSlice) callconv(.c) noreturn {
    const argc = argv.len;

    var argv_slices: [MAX_ARGV_COUNT][]const u8 = undefined;
    if (argc > 0) {
        const str_abi: [*]const AbiSlice = @ptrFromInt(argv.ptr);
        for (0..argc) |i| {
            argv_slices[i] = str_abi[i].toSlice(u8);
        }
    }

    root.main(argv_slices[0..argc]) catch |err| {
        _ = write(STDOUT, "Runtime error: ") catch {};
        _ = write(STDOUT, @errorName(err)) catch {};
        _ = write(STDOUT, "\n") catch {};
        exit(1);
    };
    exit(0);
}
