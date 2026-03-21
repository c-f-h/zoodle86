const console = @import("console.zig");
const readline = @import("readline.zig");
const keyboard = @import("keyboard.zig");
const app_keylog = @import("app_keylog.zig");

const c = @cImport({
    @cInclude("app.h");
});

const VGA_ATTR: u8 = 0x07;

// External interrupt setup from interrupts.asm
extern fn interrupts_init() void;

// Global application context
var cur_app: c.struct_app_context = undefined;

/// Get the current app context
export fn get_cur_app() [*c]c.struct_app_context {
    return &cur_app;
}

/// Keyboard event consumer called by interrupt handler
export fn consume_key_event(event: [*c]const c.struct_key_event) callconv(.c) void {
    if (cur_app.key_event_handler != null) {
        _ = cur_app.key_event_handler.?(event);
    }
}

comptime {
    // Force semantic analysis of imported modules so their `pub export fn`
    // declarations are emitted into this translation unit.
    _ = console;
    _ = readline;
    _ = keyboard;
    _ = app_keylog;
}

/// Kernel entry point
export fn _start() void {
    console.console_init(VGA_ATTR);
    console.puts("Hello from protected mode.\n");
    console.puts("Press a key.\n\n");

    interrupts_init();

    _ = app_keylog.app_keylog_init(@ptrCast(&cur_app));

    while (true) {
        keyboard.keyboard_poll();
    }
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = message;
    _ = trace;
    _ = return_address;
    while (true) {}
}
