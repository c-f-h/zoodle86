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

pub fn initRateGenerator(channel: u8, mode: OperatingMode, divisor: u16) void {
    io.outb(0x43, @bitCast(CommandWord{
        .operating_mode = mode,
        .access_mode = .LoHi,
        .channel = @truncate(channel),
    }));
    io.outb(0x40 + channel, @truncate(divisor & 0xFF)); // low byte
    io.outb(0x40 + channel, @truncate((divisor >> 8) & 0xFF)); // high byte
}

fn getCurrentValue(channel: u8) u16 {
    io.outb(0x43, @bitCast(CommandWord{
        .operating_mode = .InterruptOnTerminalCount,
        .access_mode = .LatchCount,
        .channel = @truncate(channel),
    }));
    const low: u16 = io.inb(0x40 + channel);
    const high: u16 = io.inb(0x40 + channel);
    return (high << 8) | low;
}

fn busySleepTicks(count: u16) void {
    initRateGenerator(0, .InterruptOnTerminalCount, count);
    while (getCurrentValue(0) != 0) {}
}

pub fn busySleep(duration_ms: u32) void {
    var remaining_ticks: u64 = (@as(u64, duration_ms) * 1193182) / 1000;

    while (remaining_ticks != 0) {
        const chunk: u16 = @intCast(@min(remaining_ticks, std.math.maxInt(u16)));
        busySleepTicks(chunk);
        remaining_ticks -= chunk;
    }
}

var ticks: u32 = 0;

const vga = @import("vgatext.zig");

pub fn timer_irq_handler() void {
    ticks += 1;
    const attr: u8 = if ((ticks & 0x100) != 0) 0x70 else 0x07;
    vga.putCharAt(0, 79, @truncate(ticks & 0xFF), attr);
}
