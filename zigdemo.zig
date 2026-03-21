extern fn console_puts(s: [*:0]const u8) void;

pub export fn zig_print_banner() callconv(.c) void {
    console_puts("Hello from Zig.\n");
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = message;
    _ = trace;
    _ = return_address;
    while (true) {}
}
