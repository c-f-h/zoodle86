pub export fn _start() void {
    _ = asm volatile (
        \\mov $1, %eax
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        :
        : .{ .eax = true });
}
