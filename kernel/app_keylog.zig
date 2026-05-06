const kernel = @import("kernel.zig");
const keyboard = @import("keyboard.zig");
const console = @import("console.zig");

const VGA_ATTR: u8 = 0x07;

/// Handle keyboard events and log them to console
fn appKeylogKeyhandler(ctx: ?*anyopaque, ev: *const keyboard.KeyEvent) u32 {
    const con: *console.Console = @ptrCast(@alignCast(ctx.?));
    // Print press/release status
    con.puts(if (ev.pressed != 0) "Down: " else "Up:   ");

    // Print ASCII character if available
    if (ev.ascii != 0) {
        con.putch('\'');
        con.setAttr(0x0f);
        if (ev.ascii == '\n') {
            con.putch('\\');
            con.putch('n');
        } else {
            con.putch(ev.ascii);
        }
        con.setAttr(VGA_ATTR);
        con.putch('\'');
    } else if (keyboard.keycodeName(ev.keycode)) |name| {
        // Print key name if available
        con.setAttr(0x0f);
        // Output each character of the name until null terminator
        var i: usize = 0;
        while (name[i] != 0) : (i += 1) {
            con.putch(name[i]);
        }
        con.setAttr(VGA_ATTR);
    } else {
        // Print hex keycode
        con.puts("keycode 0x");
        con.setAttr(0x0f);
        con.putHexU16(ev.keycode);
        con.setAttr(VGA_ATTR);
    }
    con.newline();

    // Print raw scancode
    con.puts("Raw:     ");
    if ((ev.keycode & keyboard.VK_EXTENDED) != 0) {
        con.puts("0xE0 ");
    }
    con.puts("0x");
    con.setAttr(0x0f);
    con.putHexU8(ev.scancode);
    con.setAttr(VGA_ATTR);
    con.newline();

    // Print modifier keys
    con.puts("Mods:    ");
    con.setAttr(0x0f);
    if ((ev.modifiers & keyboard.MOD_SHIFT) != 0) {
        con.puts("Shift ");
    }
    if ((ev.modifiers & keyboard.MOD_ALT) != 0) {
        con.puts("Alt ");
    }
    if ((ev.modifiers & keyboard.MOD_CTRL) != 0) {
        con.puts("Ctrl ");
    } else if (ev.modifiers == 0) {
        con.puts("-");
    }
    con.setAttr(VGA_ATTR);
    con.newline();

    // Print IRQ count
    con.puts("IRQs:    ");
    con.setAttr(0x0f);
    con.putDecU32(keyboard.keyboard_irq_count);
    con.setAttr(VGA_ATTR);
    con.newline();

    // Print overflow count
    con.puts("Dropped: ");
    con.setAttr(0x0f);
    con.putDecU32(keyboard.keyboard_overflow_count);
    con.setAttr(VGA_ATTR);
    con.newline();
    con.newline();

    return 0;
}

pub const Keylog = struct {
    console: *console.Console,

    pub fn init(self: *Keylog) void {
        kernel.setKeyboardHandler(appKeylogKeyhandler, self.console);
    }

    pub fn deinit(_: *Keylog) void {
        kernel.clearKeyboardHandler();
    }
};
