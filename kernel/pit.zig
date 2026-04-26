// Basic PIT (Programmable Interval Timer) functionality.

const std = @import("std");
const io = @import("io.zig");

const OperatingMode = enum(u3) {
    InterruptOnTerminalCount = 0,
    HardwareOneShot = 1,
    RateGenerator = 2,
    SquareWaveGenerator = 3,
    SoftwareStrobe = 4,
    HardwareStrobe = 5,
};

const AccessMode = enum(u2) {
    LatchCount = 0,
    Lo = 1, // low byte only
    Hi = 2, // high byte only
    LoHi = 3, // low byte followed by high byte
};

const CommandWord = packed struct(u8) {
    bcd: bool = false,
    operating_mode: OperatingMode,
    access_mode: AccessMode,
    channel: u2 = 0,
};

pub fn initRateGenerator(frequency_hz: u32) void {
    const channel = 0; // PIT channel 0
    var divisor = 1193182 / frequency_hz;
    if (divisor > std.math.maxInt(u16)) {
        divisor = 0; // interpreted as 65536, the maximum divisor, which gives ~18.2 Hz
    }
    io.outb(0x43, @bitCast(CommandWord{
        .operating_mode = .RateGenerator,
        .access_mode = .LoHi,
        .channel = channel,
    }));
    io.outb(0x40 + channel, @truncate(divisor & 0xFF)); // low byte
    io.outb(0x40 + channel, @truncate((divisor >> 8) & 0xFF)); // high byte
}

var ticks: u64 = 0;

const vga = @import("vgatext.zig");

export fn timer_irq_handler() callconv(.c) void {
    ticks += 1;
    vga.putCharAt(0, 79, @truncate(ticks & 0xFF), 0x07);
}
