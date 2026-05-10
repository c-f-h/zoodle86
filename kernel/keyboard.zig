const interrupt_frame = @import("interrupt_frame.zig");
const kernel = @import("kernel.zig");
const io = @import("io.zig");
const filedesc = @import("filedesc.zig");
const abi = @import("abi");
const std = @import("std");

// Modifier flags
pub const MOD_SHIFT = abi.MOD_SHIFT;
pub const MOD_ALT = abi.MOD_ALT;
pub const MOD_CTRL = abi.MOD_CTRL;

// Virtual keycode prefix for extended keys
pub const VK_EXTENDED = abi.VK_EXTENDED;

// Regular virtual keycodes (non-extended scancode equivalents)
pub const VK_ENTER = abi.VK_ENTER;
pub const VK_BACKSPACE = abi.VK_BACKSPACE;
pub const VK_TAB = abi.VK_TAB;
pub const VK_ESC = abi.VK_ESC;
pub const VK_LCTRL = abi.VK_LCTRL;
pub const VK_LSHIFT = abi.VK_LSHIFT;
pub const VK_RSHIFT = abi.VK_RSHIFT;
pub const VK_LALT = abi.VK_LALT;
pub const VK_SPACE = abi.VK_SPACE;

// Letter keycodes
pub const VK_A = abi.VK_A;
pub const VK_B = abi.VK_B;
pub const VK_C = abi.VK_C;
pub const VK_D = abi.VK_D;
pub const VK_E = abi.VK_E;
pub const VK_F = abi.VK_F;
pub const VK_G = abi.VK_G;
pub const VK_H = abi.VK_H;
pub const VK_I = abi.VK_I;
pub const VK_J = abi.VK_J;
pub const VK_K = abi.VK_K;
pub const VK_L = abi.VK_L;
pub const VK_M = abi.VK_M;
pub const VK_N = abi.VK_N;
pub const VK_O = abi.VK_O;
pub const VK_P = abi.VK_P;
pub const VK_Q = abi.VK_Q;
pub const VK_R = abi.VK_R;
pub const VK_S = abi.VK_S;
pub const VK_T = abi.VK_T;
pub const VK_U = abi.VK_U;
pub const VK_V = abi.VK_V;
pub const VK_W = abi.VK_W;
pub const VK_X = abi.VK_X;
pub const VK_Y = abi.VK_Y;
pub const VK_Z = abi.VK_Z;

// Extended virtual keycodes
pub const VK_KEYPAD_ENTER = abi.VK_KEYPAD_ENTER;
pub const VK_RCTRL = abi.VK_RCTRL;
pub const VK_KEYPAD_SLASH = abi.VK_KEYPAD_SLASH;
pub const VK_RALT = abi.VK_RALT;
pub const VK_UP = abi.VK_UP;
pub const VK_LEFT = abi.VK_LEFT;
pub const VK_RIGHT = abi.VK_RIGHT;
pub const VK_DOWN = abi.VK_DOWN;
pub const VK_HOME = abi.VK_HOME;
pub const VK_END = abi.VK_END;
pub const VK_DELETE = abi.VK_DELETE;

// Legacy names for compatibility (will be removed)
pub const SC_ENTER = VK_ENTER;
pub const SC_BACKSPACE = VK_BACKSPACE;
pub const ESC_HOME = VK_HOME;
pub const ESC_LEFT = VK_LEFT;
pub const ESC_UP = VK_UP;
pub const ESC_END = VK_END;
pub const ESC_RIGHT = VK_RIGHT;
pub const ESC_DOWN = VK_DOWN;
pub const ESC_DELETE = VK_DELETE;

/// Keyboard event structure
pub const KeyEvent = struct {
    scancode: u8,
    pressed: u8,
    keycode: u16,
    modifiers: u8,
    ascii: u8,
};

/// Compact 4-byte key event delivered to userspace via the keyboard event pipe.
pub const StdinKeyEvent = abi.KeyEvent;

// Keyboard ring buffer
var keyboard_scancode_buffer: [16]u8 = undefined;
var keyboard_scancode_head: u8 = 0;
var keyboard_scancode_tail: u8 = 0;

// Output metrics
pub var keyboard_irq_count: u32 = 0;
pub var keyboard_overflow_count: u32 = 0;

// Module state
var keyboard_modifiers: u8 = 0;
var keyboard_e0_pending: u8 = 0;

/// Convert a keycode to ASCII character, respecting shift modifier
fn keycodeToAscii(keycode: u16, modifiers: u8) u8 {
    // ASCII conversion only works for non-extended keycodes
    if ((keycode & VK_EXTENDED) != 0) return 0;
    const sc = @as(u8, @truncate(keycode));

    return switch (sc) {
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

/// Get human-readable name for virtual keycodes
pub fn keycodeName(keycode: u16) ?[*:0]const u8 {
    return switch (keycode) {
        VK_KEYPAD_ENTER => "Keypad Enter",
        VK_RCTRL => "Right Ctrl",
        VK_KEYPAD_SLASH => "Keypad /",
        VK_RALT => "Right Alt",
        VK_UP => "Up",
        VK_LEFT => "Left",
        VK_RIGHT => "Right",
        VK_DOWN => "Down",
        VK_HOME => "Home",
        VK_END => "End",
        VK_DELETE => "Delete",
        VK_ESC => "Esc",
        VK_BACKSPACE => "Backspace",
        VK_TAB => "Tab",
        VK_ENTER => "Enter",
        VK_LCTRL => "Left Ctrl",
        VK_LSHIFT => "Left Shift",
        VK_RSHIFT => "Right Shift",
        VK_LALT => "Left Alt",
        VK_SPACE => "Space",
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
    const sc = scancode & 0x7F;
    const pressed = (scancode & 0x80) == 0; // high bit = released

    // Create virtual keycode with extended flag if needed
    const vk: u16 = if (extended != 0) (VK_EXTENDED | @as(u16, sc)) else @as(u16, sc);

    // Update shift modifiers (only for non-extended codes)
    if (extended == 0 and (sc == 0x2A or sc == 0x36)) {
        if (pressed) {
            keyboard_modifiers |= MOD_SHIFT;
        } else {
            keyboard_modifiers &= ~MOD_SHIFT;
        }
    }

    // Update alt modifier
    if (sc == 0x38) {
        if (pressed) {
            keyboard_modifiers |= MOD_ALT;
        } else {
            keyboard_modifiers &= ~MOD_ALT;
        }
    }

    // Update ctrl modifier
    if (sc == 0x1D) {
        if (pressed) {
            keyboard_modifiers |= MOD_CTRL;
        } else {
            keyboard_modifiers &= ~MOD_CTRL;
        }
    }

    event.scancode = scancode;
    event.keycode = vk;
    event.pressed = if (pressed) 1 else 0;
    event.modifiers = keyboard_modifiers;
    event.ascii = if (extended == 0 and pressed) keycodeToAscii(vk, keyboard_modifiers) else 0;

    return 1;
}

pub fn keyboard_dispatch(frame: *const interrupt_frame.InterruptFrame) void {
    _ = frame;

    const scancode = io.inb(0x60);
    keyboard_irq_count += 1;

    const next_head: u8 = (keyboard_scancode_head + 1) & 0x0F;
    if (next_head == keyboard_scancode_tail) {
        // Buffer overflow - drop event
        keyboard_overflow_count += 1;
        return;
    } else {
        keyboard_scancode_buffer[keyboard_scancode_head] = scancode;
        keyboard_scancode_head = next_head;
    }
}

/// Poll the ringbuffer of scancodes filled by the keyboard ISR, decode key events, and send them to the event sink.
pub export fn pollingLoop() void {
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
            kernel.consumeKeyEvent(&event);
        }

        // Disable again to check buffer
        asm volatile ("cli");
    }

    // Re-enable interrupts
    asm volatile ("sti");
}

var pipe_initialized: bool = false;
var pipe_writer_fd: filedesc.FileDesc = undefined;

/// Get a pipe FileDesc for reading keyboard events as StdinKeyEvent structs.
pub fn getKeyEventPipe() error{ OutOfMemory, BadFd }!filedesc.FileDesc {
    if (!pipe_initialized) {
        var reader, const writer = try filedesc.makePipe();
        try reader.close(); // readers will be created on demand
        pipe_writer_fd = writer;
        pipe_initialized = true;
    }
    return filedesc.newPipeReader(pipe_writer_fd.pipe.handle);
}

/// Pushes a key event into the event pipe; drops the event if the buffer is full or there are no readers.
pub fn pushRawKeyEventToPipe(ev: KeyEvent) bool {
    if (!pipe_initialized) return false;
    if (pipe_writer_fd.pipe.handle.num_readers == 0) return false; // no readers, drop event
    if (pipe_writer_fd.pipe.handle.bytesFree() < @sizeOf(abi.KeyEvent)) return false; // not enough space, drop event

    const write_ev = abi.KeyEvent{
        .keycode = ev.keycode,
        .modifiers = ev.modifiers,
        .ascii = ev.ascii,
    };

    const written = pipe_writer_fd.pipe.handle.write(std.mem.asBytes(&write_ev));
    if (written != @sizeOf(abi.KeyEvent)) {
        // Shouldn't happen due to check; possible race condition once kernel is reentrant
        @panic("partial write to keyevent pipe");
    }
    return true;
}
