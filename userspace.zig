inline fn syscall(nr: u32, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        : [nr] "{eax}" (nr),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
        : .{ .memory = true });
}

pub fn exit(exitcode: u32) noreturn {
    _ = syscall(60, exitcode, 0, 0);
    unreachable;
}

pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

pub fn write(fd: u32, buf: []const u8) u32 {
    return syscall(1, fd, @intFromPtr(buf.ptr), buf.len);
}

const STDOUT = 1;

pub export fn _start() void {
    _ = write(STDOUT, "Hello, world!\n");
    exit(0);
}
