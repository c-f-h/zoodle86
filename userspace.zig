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

pub export fn _start() void {
    while (true) {
        _ = syscall(1, 0, 0, 0);
    }
}
