pub const TEXT_WIDTH: u32 = 80;
pub const TEXT_HEIGHT: u32 = 25;

const VGA_BASE: usize = 0xB8000;
const VGA_CRTC_INDEX: u16 = 0x3D4;
const VGA_CRTC_DATA: u16 = 0x3D5;

const vga: *volatile [TEXT_HEIGHT * TEXT_WIDTH]u16 =
    @ptrFromInt(VGA_BASE);

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

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
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, inb(VGA_CRTC_DATA) & ~@as(u8, 0x20));
}

pub fn disableCursor() void {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, inb(VGA_CRTC_DATA) | 0x20);
}

pub fn setCursorSize(cursor_start: u8, cursor_end: u8) void {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, cursor_start);
    outb(VGA_CRTC_INDEX, 0x0B);
    outb(VGA_CRTC_DATA, cursor_end);
}

pub fn setCursorPos(row: u32, col: u32) void {
    const pos: u16 = @intCast(row * TEXT_WIDTH + col);
    outb(VGA_CRTC_INDEX, 0x0E);
    outb(VGA_CRTC_DATA, @truncate(pos >> 8));
    outb(VGA_CRTC_INDEX, 0x0F);
    outb(VGA_CRTC_DATA, @truncate(pos & 0xFF));
}
