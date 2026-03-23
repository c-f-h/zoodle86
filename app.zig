const keyboard = @import("keyboard.zig");

/// Application context structure
pub const AppContext = struct {
    name: [*:0]const u8,
    key_event_handler: ?*const fn (*AppContext, *const keyboard.KeyEvent) u32,
    done: bool = false,
};
