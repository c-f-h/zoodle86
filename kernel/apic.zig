const io = @import("io.zig");
const acpi = @import("acpi.zig");
const console = @import("console.zig");
const paging = @import("paging.zig");

// Virtual addresses where we will map the Local APIC and I/O APIC MMIO regions.
const lapic_va = 0xFEE0_0000;
const ioapic_va = 0xFEC0_0000;

// Physical addresses of the Local APIC and I/O APIC MMIO regions, read from the MADT.
var lapic_mmio_base: u32 = 0; // same physical address for every CPU
var ioapic_mmio_base: u32 = 0; // MMIO base address for the GSI 0-31 I/O APIC

/// Count of LAPIC spurious interrupts observed since boot.
pub extern var spurious_irq_count: u32;

// Mappings from IRQs to GSIs, read from the MADT's Interrupt Source Override entries.
const InterruptSourceOverride = struct {
    bus_source: u8,
    irq_source: u8,
    global_system_interrupt: u32,
    flags: u16,
};

var isos: [32]InterruptSourceOverride = undefined;
var iso_count: u8 = 0;

pub fn parseApicEntries(p_madt: *const acpi.MADT) void {
    const bytes: [*]const u8 = @ptrCast(p_madt);
    var offset: usize = @sizeOf(acpi.MADT);

    lapic_mmio_base = p_madt.local_apic_address;

    while (offset < p_madt.header.length) {
        const entry_type = bytes[offset];
        const entry_len = bytes[offset + 1];
        console.put(.{ "    APIC Entry type: ", entry_type, " length: ", entry_len, "\n" });

        switch (entry_type) {
            0 => { // Processor Local APIC
                const proc_id = bytes[offset + 2];
                const local_apic_id = bytes[offset + 3];
                const flagsptr: [*]u32 = @ptrFromInt(@intFromPtr(bytes) + offset + 4);
                const flags = flagsptr[0];
                console.put(.{ "      Local APIC ID: ", local_apic_id, " processor: ", proc_id, " flags: ", flags, "\n" });
            },
            1 => { // I/O APIC
                const io_apic_id = bytes[offset + 3];
                const addrptr: [*]u32 = @ptrFromInt(@intFromPtr(bytes) + offset + 4);
                const io_apic_address = addrptr[0];
                const global_base = addrptr[1];

                if (global_base == 0) {
                    // For now, map only the I/O APIC for GSI base 0 - we check that at least 16 entries are present
                    ioapic_mmio_base = io_apic_address;
                }
                console.put(.{ "      I/O APIC ID: ", io_apic_id, " address: ", io_apic_address, " global base: ", global_base, "\n" });
            },
            2 => { // Interrupt Source Override
                const bus_source = bytes[offset + 2];
                const irq_source = bytes[offset + 3];
                const irqptr: *u32 = @ptrFromInt(@intFromPtr(bytes) + offset + 4);
                const global_system_interrupt = irqptr.*;
                const flagsptr: *u16 = @ptrFromInt(@intFromPtr(bytes) + offset + 8);
                const flags = flagsptr.*;

                if (iso_count < isos.len) {
                    isos[iso_count] = InterruptSourceOverride{
                        .bus_source = bus_source,
                        .irq_source = irq_source,
                        .global_system_interrupt = global_system_interrupt,
                        .flags = flags,
                    };
                    iso_count += 1;
                }

                console.put(.{ "      Interrupt Source Override: bus ", bus_source, " irq ", irq_source, " -> GSI ", global_system_interrupt, " flags: ", flags, "\n" });
            },
            4 => { // Local APIC NMI
                const local_apic_id = bytes[offset + 3];
                const flagsptr: *u16 = @ptrFromInt(@intFromPtr(bytes) + offset + 4);
                const flags = flagsptr.*;
                const local_apic_lint = bytes[offset + 5];
                console.put(.{ "      Local APIC NMI: local APIC ID ", local_apic_id, " flags: ", flags, " LINT#: ", local_apic_lint, "\n" });
            },
            else => {},
        }

        offset += entry_len;
    }
}

const LAPIC_ID = 0x20;

// LAPIC Timer Registers
const LAPIC_LVT_TIMER = 0x320; // Local Vector Table Timer Register
const LAPIC_TIMER_INITIAL = 0x380; // Timer Initial Count Register
const LAPIC_TIMER_CURRENT = 0x390; // Timer Current Count Register
const LAPIC_TIMER_DIVIDE = 0x3E0; // Timer Divide Configuration Register

const IOAPIC_REGSEL = 0x00;
const IOAPIC_WINDOW = 0x10;

inline fn lapicRead(base: usize, offset: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(base + offset)).*;
}

inline fn lapicWrite(base: usize, offset: u32, value: u32) void {
    @as(*volatile u32, @ptrFromInt(base + offset)).* = value;
}

inline fn ioapicWrite(base: usize, reg: u32, value: u32) void {
    const sel: *volatile u32 = @ptrFromInt(base + IOAPIC_REGSEL);
    const win: *volatile u32 = @ptrFromInt(base + IOAPIC_WINDOW);

    sel.* = reg;
    win.* = value;
}

inline fn ioapicRead(base: usize, reg: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(base + IOAPIC_REGSEL);
    const win: *volatile u32 = @ptrFromInt(base + IOAPIC_WINDOW);

    sel.* = reg;
    return win.*;
}

fn testLocalApic(lapic_base: u32, expected_id: u32) void {
    const id = lapicRead(lapic_base, LAPIC_ID);
    const apic_id = id >> 24;

    //const version = lapicRead(lapic_base, 0x30) & 0xFF;
    //console.put(.{ "LAPIC version: ", version, " ID raw: ", id, " LAPIC ID: ", apic_id, "\n" });

    if (apic_id != expected_id) {
        @panic("Unexpected LAPIC ID");
    }
}

fn testIoApic(ioapic_base: usize, min_num_entries: u32) void {
    const ver = ioapicRead(ioapic_base, 0x01);
    const max_entry = (ver >> 16) & 0xFF;

    //console.put(.{ "IOAPIC version: ", version & 0xFF, " max redirection entry index: ", max_entry, "\n" });

    if (max_entry + 1 < min_num_entries) {
        @panic("Not enough I/O APIC redirection entries");
    }
}

/// Remap the legacy PIC to the vectors 0x20-0x2F and mask all IRQs.
/// It may still generate spurious IRQs in this range on some hardware.
fn disablePic() void {
    // Remap PICs to vectors 0x20-0x2F and mask all IRQs
    // PIC1 handles IRQs 0-7 -> vectors 0x20-0x27
    // PIC2 handles IRQs 8-15 -> vectors 0x28-0x2F

    // ICW1: Initialize both PICs
    io.outb(0x20, 0x11); // PIC1 command port
    io.outb(0xA0, 0x11); // PIC2 command port

    // ICW2: Set interrupt vector offsets
    io.outb(0x21, 0x20); // PIC1: base vector = 0x20
    io.outb(0xA1, 0x28); // PIC2: base vector = 0x28

    // ICW3: Configure cascade mode
    io.outb(0x21, 0x04); // PIC1: slave on IR2
    io.outb(0xA1, 0x02); // PIC2: slave ID = 2

    // ICW4: Set 8086 mode
    io.outb(0x21, 0x01); // PIC1: 8086 mode
    io.outb(0xA1, 0x01); // PIC2: 8086 mode

    // Mask all IRQs on both PICs
    io.outb(0x21, 0xFF); // PIC1 data port
    io.outb(0xA1, 0xFF); // PIC2 data port
}

fn enableLocalApic(lapic_base: usize) void {
    const SVR = 0xF0; // Spurious Interrupt Vector Register
    const ENABLE = 1 << 8;
    const TPR = 0x80; // Task Priority Register

    lapicWrite(lapic_base, TPR, 0x00); // allow all interrupts
    lapicWrite(lapic_base, SVR, ENABLE | 0xFF); // spurious interrupts -> vector 0xFF
}

/// IF the IRQ appears in the GSI remappings, return the remapped GSI; otherwise, return the original IRQ.
fn getRemappedGSI(bus: u8, irq: u8) u32 {
    for (isos[0..iso_count]) |*iso| {
        if (iso.bus_source == bus and iso.irq_source == irq) {
            return iso.global_system_interrupt;
        }
    }
    return irq; // identity mapping if no override
}

fn ioapicSetRedir(ioapic_base: usize, gsi: u32, vector: u8, lapic_id: u8) void {
    const reg = 0x10 + gsi * 2;

    var low: u32 = 0;
    low |= vector; // bits 0–7
    // rest = 0 -> fixed delivery, physical, edge, active high

    const high: u32 = (@as(u32, lapic_id) << 24);

    // write high first, then low
    ioapicWrite(ioapic_base, reg + 1, high);
    ioapicWrite(ioapic_base, reg + 0, low);
}

pub fn assignInterruptVector(bus: u8, irq: u8, vector: u8) void {
    const ioapic_base = ioapic_va; // TODO: support multiple I/O APICs
    const gsi: u32 = getRemappedGSI(bus, irq);
    if (gsi >= 16) { // guaranteed by testIoApic
        @panic("GSI out of range for initial I/O APIC");
    }
    const lapic_id: u8 = 0;
    ioapicSetRedir(ioapic_base, gsi, vector, lapic_id);
}

pub export fn lapic_eoi() callconv(.c) void {
    const EOI = 0xB0;
    lapicWrite(lapic_va, EOI, 0);
}

const TIMER_MODE_PERIODIC: u32 = 1 << 17;
const TIMER_MASKED: u32 = 1 << 16;

pub const Divider = enum(u8) {
    div1 = 0x00,
    div2 = 0x01,
    div4 = 0x02,
    div16 = 0x03,
    div32 = 0x08,
    div64 = 0x09,
    div128 = 0x0A,
    div256 = 0x0B,
};

/// Initialize the APIC timer with the specified interrupt vector.
/// This configures the timer to use periodic mode (not one-shot).
pub fn initTimer(vector: u8, divider: Divider) void {
    // Set divide configuration: divide by 16
    setTimerDivider(divider);

    // Set up LVT Timer register: periodic mode, masked, vector
    lapicWrite(lapic_va, LAPIC_LVT_TIMER, TIMER_MASKED | TIMER_MODE_PERIODIC | vector);

    // Clear the counter
    lapicWrite(lapic_va, LAPIC_TIMER_INITIAL, 0);
}

/// Start the APIC timer with the given initial count.
/// The timer will decrement and fire interrupts at the configured vector.
pub fn startTimer(initial_count: u32) void {
    // Unmask the timer interrupt by clearing bit 16 of the LVT Timer register
    const lvt_current = lapicRead(lapic_va, LAPIC_LVT_TIMER);
    lapicWrite(lapic_va, LAPIC_LVT_TIMER, lvt_current & ~TIMER_MASKED);

    // Set the initial count to start the timer
    lapicWrite(lapic_va, LAPIC_TIMER_INITIAL, initial_count);
}

/// Stop the APIC timer by masking its interrupt.
pub fn stopTimer() void {
    const lvt_current = lapicRead(lapic_va, LAPIC_LVT_TIMER);
    lapicWrite(lapic_va, LAPIC_LVT_TIMER, lvt_current | TIMER_MASKED);
}

/// Get the current count of the APIC timer.
pub fn getTimerCurrentCount() u32 {
    return lapicRead(lapic_va, LAPIC_TIMER_CURRENT);
}

/// Set the APIC timer divide configuration.
pub inline fn setTimerDivider(divider: Divider) void {
    lapicWrite(lapic_va, LAPIC_TIMER_DIVIDE, @intFromEnum(divider) & 0x0F);
}

pub fn initApic() void {
    if (lapic_mmio_base == 0) {
        @panic("No Local APIC MMIO base found in MADT");
    } else {
        paging.mapContiguousRangeAt(lapic_va, lapic_mmio_base, 1, false, true, true); // disable caching!
    }
    if (ioapic_mmio_base == 0) {
        @panic("No I/O APIC MMIO base found in MADT");
    } else {
        paging.mapContiguousRangeAt(ioapic_va, ioapic_mmio_base, 1, false, true, true); // disable caching!
    }

    testLocalApic(lapic_va, 0);
    testIoApic(ioapic_va, 16); // want at least IRQs 0-15

    disablePic();
    enableLocalApic(lapic_va);
}
