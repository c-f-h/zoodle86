const console = @import("console.zig");
const readline = @import("readline.zig");
const keyboard = @import("keyboard.zig");
const app_keylog = @import("app_keylog.zig");

comptime {
    // Force semantic analysis of imported modules so their `pub export fn`
    // declarations are emitted into this translation unit.
    _ = console;
    _ = readline;
    _ = keyboard;
    _ = app_keylog;
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = message;
    _ = trace;
    _ = return_address;
    while (true) {}
}
