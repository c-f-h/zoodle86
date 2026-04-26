const console = @import("console.zig");
const paging = @import("paging.zig");
const apic = @import("apic.zig");

const std = @import("std");

const RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oemid: [6]u8,
    revision: u8,
    rsdt_address: u32,
};

const SDTHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oemid: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

pub const MADT = extern struct {
    header: SDTHeader,
    local_apic_address: u32,
    flags: u32,
    // followed by variable-length entries
};

var rsdt: *const SDTHeader = undefined;
var madt: ?*const MADT = null;

fn scanRange(start: usize, end: usize) ?*const RSDP {
    var ptr: [*]u8 = @ptrFromInt(start);
    while (@intFromPtr(ptr) < end) {
        if (std.mem.eql(u8, ptr[0..8], "RSD PTR ")) {
            console.put(.{ "Found RSDP at ", @intFromPtr(ptr), "\n" });
            return @ptrCast(@alignCast(ptr));
        }
        ptr += 16;
    }
    return null;
}

// Cursor for mapping ACPI tables into virtual memory
var next_table_va: usize = 0xFC00_0000;
const final_table_va: usize = 0xFE00_0000; // for bounds checking

/// Map the ACPI table at the given physical address into virtual memory and return a pointer to it.
fn mapTable(phys_addr: u32) *const SDTHeader {
    const phys_page = phys_addr & ~paging.PAGE_MASK;
    const phys_offset = phys_addr & paging.PAGE_MASK;

    paging.mapContiguousRangeAt(next_table_va, phys_page, 1, false, false, false);
    const header: *const SDTHeader = @ptrFromInt(next_table_va + phys_offset);
    next_table_va += paging.PAGE;

    // Is the table longer than 1 page? Then we need to map additional memory
    const total_pages = paging.numPagesBetween(phys_addr, phys_addr + header.length);
    if (total_pages > 1) {
        paging.mapContiguousRangeAt(next_table_va, phys_page + paging.PAGE, total_pages - 1, false, false, false);
        next_table_va += (total_pages - 1) * paging.PAGE;
    }

    if (next_table_va > final_table_va) {
        @panic("ACPI tables too large for virtual memory");
    }
    verifyChecksum(header);

    return header;
}

fn verifyChecksum(header: *const SDTHeader) void {
    const bytes: [*]const u8 = @ptrCast(header);
    var sum: u8 = 0;
    for (bytes[0..header.length]) |b| {
        sum += b;
    }
    if (sum != 0) {
        @panic("Invalid ACPI table checksum");
    }
}

pub fn init() void {
    console.puts("Scanning ACPI tables...\n");
    const ebda_short_ptr: *const u16 = @ptrFromInt(0x40E);
    const ebda_addr = @intFromPtr(ebda_short_ptr) << 4;
    const rsdp =
        scanRange(ebda_addr, 0x000A_0000) orelse
        scanRange(0x000E_0000, 0x0010_0000) orelse
        @panic("ACPI RSDP not found");
    console.put(.{ "RSDP OEMID: ", &rsdp.oemid, " revision: ", rsdp.revision, " RSDT address: ", rsdp.rsdt_address, "\n" });

    rsdt = mapTable(rsdp.rsdt_address);

    const rsdt_entries: [*]u32 = @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(SDTHeader));
    const num_entries = (rsdt.length - @sizeOf(SDTHeader)) / 4;

    console.put(.{ "RSDT OEMID: ", &rsdt.oemid, " revision: ", rsdt.revision, " num entries: ", num_entries, "\n" });
    for (rsdt_entries[0..num_entries]) |entry_phys_ptr| {
        const entry_header = mapTable(entry_phys_ptr);
        console.put(.{ "  Entry: ", &entry_header.signature, " OEMID: ", &entry_header.oemid, " length: ", entry_header.length, " revision: ", entry_header.revision, "\n" });
        if (std.mem.eql(u8, entry_header.signature[0..4], "APIC")) {
            madt = @ptrCast(entry_header);
            console.put(.{ "    MADT found: local APIC address: ", madt.?.local_apic_address, " flags: ", madt.?.flags, "\n" });
            apic.parseApicEntries(madt.?);
        }
    }

    apic.initApic();
}
