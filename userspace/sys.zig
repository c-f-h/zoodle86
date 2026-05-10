pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;
pub const FAIL: u32 = 0xFFFF_FFFF;

/// Stable 32-bit ABI slice representation used for receiving argv at process startup.
/// Must match the definition in kernel/task.zig.
pub const AbiSlice = extern struct {
    ptr: u32,
    len: u32,

    fn toSlice(slice: *const AbiSlice, comptime T: type) []const T {
        return @as([*]const T, @ptrFromInt(slice.ptr))[0..slice.len];
    }

    fn fromSlice(comptime T: type, s: []const T) AbiSlice {
        return .{
            .ptr = @intFromPtr(s.ptr),
            .len = @intCast(s.len),
        };
    }
};

/// Maximum number of arguments supported in the argv startup array.
pub const MAX_ARGV_COUNT = 128;

/// Selects the access mode encoded in userspace open flags.
pub const FileOpenMode = enum(u2) {
    ReadOnly = 0,
    WriteOnly = 1,
    ReadWrite = 2,
};

/// Encodes the userspace `open` syscall flags in a typed form.
pub const FileOpenFlags = packed struct(u32) {
    open_mode: FileOpenMode = .ReadOnly, // 0-1
    reserved0: u4 = 0, // 2-5
    create: bool = false, // 6
    reserved1: u2 = 0, // 7-8
    truncate: bool = false, // 9
    append: bool = false, // 10
    reserved2: u21 = 0, // 11-31
};

/// Selects the reference point used by the `lseek` syscall.
pub const SeekWhence = enum(u32) {
    Set = 0, // offset from beginning of file
    Cur = 1, // offset from current position
    End = 2, // offset from end of file
};

/// Categorizes the underlying object described by `Stat`.
pub const FileKind = enum(u32) {
    Unknown = 0,
    Regular = 1,
    Directory = 2,
    CharDevice = 3,
    Pipe = 4,
};

pub const STAT_FLAG_READABLE: u32 = 1 << 0;
pub const STAT_FLAG_WRITABLE: u32 = 1 << 1;
pub const STAT_FLAG_APPEND: u32 = 1 << 2;
pub const STAT_FLAG_SYNTHETIC: u32 = 1 << 3;

/// Stable stat-like file metadata returned by `stat` and `fstat`.
pub const Stat = extern struct {
    inode: u32,
    size: u32,
    blocks: u32,
    blksize: u32,
    nlink: u32,
    kind: FileKind,
    flags: u32,
};

const Syscall = enum(u32) {
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Stat = 4,
    Fstat = 5,
    Seek = 8,
    Brk = 12, // change program heap size
    Pipe = 22,
    Yield = 24,
    GetPid = 39,
    Exit = 60,
    WaitPid = 61,
    Mkdir = 83,
    Rmdir = 84,
    Link = 86,
    Unlink = 87,
    Ftruncate = 93,
    Spawn = 1001,
    SetChildReap = 1002,
    KShell = 1003,
    GetCursor = 1004,
};

// Virtual key codes delivered in KeyEvent.keycode
pub const VK_BACKSPACE: u16 = 0x0E;
pub const VK_TAB: u16 = 0x0F;
pub const VK_ENTER: u16 = 0x1C;
pub const VK_LCTRL: u16 = 0x1D;
pub const VK_LSHIFT: u16 = 0x2A;
pub const VK_RSHIFT: u16 = 0x36;
pub const VK_LALT: u16 = 0x38;
pub const VK_ESC: u16 = 0x01;
pub const VK_A: u16 = 0x1E;
pub const VK_B: u16 = 0x30;
pub const VK_D: u16 = 0x20;
pub const VK_E: u16 = 0x12;
pub const VK_F: u16 = 0x21;
pub const VK_K: u16 = 0x25;
pub const VK_U: u16 = 0x16;
// Extended keys (top byte 0xE0)
pub const VK_EXTENDED: u16 = 0xE000;
pub const VK_UP: u16 = VK_EXTENDED | 0x48;
pub const VK_DOWN: u16 = VK_EXTENDED | 0x50;
pub const VK_LEFT: u16 = VK_EXTENDED | 0x4B;
pub const VK_RIGHT: u16 = VK_EXTENDED | 0x4D;
pub const VK_HOME: u16 = VK_EXTENDED | 0x47;
pub const VK_END: u16 = VK_EXTENDED | 0x4F;
pub const VK_DELETE: u16 = VK_EXTENDED | 0x53;

// Modifier flags in KeyEvent.modifiers
pub const MOD_SHIFT: u8 = 0x01;
pub const MOD_ALT: u8 = 0x02;
pub const MOD_CTRL: u8 = 0x04;

/// A compact key event delivered by read(STDIN).  Exactly 4 bytes; layout matches
/// kernel/keyboard.zig StdinKeyEvent.
pub const KeyEvent = extern struct {
    keycode: u16,
    modifiers: u8,
    ascii: u8,
};

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

inline fn syscall(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        : [nr] "{eax}" (@intFromEnum(nr)),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
        : .{ .memory = true });
}

/// Emits a Bochs magic breakpoint instruction for low-level debugging.
pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

/// Writes a byte slice to a userspace-visible file descriptor.
pub fn write(fd: u32, buf: []const u8) u32 {
    return syscall(.Write, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

/// Writes the full slice to a userspace-visible file descriptor.
/// Returns false if the syscall fails or makes no forward progress.
pub fn writeAll(fd: u32, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const chunk = write(fd, data[written..]);
        if (chunk == FAIL or chunk == 0) return false;
        written += @intCast(chunk);
    }
    return true;
}

/// Reads bytes from a userspace-visible file descriptor into a buffer.
pub fn read(fd: u32, buf: []u8) u32 {
    return syscall(.Read, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

/// Opens a filesystem path with the provided userspace flags.
pub fn open(path: []const u8, flags: FileOpenFlags) u32 {
    return syscall(.Open, @intFromPtr(path.ptr), @intCast(path.len), @bitCast(flags));
}

/// Closes a userspace-visible file descriptor.
pub fn close(fd: u32) u32 {
    return syscall(.Close, fd, 0, 0);
}

/// Reads metadata for a filesystem path into `out`.
pub fn stat(path: []const u8, out: *Stat) u32 {
    return syscall(.Stat, @intFromPtr(&AbiSlice.fromSlice(u8, path)), @intFromPtr(out), 0);
}

/// Reads metadata for an open file descriptor into `out`.
pub fn fstat(fd: u32, out: *Stat) u32 {
    return syscall(.Fstat, fd, @intFromPtr(out), 0);
}

/// Repositions a userspace-visible file descriptor and returns the new offset.
pub fn lseek(fd: u32, offset: i32, whence: SeekWhence) u32 {
    return syscall(.Seek, fd, @bitCast(offset), @intFromEnum(whence));
}

/// Resizes a filesystem-backed file descriptor to the requested byte length.
pub fn ftruncate(fd: u32, length: u32) u32 {
    return syscall(.Ftruncate, fd, length, 0);
}

/// Unlinks a filesystem path by name.
pub fn unlink(path: []const u8) u32 {
    return syscall(.Unlink, @intFromPtr(path.ptr), @intCast(path.len), 0);
}

/// Returns the current process identifier.
pub fn getpid() u32 {
    return syscall(.GetPid, 0, 0, 0);
}

/// Returns the stdout console cursor position packed as (row << 16) | col (both 0-indexed).
pub fn getCursor() struct { row: u32, col: u32 } {
    const packed_pos = syscall(.GetCursor, 0, 0, 0);
    return .{ .row = packed_pos >> 16, .col = packed_pos & 0xFFFF };
}

/// Reads exactly one KeyEvent (4 bytes) from stdin, blocking until a key is pressed.
pub fn readKey() KeyEvent {
    var bytes: [@sizeOf(KeyEvent)]u8 = undefined;
    _ = read(STDIN, &bytes);
    return @bitCast(bytes);
}

/// A (dst, src) fd-index pair for remapping parent file descriptors into the child at spawn time.
/// `child.fd[dst]` will be set to a copy of `parent.fd[src]`.
pub const FdRemap = extern struct {
    dst: u32,
    src: u32,
};

/// Options for the spawn syscall. Pass a pointer to this struct as the second argument to spawnvOpts/spawnOpts.
pub const SpawnOpts = extern struct {
    fd_remaps: AbiSlice,
};

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
    const pid = syscall(.Spawn, @intFromPtr(&argv_abi), 0, 0);
    if (pid == FAIL) {
        return error.SpawnFailed;
    }
    return pid;
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
    const pid = syscall(.Spawn, @intFromPtr(&argv_abi), @intFromPtr(&opts), 0);
    if (pid == FAIL) return error.SpawnFailed;
    return pid;
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
    const result = syscall(.Pipe, @intFromPtr(&fds_slice), 0, 0);
    if (result == FAIL) {
        return error.SyscallFailed;
    }
    return .{ fds[0], fds[1] };
}

/// Voluntarily yields execution to the scheduler.
pub fn yield() void {
    _ = syscall(.Yield, 0, 0, 0);
}

/// Waits for the child with the given PID to exit and returns its exit status.
/// Returns FAIL if the PID is not a child of the calling process.
pub fn waitpid(pid: u32) u32 {
    return syscall(.WaitPid, pid, 0, 0);
}

pub fn mkdir(path: []const u8) !void {
    const path_abi = AbiSlice.fromSlice(u8, path);
    if (syscall(.Mkdir, @intFromPtr(&path_abi), 0, 0) == FAIL) {
        return error.MkdirFailed;
    }
}

/// Removes a directory by name.
pub fn rmdir(path: []const u8) u32 {
    const path_abi = AbiSlice.fromSlice(u8, path);
    return syscall(.Rmdir, @intFromPtr(&path_abi), 0, 0);
}

/// Creates a new hard link from `new_path` to the existing regular file at `old_path`.
pub fn link(old_path: []const u8, new_path: []const u8) u32 {
    const old_path_abi = AbiSlice.fromSlice(u8, old_path);
    const new_path_abi = AbiSlice.fromSlice(u8, new_path);
    return syscall(.Link, @intFromPtr(&old_path_abi), @intFromPtr(&new_path_abi), 0);
}

/// Marks the calling process so all its children are auto-reaped on exit
/// instead of becoming zombies. After this call, waitpid on children will fail.
pub fn setChildReap() void {
    _ = syscall(.SetChildReap, 0, 0, 0);
}

/// Executes a kernel shell command using the calling task's console.
/// The command string is passed as a slice and will be interpreted by the kernel shell.
/// Returns 0 on success, FAIL on error.
pub fn kshell(cmdline: []const u8) u32 {
    const cmdline_abi = AbiSlice.fromSlice(u8, cmdline);
    return syscall(.KShell, @intFromPtr(&cmdline_abi), 0, 0);
}

/// Terminates the current process with the provided exit code.
pub fn exit(exitcode: u32) noreturn {
    _ = syscall(.Exit, exitcode, 0, 0);
    unreachable;
}

///////////////////////////////////////////////////////////////////////////////

fn sys_brk(addr: usize) usize {
    return syscall(.Brk, addr, 0, 0);
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
    const result = sys_brk(new_brk);
    if (result == FAIL) {
        return error.OutOfMemory;
    }
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
        _ = write(STDOUT, "Runtime error: ");
        _ = write(STDOUT, @errorName(err));
        _ = write(STDOUT, "\n");
        exit(1);
    };
    exit(0);
}
