inline fn syscall(nr: u32, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\mov %[nr], %%eax
        \\mov %[a1], %%ebx
        \\mov %[a2], %%ecx
        \\mov %[a3], %%edx
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        : [nr] "r" (nr),
          [a1] "r" (arg1),
          [a2] "r" (arg2),
          [a3] "r" (arg3),
        : .{ .ebx = true, .ecx = true, .edx = true });
}

pub fn exit(exitcode: u32) noreturn {
    _ = syscall(60, exitcode, 0, 0);
    unreachable;
}

pub fn write(fd: u32, buf: []const u8) u32 {
    return syscall(1, fd, @intFromPtr(buf.ptr), buf.len);
}

pub export fn _start() void {
    _ = write(1, "Hello, world!\n");
    exit(0);
}
