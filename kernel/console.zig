const serial = @import("serial.zig");
const vconsole = @import("gfx/vconsole.zig");
const vga = @import("vgatext.zig");

pub const TEXT_WIDTH: u32 = vga.TEXT_WIDTH;
pub const TEXT_HEIGHT: u32 = vga.TEXT_HEIGHT;

const SCREEN_CELLS = TEXT_WIDTH * TEXT_HEIGHT;

pub const Cell = u16;

const Backend = enum {
    vga,
    framebuf,
};

var console_row: u32 = 0;
var console_col: u32 = 0;
var console_attr: u8 = 0x07;
var serial_mirror_enabled: bool = false;
var cursor_visible: bool = true;
var backend: Backend = .vga;
var console_cells: [*]u16 = undefined; // Points to either VGA memory or a console buffer, depending on backend.

// Only used for framebuffer backend.
// TODO: allocate on demand and make larger for efficient append/rollback
var console_buffer: [SCREEN_CELLS]u16 = undefined;

inline fn cellIndex(row: u32, col: u32) u32 {
    return row * TEXT_WIDTH + col;
}

inline fn makeCell(ch: u8, attr: u8) u16 {
    return (@as(u16, attr) << 8) | ch;
}

/// If required by the backend, update the screen.
pub fn refresh() void {
    if (backend == .framebuf)
        vconsole.render(console_cells, console_row, console_col, cursor_visible);
    // VGA backend is updated automatically by hardware when we write to video memory.
}

fn syncCursor() void {
    switch (backend) {
        .vga => {
            if (cursor_visible) {
                vga.enableCursor();
                vga.setCursorPos(console_row, console_col);
            } else {
                vga.disableCursor();
            }
        },
        .framebuf => vconsole.setCursor(console_cells, console_row, console_col, cursor_visible),
    }
}

fn scrollIfNeeded() void {
    if (console_row < TEXT_HEIGHT) return;

    if (backend == .framebuf and cursor_visible) {
        vconsole.setCursor(console_cells, console_row, console_col, false);
    }

    var row: u32 = 1;
    while (row < TEXT_HEIGHT) : (row += 1) {
        var col: u32 = 0;
        while (col < TEXT_WIDTH) : (col += 1) {
            console_cells[cellIndex(row - 1, col)] = console_cells[cellIndex(row, col)];
        }
    }

    var col: u32 = 0;
    while (col < TEXT_WIDTH) : (col += 1) {
        console_cells[cellIndex(TEXT_HEIGHT - 1, col)] = makeCell(' ', console_attr);
    }

    console_row = TEXT_HEIGHT - 1;
    if (backend == .framebuf) {
        vconsole.scroll(console_cells);
    } else {
        refresh();
    }
}

fn advanceLine() void {
    console_col = 0;
    console_row += 1;
    scrollIfNeeded();
}

pub export fn init(attr: u8) void {
    backend = .vga;
    console_cells = @ptrCast(@volatileCast(vga.memory));
    console_attr = attr;
    console_row = 0;
    console_col = 0;
    cursor_visible = true;
    clearCells(console_attr);
}

pub fn clearCells(attr: u8) void {
    @memset(console_cells[0..SCREEN_CELLS], makeCell(' ', attr));
    refresh();
}

pub fn clear() void {
    console_row = 0;
    console_col = 0;
    clearCells(console_attr);
}

pub fn setCursor(row: u32, col: u32) void {
    console_row = if (row >= TEXT_HEIGHT) TEXT_HEIGHT - 1 else row;
    console_col = if (col >= TEXT_WIDTH) TEXT_WIDTH - 1 else col;
    syncCursor();
}

pub fn getCursorPos() struct { u32, u32 } {
    return .{ console_row, console_col };
}

pub fn setAttr(attr: u8) void {
    console_attr = attr;
}

/// Show or hide the active console cursor.
pub fn setCursorVisible(visible: bool) void {
    cursor_visible = visible;
    syncCursor();
}

/// Enable or disable mirroring console output to the serial port.
pub fn setSerialMirrorEnabled(enabled: bool) void {
    serial_mirror_enabled = enabled;
}

/// Return whether console output is currently mirrored to serial.
pub fn isSerialMirrorEnabled() bool {
    return serial_mirror_enabled;
}

/// Read a raw u16 cell (attr<<8 | char) from the console grid at (row, col).
pub fn readCell(row: u32, col: u32) u16 {
    if (row >= TEXT_HEIGHT or col >= TEXT_WIDTH) return 0;
    return console_cells[cellIndex(row, col)];
}

/// Write a single character cell directly into the console grid.
pub fn putCharAt(row: u32, col: u32, ch: u8, attr: u8) void {
    if (row >= TEXT_HEIGHT or col >= TEXT_WIDTH) return;

    console_cells[cellIndex(row, col)] = makeCell(ch, attr);

    if (backend == .framebuf) {
        vconsole.renderCell(console_cells, row, col);
    }
}

/// Switch console rendering to the framebuffer text backend when graphics mode is available.
pub fn enableFramebufBackend() void {
    if (backend == .framebuf) return;

    backend = .framebuf;
    vga.disableCursor();

    console_cells = &console_buffer;
}

fn newlineInternal(sync_cursor: bool) void {
    if (serial_mirror_enabled and serial.isInitialized()) {
        serial.putch('\n');
    }
    advanceLine();
    if (sync_cursor) syncCursor();
}

pub fn newline() void {
    newlineInternal(true);
}

fn putchInternal(ch: u8, sync_cursor: bool) void {
    switch (ch) {
        '\n' => {
            newlineInternal(sync_cursor);
            return;
        },
        '\r' => {
            if (serial_mirror_enabled and serial.isInitialized()) {
                serial.putch(ch);
            }
            console_col = 0;
            if (sync_cursor) syncCursor();
            return;
        },
        else => {},
    }

    if (serial_mirror_enabled and serial.isInitialized()) {
        serial.putch(ch);
    }
    putCharAt(console_row, console_col, ch, console_attr);
    console_col += 1;
    if (console_col >= TEXT_WIDTH) {
        advanceLine();
    }
    if (sync_cursor) syncCursor();
}

pub fn putch(ch: u8) void {
    putchInternal(ch, true);
}

pub fn puts(s: []const u8) void {
    if (backend == .framebuf and cursor_visible and s.len > 1) {
        cursor_visible = false;
        syncCursor();
        defer {
            cursor_visible = true;
            syncCursor();
        }

        for (s) |ch| {
            putchInternal(ch, false);
        }
        return;
    }

    for (s) |ch| {
        putchInternal(ch, true);
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
        } else if (@TypeOf(val) == u16) {
            putHexU16(val);
        } else if (@TypeOf(val) == u8) {
            putHexU8(val);
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
