const console = @import("console.zig");
const readline = @import("readline.zig");
const keyboard = @import("keyboard.zig");
const app_keylog = @import("app_keylog.zig");
const app = @import("app.zig");

const VGA_ATTR: u8 = 0x07;

// External interrupt setup from interrupts.asm
extern fn interrupts_init() void;

// Global application context
var cur_app: app.AppContext = undefined;

/// Keyboard event consumer called by interrupt handler
export fn consume_key_event(event: *const keyboard.KeyEvent) callconv(.c) void {
    if (cur_app.key_event_handler != null) {
        _ = cur_app.key_event_handler.?(event);
    }
}

/// Kernel entry point
export fn _start() void {
    console.console_init(VGA_ATTR);
    console.puts("Hello from protected mode.\n");
    console.puts("Press a key.\n\n");

    interrupts_init();

    //_ = app_keylog.app_keylog_init(&cur_app);
    _ = readline.app_launcher_init(&cur_app, 3);

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
