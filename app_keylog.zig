const keyboard = @import("keyboard.zig");
const console = @import("console.zig");
const c = @cImport({
    @cInclude("app.h");
});

const VGA_ATTR: u8 = 0x07;

/// Handle keyboard events and log them to console
fn appKeylogKeyhandler(event: [*c]const c.struct_key_event) callconv(.c) u32 {
    const ev = event[0];

    // Print press/release status
    console.puts(if (ev.pressed != 0) "Down: " else "Up:   ");

    // Print ASCII character if available
    if (ev.ascii != 0) {
        console.putch('\'');
        console.setAttr(0x0f);
        if (ev.ascii == '\n') {
            console.putch('\\');
            console.putch('n');
        } else {
            console.putch(ev.ascii);
        }
        console.setAttr(VGA_ATTR);
        console.putch('\'');
    } else if (keyboard.keycodeName(ev.keycode, ev.extended)) |name| {
        // Print key name if available
        console.setAttr(0x0f);
        // Output each character of the name until null terminator
        var i: usize = 0;
        while (name[i] != 0) : (i += 1) {
            console.putch(name[i]);
        }
        console.setAttr(VGA_ATTR);
    } else {
        // Print hex keycode
        console.puts("keycode 0x");
        console.setAttr(0x0f);
        console.putHexU8(ev.keycode);
        console.setAttr(VGA_ATTR);
    }
    console.newline();

    // Print raw scancode
    console.puts("Raw:     ");
    if (ev.extended != 0) {
        console.puts("0xE0 ");
    }
    console.puts("0x");
    console.setAttr(0x0f);
    console.putHexU8(ev.scancode);
    console.setAttr(VGA_ATTR);
    console.newline();

    // Print modifier keys
    console.puts("Mods:    ");
    console.setAttr(0x0f);
    if ((ev.modifiers & keyboard.MOD_SHIFT) != 0) {
        console.puts("Shift ");
    }
    if ((ev.modifiers & keyboard.MOD_ALT) != 0) {
        console.puts("Alt ");
    }
    if ((ev.modifiers & keyboard.MOD_CTRL) != 0) {
        console.puts("Ctrl ");
    } else if (ev.modifiers == 0) {
        console.puts("-");
    }
    console.setAttr(VGA_ATTR);
    console.newline();

    // Print IRQ count
    console.puts("IRQs:    ");
    console.setAttr(0x0f);
    console.putDecU32(keyboard.keyboard_irq_count);
    console.setAttr(VGA_ATTR);
    console.newline();

    // Print overflow count
    console.puts("Dropped: ");
    console.setAttr(0x0f);
    console.putDecU32(keyboard.keyboard_overflow_count);
    console.setAttr(VGA_ATTR);
    console.newline();
    console.newline();

    return 0;
}

/// Initialize the keylog app
pub export fn app_keylog_init(app: [*c]c.struct_app_context) callconv(.c) u32 {
    if (app == null) return 1;

    const app_ptr = &app[0];
    app_ptr.* = .{
        .name = "keylog",
        .key_event_handler = appKeylogKeyhandler,
    };

    return 0;
}
