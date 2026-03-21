const c = @cImport({
    @cInclude("vgatext.h");
});

var console_row: u32 = 0;
var console_col: u32 = 0;
var console_attr: u8 = 0x07;

fn syncCursor() void {
    c.vga_set_cursor_pos(console_row, console_col);
}

fn scrollIfNeeded() void {
    if (console_row < c.VGA_TEXT_HEIGHT) return;

    var row: u32 = 1;
    while (row < c.VGA_TEXT_HEIGHT) : (row += 1) {
        var col: u32 = 0;
        while (col < c.VGA_TEXT_WIDTH) : (col += 1) {
            const cell: u16 = c.vga_read_cell(row, col);
            c.vga_put_char_at(row - 1, col, @truncate(cell & 0x00FF), @truncate(cell >> 8));
        }
    }

    var col: u32 = 0;
    while (col < c.VGA_TEXT_WIDTH) : (col += 1) {
        c.vga_put_char_at(c.VGA_TEXT_HEIGHT - 1, col, ' ', console_attr);
    }

    console_row = c.VGA_TEXT_HEIGHT - 1;
}

fn advanceLine() void {
    console_col = 0;
    console_row += 1;
    scrollIfNeeded();
}

pub export fn console_init(attr: u8) callconv(.c) void {
    console_attr = attr;
    console_row = 0;
    console_col = 0;
    c.vga_enable_cursor();
    c.vga_clear(console_attr);
    syncCursor();
}

pub fn clear() void {
    c.vga_clear(console_attr);
    console_row = 0;
    console_col = 0;
    syncCursor();
}

pub fn setCursor(row: u32, col: u32) void {
    console_row = if (row >= c.VGA_TEXT_HEIGHT) c.VGA_TEXT_HEIGHT - 1 else row;
    console_col = if (col >= c.VGA_TEXT_WIDTH) c.VGA_TEXT_WIDTH - 1 else col;
    syncCursor();
}

pub fn setAttr(attr: u8) void {
    console_attr = attr;
}

pub fn newline() void {
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
            console_col = 0;
            syncCursor();
            return;
        },
        else => {},
    }

    c.vga_put_char_at(console_row, console_col, ch, console_attr);
    console_col += 1;
    if (console_col >= c.VGA_TEXT_WIDTH) {
        advanceLine();
    }
    syncCursor();
}

pub fn puts(s: []const u8) void {
    for (s) |ch| {
        putch(ch);
    }
}

pub fn putHexU8(value: u8) void {
    const hex = "0123456789ABCDEF";
    putch(hex[(value >> 4) & 0x0F]);
    putch(hex[value & 0x0F]);
}

pub fn putHexU32(value: u32) void {
    const hex = "0123456789ABCDEF";
    var shift: i6 = 28;
    while (shift >= 0) : (shift -= 4) {
        putch(hex[(value >> @intCast(shift)) & 0x0F]);
    }
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
