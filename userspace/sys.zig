pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_CREAT: u32 = 64;
pub const O_TRUNC: u32 = 512;
pub const O_APPEND: u32 = 1024;

const Syscall = enum(u32) {
    read = 0,
    write = 1,
    open = 2,
    close = 3,
    sched_yield = 24,
    getpid = 39,
    exit = 60,
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

inline fn syscallRaw(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        : [nr] "{eax}" (@intFromEnum(nr)),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
        : .{ .memory = true });
}

inline fn syscall(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) i32 {
    return @bitCast(syscallRaw(nr, arg1, arg2, arg3));
}

/// Emits a Bochs magic breakpoint instruction for low-level debugging.
pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

/// Writes a byte slice to a userspace-visible file descriptor.
pub fn write(fd: u32, buf: []const u8) i32 {
    return syscall(.write, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

/// Reads bytes from a userspace-visible file descriptor into a buffer.
pub fn read(fd: u32, buf: []u8) i32 {
    return syscall(.read, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

/// Opens a filesystem path with the provided userspace flags.
pub fn open(path: []const u8, flags: u32) i32 {
    return syscall(.open, @intFromPtr(path.ptr), @intCast(path.len), flags);
}

/// Closes a userspace-visible file descriptor.
pub fn close(fd: u32) i32 {
    return syscall(.close, fd, 0, 0);
}

/// Returns the current process identifier.
pub fn getpid() u32 {
    return @bitCast(syscall(.getpid, 0, 0, 0));
}

/// Voluntarily yields execution to the scheduler.
pub fn yield() void {
    _ = syscall(.sched_yield, 0, 0, 0);
}

/// Terminates the current process with the provided exit code.
pub fn exit(exitcode: u32) noreturn {
    _ = syscall(.exit, exitcode, 0, 0);
    unreachable;
}
