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

fn disablePic() void {
    // mask all IRQs on legacy PIC
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

fn setupKeyboardApic(ioapic_base: usize) void {
    const keyboard_gsi: u32 = getRemappedGSI(0, 1); // bus 0 (ISA), IRQ 1 is keyboard
    const vector = 0x21; // IDT entry which handles keyboard interrupts

    const lapic_id: u8 = 0;
    ioapicSetRedir(ioapic_base, keyboard_gsi, vector, lapic_id);
}

pub export fn lapic_eoi() callconv(.c) void {
    const EOI = 0xB0;
    lapicWrite(lapic_va, EOI, 0);
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

    setupKeyboardApic(ioapic_va);
}
