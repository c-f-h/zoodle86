const keyboard = @import("keyboard.zig");

/// Application context structure
pub const AppContext = struct {
    name: [*:0]const u8,
    key_event_handler: ?*const fn (*const keyboard.KeyEvent) u32,
};
