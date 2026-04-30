const paging = @import("paging.zig");
const serial = @import("serial.zig");
const vconsole = @import("gfx/vconsole.zig");
const vga = @import("vgatext.zig");
const mem = @import("mem.zig");

const std = @import("std");

pub const VGA_TEXT_WIDTH: u32 = vga.TEXT_WIDTH;
pub const VGA_TEXT_HEIGHT: u32 = vga.TEXT_HEIGHT;

pub var width: u32 = VGA_TEXT_WIDTH;
pub var height: u32 = VGA_TEXT_HEIGHT;

pub const Cell = u16;

const Backend = enum {
    vga,
    buffered, // only for temporary console storage before framebuffer is initialized
    framebuf,
};

var console_row: u32 = 0;
var console_col: u32 = 0;
var console_attr: u8 = 0x07;
var serial_mirror_enabled: bool = false;
var cursor_visible: bool = true;

var backend: Backend = .vga;
var console_cell_count: usize = @as(usize, VGA_TEXT_WIDTH) * @as(usize, VGA_TEXT_HEIGHT);
var console_cells: [*]u16 = undefined; // Points to either VGA memory or a console buffer, depending on backend.
var bootstrap_buffer: [VGA_TEXT_WIDTH * VGA_TEXT_HEIGHT]u16 = undefined;
var cell_buffer: []Cell = undefined; // allocated when switching to framebuffer backend

inline fn cellIndex(row: u32, col: u32) usize {
    return row * width + col;
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
        .buffered => {},
        .framebuf => vconsole.setCursor(console_cells, console_row, console_col, cursor_visible),
    }
}

fn scrollIfNeeded() void {
    if (console_row < height) return;

    if (backend == .framebuf and cursor_visible) {
        vconsole.setCursor(console_cells, console_row, console_col, false);
    }

    // Shift all rows up by one in the console cell buffer.
    mem.copyBytesForward(@ptrCast(console_cells), @ptrCast(console_cells + width), (height - 1) * width * @sizeOf(Cell));

    // Clear the new bottom row.
    var col: u32 = 0;
    while (col < width) : (col += 1) {
        console_cells[cellIndex(height - 1, col)] = makeCell(' ', console_attr);
    }

    console_row = height - 1;
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
    width = VGA_TEXT_WIDTH;
    height = VGA_TEXT_HEIGHT;
    console_cell_count = width * height;
    console_attr = attr;
    console_row = 0;
    console_col = 0;
    cursor_visible = true;
    clearCells(console_attr);
}

pub fn clearCells(attr: u8) void {
    @memset(console_cells[0..console_cell_count], makeCell(' ', attr));
    refresh();
}

pub fn clear() void {
    console_row = 0;
    console_col = 0;
    clearCells(console_attr);
}

pub fn setCursor(row: u32, col: u32) void {
    console_row = if (row >= height) height - 1 else row;
    console_col = if (col >= width) width - 1 else col;
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
    if (row >= height or col >= width) return 0;
    return console_cells[cellIndex(row, col)];
}

/// Write a single character cell directly into the console grid.
pub fn putCharAt(row: u32, col: u32, ch: u8, attr: u8) void {
    if (row >= height or col >= width) return;

    console_cells[cellIndex(row, col)] = makeCell(ch, attr);

    if (backend == .framebuf) {
        vconsole.renderCell(console_cells, row, col);
    }
}

/// Switch console rendering to the framebuffer text backend when graphics mode is available.
pub fn enableFramebufBackend(allocator: std.mem.Allocator, text_width: u32, text_height: u32) !void {
    if (backend == .framebuf) return;
    if (text_width == 0 or text_height == 0) @panic("framebuffer console must be at least 1x1");

    const old_width = width;
    const old_height = height;
    const old_cells = console_cells;
    const new_cell_count = text_width * text_height;
    cell_buffer = try allocator.alloc(Cell, new_cell_count);

    @memset(cell_buffer, makeCell(' ', console_attr));

    const copy_rows = @min(old_height, text_height);
    const copy_cols = @min(old_width, text_width);
    var row: u32 = 0;
    while (row < copy_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < copy_cols) : (col += 1) {
            const src_idx = row * old_width + col;
            const dst_idx = row * text_width + col;
            cell_buffer[dst_idx] = old_cells[src_idx];
        }
    }

    backend = .framebuf;
    vga.disableCursor();
    width = text_width;
    height = text_height;
    console_cell_count = new_cell_count;
    console_cells = cell_buffer.ptr;
    if (console_row >= height) console_row = height - 1;
    if (console_col >= width) console_col = width - 1;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (backend == .framebuf and cell_buffer.len > 0) {
        allocator.free(cell_buffer);
        cell_buffer.len = 0;
    }
}

/// Keep console output in RAM until the framebuffer console is ready.
pub fn enableBufferedBackend() void {
    if (backend != .vga) return;

    @memset(bootstrap_buffer[0..], makeCell(' ', console_attr));

    backend = .buffered;
    console_cells = &bootstrap_buffer;
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
    if (console_col >= width) {
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
