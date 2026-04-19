pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

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

const Syscall = enum(u32) {
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Yield = 24,
    GetPid = 39,
    Exit = 60,
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

/// Returns the current process identifier.
pub fn getpid() u32 {
    return syscall(.GetPid, 0, 0, 0);
}

/// Voluntarily yields execution to the scheduler.
pub fn yield() void {
    _ = syscall(.Yield, 0, 0, 0);
}

/// Terminates the current process with the provided exit code.
pub fn exit(exitcode: u32) noreturn {
    _ = syscall(.Exit, exitcode, 0, 0);
    unreachable;
}
