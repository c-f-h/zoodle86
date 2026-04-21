const serial = @import("serial.zig");
const vga = @import("vgatext.zig");

var console_row: u32 = 0;
var console_col: u32 = 0;
var console_attr: u8 = 0x07;
var serial_mirror_enabled: bool = false;

fn syncCursor() void {
    vga.setCursorPos(console_row, console_col);
}

fn scrollIfNeeded() void {
    if (console_row < vga.TEXT_HEIGHT) return;

    var row: u32 = 1;
    while (row < vga.TEXT_HEIGHT) : (row += 1) {
        var col: u32 = 0;
        while (col < vga.TEXT_WIDTH) : (col += 1) {
            const cell: u16 = vga.readCell(row, col);
            vga.putCharAt(row - 1, col, @truncate(cell & 0x00FF), @truncate(cell >> 8));
        }
    }

    var col: u32 = 0;
    while (col < vga.TEXT_WIDTH) : (col += 1) {
        vga.putCharAt(vga.TEXT_HEIGHT - 1, col, ' ', console_attr);
    }

    console_row = vga.TEXT_HEIGHT - 1;
}

fn advanceLine() void {
    console_col = 0;
    console_row += 1;
    scrollIfNeeded();
}

pub export fn console_init(attr: u8) void {
    console_attr = attr;
    console_row = 0;
    console_col = 0;
    vga.enableCursor();
    vga.clear(console_attr);
    syncCursor();
}

pub fn clear() void {
    vga.clear(console_attr);
    console_row = 0;
    console_col = 0;
    syncCursor();
}

pub fn setCursor(row: u32, col: u32) void {
    console_row = if (row >= vga.TEXT_HEIGHT) vga.TEXT_HEIGHT - 1 else row;
    console_col = if (col >= vga.TEXT_WIDTH) vga.TEXT_WIDTH - 1 else col;
    syncCursor();
}

pub fn getCursorPos() struct { u32, u32 } {
    return .{ console_row, console_col };
}

pub fn setAttr(attr: u8) void {
    console_attr = attr;
}

/// Enable or disable mirroring console output to the serial port.
pub fn setSerialMirrorEnabled(enabled: bool) void {
    serial_mirror_enabled = enabled;
}

/// Return whether console output is currently mirrored to serial.
pub fn isSerialMirrorEnabled() bool {
    return serial_mirror_enabled;
}

pub fn newline() void {
    if (serial_mirror_enabled and serial.isInitialized()) {
        serial.putch('\n');
    }
    advanceLine();
    syncCursor();
}

pub fn putch(ch: u8) void {
    switch (ch) {
        '\n' => {
            newline();
            return;
        },
        '\r' => {
            if (serial_mirror_enabled and serial.isInitialized()) {
                serial.putch(ch);
            }
            console_col = 0;
            syncCursor();
            return;
        },
        else => {},
    }

    if (serial_mirror_enabled and serial.isInitialized()) {
        serial.putch(ch);
    }
    vga.putCharAt(console_row, console_col, ch, console_attr);
    console_col += 1;
    if (console_col >= vga.TEXT_WIDTH) {
        advanceLine();
    }
    syncCursor();
}

pub fn puts(s: []const u8) void {
    for (s) |ch| {
        putch(ch);
    }
}

pub fn formatHexU(comptime bytes: u8, value: @Int(.unsigned, 8 * bytes), out: *[2 * bytes]u8) void {
    const hex = "0123456789ABCDEF";
    var shift: i8 = 8 * bytes - 4;
    var ofs: u8 = 0;
    while (shift >= 0) : (shift -= 4) {
        out.*[ofs] = hex[(value >> @intCast(shift)) & 0x0F];
        ofs += 1;
    }
}

pub fn putHexU8(value: u8) void {
    const hex = "0123456789ABCDEF";
    putch(hex[(value >> 4) & 0x0F]);
    putch(hex[value & 0x0F]);
}

pub fn putHexU16(value: u16) void {
    var str: [4]u8 = undefined;
    formatHexU(2, value, &str);
    puts(&str);
}

pub fn putHexU32(value: u32) void {
    var str: [8]u8 = undefined;
    formatHexU(4, value, &str);
    puts(&str);
}

pub fn putHexU64(value: u64) void {
    // Split u64 into two u32 halves to avoid 64-bit shift runtime functions
    const hi: u32 = @intCast(value >> 32);
    const lo: u32 = @intCast(value & 0xFFFFFFFF);
    putHexU32(hi);
    putHexU32(lo);
}

pub fn putDecU32(value: u32) void {
    if (value == 0) {
        putch('0');
        return;
    }

    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var remaining = value;

    while (remaining > 0) {
        digits[count] = @intCast('0' + (remaining % 10));
        remaining /= 10;
        count += 1;
    }

    while (count > 0) {
        count -= 1;
        putch(digits[count]);
    }
}

/// Print a u32 as a fixed-width 32-bit binary string.
pub fn putBinaryU32(value: u32) void {
    var bit: u32 = 0;
    while (bit < 32) : (bit += 1) {
        const shift: u5 = @intCast(31 - bit);
        putch(if (((value >> shift) & 1) == 0) '0' else '1');
    }
}

pub inline fn put(multiple: anytype) void {
    inline for (multiple) |val| {
        if (@TypeOf(val) == u64) {
            putHexU64(val);
        } else if (@TypeOf(val) == u32 or @TypeOf(val) == usize) {
            putHexU32(val);
        } else {
            puts(val);
        }
    }
}

/// Dump memory in hex viewer format showing address, hex bytes, and ASCII representation.
/// Displays `num_lines` of 16 bytes each starting from the given address.
pub fn dumpMem(addr: u32, num_lines: u32) void {
    var line: u32 = 0;
    while (line < num_lines) : (line += 1) {
        const line_addr = addr + (line * 16);
        const ptr: [*]const u8 = @ptrFromInt(line_addr);

        // Print address
        putHexU32(line_addr);
        puts(": ");

        // Print hex bytes
        var byte_idx: u32 = 0;
        while (byte_idx < 16) : (byte_idx += 1) {
            putHexU8(ptr[byte_idx]);
            putch(' ');
        }

        // Print separator
        puts("| ");

        // Print ASCII representation
        byte_idx = 0;
        while (byte_idx < 16) : (byte_idx += 1) {
            const ch = ptr[byte_idx];
            if (ch >= 32 and ch < 127) {
                putch(ch);
            } else {
                putch('.');
            }
        }

        newline();
    }
}
