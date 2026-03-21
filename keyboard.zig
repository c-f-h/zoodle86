const std = @import("std");

// Modifier flags
pub const MOD_SHIFT = 0x01;
pub const MOD_ALT = 0x02;
pub const MOD_CTRL = 0x04;

// Scancodes
pub const SC_ENTER = 0x1C;
pub const SC_BACKSPACE = 0x0E;

// Extended Scancodes
pub const ESC_HOME = 0x47;
pub const ESC_LEFT = 0x4B;
pub const ESC_UP = 0x48;
pub const ESC_END = 0x4F;
pub const ESC_RIGHT = 0x4D;
pub const ESC_DOWN = 0x50;
pub const ESC_DELETE = 0x53;

/// Keyboard event structure
pub const KeyEvent = struct {
    scancode: u8,
    keycode: u8,
    pressed: u8,
    extended: u8,
    modifiers: u8,
    ascii: u8,
};

// External symbols from interrupts.asm
extern var keyboard_scancode_buffer: [16]u8;
extern var keyboard_scancode_head: u8;
extern var keyboard_scancode_tail: u8;

// External output metrics
pub extern var keyboard_irq_count: u32;
pub extern var keyboard_overflow_count: u32;

// Module state
var keyboard_modifiers: u8 = 0;
var keyboard_e0_pending: u8 = 0;

/// Event sink callback - must be defined by kernel
extern fn consume_key_event(event: *const KeyEvent) void;

/// Convert a keycode to ASCII character, respecting shift modifier
fn keycodeToAscii(keycode: u8, modifiers: u8) u8 {
    return switch (keycode) {
        0x02 => if ((modifiers & MOD_SHIFT) != 0) '!' else '1',
        0x03 => if ((modifiers & MOD_SHIFT) != 0) '@' else '2',
        0x04 => if ((modifiers & MOD_SHIFT) != 0) '#' else '3',
        0x05 => if ((modifiers & MOD_SHIFT) != 0) '$' else '4',
        0x06 => if ((modifiers & MOD_SHIFT) != 0) '%' else '5',
        0x07 => if ((modifiers & MOD_SHIFT) != 0) '^' else '6',
        0x08 => if ((modifiers & MOD_SHIFT) != 0) '&' else '7',
        0x09 => if ((modifiers & MOD_SHIFT) != 0) '*' else '8',
        0x0A => if ((modifiers & MOD_SHIFT) != 0) '(' else '9',
        0x0B => if ((modifiers & MOD_SHIFT) != 0) ')' else '0',
        0x0C => if ((modifiers & MOD_SHIFT) != 0) '_' else '-',
        0x0D => if ((modifiers & MOD_SHIFT) != 0) '+' else '=',
        0x10 => if ((modifiers & MOD_SHIFT) != 0) 'Q' else 'q',
        0x11 => if ((modifiers & MOD_SHIFT) != 0) 'W' else 'w',
        0x12 => if ((modifiers & MOD_SHIFT) != 0) 'E' else 'e',
        0x13 => if ((modifiers & MOD_SHIFT) != 0) 'R' else 'r',
        0x14 => if ((modifiers & MOD_SHIFT) != 0) 'T' else 't',
        0x15 => if ((modifiers & MOD_SHIFT) != 0) 'Y' else 'y',
        0x16 => if ((modifiers & MOD_SHIFT) != 0) 'U' else 'u',
        0x17 => if ((modifiers & MOD_SHIFT) != 0) 'I' else 'i',
        0x18 => if ((modifiers & MOD_SHIFT) != 0) 'O' else 'o',
        0x19 => if ((modifiers & MOD_SHIFT) != 0) 'P' else 'p',
        0x1A => if ((modifiers & MOD_SHIFT) != 0) '{' else '[',
        0x1B => if ((modifiers & MOD_SHIFT) != 0) '}' else ']',
        0x1E => if ((modifiers & MOD_SHIFT) != 0) 'A' else 'a',
        0x1F => if ((modifiers & MOD_SHIFT) != 0) 'S' else 's',
        0x20 => if ((modifiers & MOD_SHIFT) != 0) 'D' else 'd',
        0x21 => if ((modifiers & MOD_SHIFT) != 0) 'F' else 'f',
        0x22 => if ((modifiers & MOD_SHIFT) != 0) 'G' else 'g',
        0x23 => if ((modifiers & MOD_SHIFT) != 0) 'H' else 'h',
        0x24 => if ((modifiers & MOD_SHIFT) != 0) 'J' else 'j',
        0x25 => if ((modifiers & MOD_SHIFT) != 0) 'K' else 'k',
        0x26 => if ((modifiers & MOD_SHIFT) != 0) 'L' else 'l',
        0x27 => if ((modifiers & MOD_SHIFT) != 0) ':' else ';',
        0x28 => if ((modifiers & MOD_SHIFT) != 0) '"' else '\'',
        0x29 => if ((modifiers & MOD_SHIFT) != 0) '~' else '`',
        0x2B => if ((modifiers & MOD_SHIFT) != 0) '|' else '\\',
        0x2C => if ((modifiers & MOD_SHIFT) != 0) 'Z' else 'z',
        0x2D => if ((modifiers & MOD_SHIFT) != 0) 'X' else 'x',
        0x2E => if ((modifiers & MOD_SHIFT) != 0) 'C' else 'c',
        0x2F => if ((modifiers & MOD_SHIFT) != 0) 'V' else 'v',
        0x30 => if ((modifiers & MOD_SHIFT) != 0) 'B' else 'b',
        0x31 => if ((modifiers & MOD_SHIFT) != 0) 'N' else 'n',
        0x32 => if ((modifiers & MOD_SHIFT) != 0) 'M' else 'm',
        0x33 => if ((modifiers & MOD_SHIFT) != 0) '<' else ',',
        0x34 => if ((modifiers & MOD_SHIFT) != 0) '>' else '.',
        0x35 => if ((modifiers & MOD_SHIFT) != 0) '?' else '/',
        0x39 => ' ',
        else => 0,
    };
}

/// Get human-readable name for special keycodes
pub fn keycodeName(keycode: u8, extended: u8) ?[*:0]const u8 {
    if (extended != 0) {
        return switch (keycode) {
            0x1C => "Keypad Enter",
            0x1D => "Right Ctrl",
            0x35 => "Keypad /",
            0x38 => "Right Alt",
            0x48 => "Up",
            0x4B => "Left",
            0x4D => "Right",
            0x50 => "Down",
            else => "Ext",
        };
    }

    return switch (keycode) {
        0x01 => "Esc",
        0x0E => "Backspace",
        0x0F => "Tab",
        0x1C => "Enter",
        0x1D => "Left Ctrl",
        0x2A => "Left Shift",
        0x36 => "Right Shift",
        0x38 => "Left Alt",
        0x39 => "Space",
        else => null,
    };
}

/// Decode a single scancode into a key event
/// Returns 1 if a complete key event was decoded, 0 otherwise
fn decodeScancode(scancode: u8, event: *KeyEvent) u8 {
    // 0xE0 signals extended scancode
    if (scancode == 0xE0) {
        keyboard_e0_pending = 1;
        return 0;
    }

    const extended = keyboard_e0_pending;
    keyboard_e0_pending = 0;
    const keycode = scancode & 0x7F;
    const pressed = (scancode & 0x80) == 0; // high bit = released

    // Update shift modifiers
    if (extended == 0 and (keycode == 0x2A or keycode == 0x36)) {
        if (pressed) {
            keyboard_modifiers |= MOD_SHIFT;
        } else {
            keyboard_modifiers &= ~@as(u8, MOD_SHIFT);
        }
    }

    // Update alt modifier
    if (keycode == 0x38) {
        if (pressed) {
            keyboard_modifiers |= MOD_ALT;
        } else {
            keyboard_modifiers &= ~@as(u8, MOD_ALT);
        }
    }

    // Update ctrl modifier
    if (keycode == 0x1D) {
        if (pressed) {
            keyboard_modifiers |= MOD_CTRL;
        } else {
            keyboard_modifiers &= ~@as(u8, MOD_CTRL);
        }
    }

    event.scancode = scancode;
    event.keycode = keycode;
    event.pressed = if (pressed) 1 else 0;
    event.extended = extended;
    event.modifiers = keyboard_modifiers;
    event.ascii = if (extended == 0 and pressed) keycodeToAscii(keycode, keyboard_modifiers) else 0;

    return 1;
}

/// Poll the ringbuffer of scancodes filled by the keyboard ISR, decode key events, and send them to the event sink.
pub export fn keyboard_poll() callconv(.c) void {
    // Disable interrupts
    asm volatile ("cli");

    // If buffer is empty, wait
    if (keyboard_scancode_head == keyboard_scancode_tail) {
        asm volatile ("sti\nhlt\ncli");
    }

    // Process all pending scancodes
    while (keyboard_scancode_head != keyboard_scancode_tail) {
        const scancode = keyboard_scancode_buffer[keyboard_scancode_tail];

        keyboard_scancode_tail = (keyboard_scancode_tail + 1) & 0x0F;

        // Re-enable interrupts while processing event
        asm volatile ("sti");

        var event: KeyEvent = undefined;
        if (decodeScancode(scancode, &event) != 0) {
            consume_key_event(&event);
        }

        // Disable again to check buffer
        asm volatile ("cli");
    }

    // Re-enable interrupts
    asm volatile ("sti");
}
