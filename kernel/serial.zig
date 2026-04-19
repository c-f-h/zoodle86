const io = @import("io.zig");
const console = @import("console.zig");

const COM1_BASE: u16 = 0x3F8;
const REG_DATA: u16 = 0;
const REG_INTERRUPT_ENABLE: u16 = 1;
const REG_FIFO_CONTROL: u16 = 2;
const REG_LINE_CONTROL: u16 = 3;
const REG_MODEM_CONTROL: u16 = 4;
const REG_LINE_STATUS: u16 = 5;
const LINE_STATUS_TX_HOLDING_EMPTY: u8 = 1 << 5;

var initialized = false;

/// Initialize the COM1 UART for 38400 8N1 output.
pub fn init() void {
    io.outb(COM1_BASE + REG_INTERRUPT_ENABLE, 0x00);
    io.outb(COM1_BASE + REG_LINE_CONTROL, 0x80);
    io.outb(COM1_BASE + REG_DATA, 0x03);
    io.outb(COM1_BASE + REG_INTERRUPT_ENABLE, 0x00);
    io.outb(COM1_BASE + REG_LINE_CONTROL, 0x03);
    io.outb(COM1_BASE + REG_FIFO_CONTROL, 0xC7);
    io.outb(COM1_BASE + REG_MODEM_CONTROL, 0x0B);
    initialized = true;
}

/// Return whether the UART has been initialized.
pub fn isInitialized() bool {
    return initialized;
}

fn waitUntilWritable() void {
    while ((io.inb(COM1_BASE + REG_LINE_STATUS) & LINE_STATUS_TX_HOLDING_EMPTY) == 0) {}
}

fn putRaw(ch: u8) void {
    if (!initialized) return;
    waitUntilWritable();
    io.outb(COM1_BASE + REG_DATA, ch);
}

/// Write one byte to COM1.
pub fn putch(ch: u8) void {
    if (ch == '\n') {
        putRaw('\r');
    }
    putRaw(ch);
}

/// Write a byte slice to COM1.
pub fn puts(s: []const u8) void {
    for (s) |ch| {
        putch(ch);
    }
}

const formatHexU = console.formatHexU;

/// Write a u8 as hexadecimal to COM1.
pub fn putHexU8(value: u8) void {
    var str: [2]u8 = undefined;
    formatHexU(1, value, &str);
    puts(&str);
}

/// Write a u16 as hexadecimal to COM1.
pub fn putHexU16(value: u16) void {
    var str: [4]u8 = undefined;
    formatHexU(2, value, &str);
    puts(&str);
}

/// Write a u32 as hexadecimal to COM1.
pub fn putHexU32(value: u32) void {
    var str: [8]u8 = undefined;
    formatHexU(4, value, &str);
    puts(&str);
}
