const io = @import("io.zig");

pub const TEXT_WIDTH: u32 = 80;
pub const TEXT_HEIGHT: u32 = 25;

const VGA_BASE: usize = 0xB8000;
const VGA_CRTC_INDEX: u16 = 0x3D4;
const VGA_CRTC_DATA: u16 = 0x3D5;

const vga: *volatile [TEXT_HEIGHT * TEXT_WIDTH]u16 =
    @ptrFromInt(VGA_BASE);

pub fn putCharAt(row: u32, col: u32, ch: u8, attr: u8) void {
    vga[row * TEXT_WIDTH + col] = (@as(u16, attr) << 8) | ch;
}

pub fn readCell(row: u32, col: u32) u16 {
    return vga[row * TEXT_WIDTH + col];
}

pub fn clear(attr: u8) void {
    const blank: u16 = (@as(u16, attr) << 8) | ' ';
    @memset(vga, blank);
}

pub fn enableCursor() void {
    io.outb(VGA_CRTC_INDEX, 0x0A);
    io.outb(VGA_CRTC_DATA, io.inb(VGA_CRTC_DATA) & ~@as(u8, 0x20));
}

pub fn disableCursor() void {
    io.outb(VGA_CRTC_INDEX, 0x0A);
    io.outb(VGA_CRTC_DATA, io.inb(VGA_CRTC_DATA) | 0x20);
}

pub fn setCursorSize(cursor_start: u8, cursor_end: u8) void {
    io.outb(VGA_CRTC_INDEX, 0x0A);
    io.outb(VGA_CRTC_DATA, cursor_start);
    io.outb(VGA_CRTC_INDEX, 0x0B);
    io.outb(VGA_CRTC_DATA, cursor_end);
}

pub fn setCursorPos(row: u32, col: u32) void {
    const pos: u16 = @intCast(row * TEXT_WIDTH + col);
    io.outb(VGA_CRTC_INDEX, 0x0E);
    io.outb(VGA_CRTC_DATA, @truncate(pos >> 8));
    io.outb(VGA_CRTC_INDEX, 0x0F);
    io.outb(VGA_CRTC_DATA, @truncate(pos & 0xFF));
}
