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
};

/// Maximum number of arguments supported in the argv startup array.
pub const MAX_ARGV_COUNT = 128;

const FileOpenMode = enum(u2) {
    ReadOnly = 0,
    WriteOnly = 1,
    ReadWrite = 2,
};

const FileOpenFlags = packed struct(u32) {
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

const Syscall = enum(u32) {
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Seek = 8,
    Brk = 12, // change program heap size
    Yield = 24,
    GetPid = 39,
    Exit = 60,
    WaitPid = 61,
    Unlink = 87,
    Spawn = 1001,
    SetChildReap = 1002,
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

/// Repositions a userspace-visible file descriptor and returns the new offset.
pub fn lseek(fd: u32, offset: i32, whence: SeekWhence) u32 {
    return syscall(.Seek, fd, @bitCast(offset), @intFromEnum(whence));
}

/// Unlinks a filesystem path by name.
pub fn unlink(path: []const u8) u32 {
    return syscall(.Unlink, @intFromPtr(path.ptr), @intCast(path.len), 0);
}

/// Returns the current process identifier.
pub fn getpid() u32 {
    return syscall(.GetPid, 0, 0, 0);
}

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

/// Voluntarily yields execution to the scheduler.
pub fn yield() void {
    _ = syscall(.Yield, 0, 0, 0);
}

/// Waits for the child with the given PID to exit and returns its exit status.
/// Returns FAIL if the PID is not a child of the calling process.
pub fn waitpid(pid: u32) u32 {
    return syscall(.WaitPid, pid, 0, 0);
}

/// Marks the calling process so all its children are auto-reaped on exit
/// instead of becoming zombies. After this call, waitpid on children will fail.
pub fn setChildReap() void {
    _ = syscall(.SetChildReap, 0, 0, 0);
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
