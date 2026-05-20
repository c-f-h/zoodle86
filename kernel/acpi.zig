const console = @import("console.zig");
const paging = @import("paging.zig");
const apic = @import("apic.zig");
const io = @import("io.zig");

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

pub const AddressSpace = enum(u8) {
    SystemMemory = 0,
    SystemIO = 1,
    PCIConfigurationSpace = 2,
    EmbeddedController = 3,
    SMBus = 4,
    SystemCMOS = 5,
    PCIDeviceBarTarget = 6,
};

pub const GenericAddressStructure = extern struct {
    address_space: AddressSpace,
    bit_width: u8,
    bit_offset: u8,
    access_size: u8,
    address: u64,
};

/// Fixed ACPI Description Table (FADT)
pub const FADT = extern struct {
    header: SDTHeader,

    firmware_ctrl: u32,
    dsdt: u32,

    reserved: u8,
    preferred_pm_profile: u8,
    sci_interrupt: u16,
    smi_command_port: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_control: u8,
    pm1a_event_block: u32,
    pm1b_event_block: u32,
    pm1a_control_block: u32,
    pm1b_control_block: u32,
    pm2_control_block: u32,
    pm_timer_block: u32,
    gpe0_block: u32,
    gpe1_block: u32,
    pm1_event_length: u8,
    pm1_control_length: u8,
    pm2_control_length: u8,
    pm_timer_length: u8,
    gpe0_block_length: u8,
    gpe1_block_length: u8,
    gpe1_base: u8,
    c_state_control: u8,
    worst_c2_latency: u16,
    worst_c3_latency: u16,
    flush_size: u16,
    flush_stride: u16,
    duty_offset: u8,
    duty_width: u8,
    day_alarm: u8,
    month_alarm: u8,
    century: u8,

    boot_architecture_flags: u16,
    reserved2: u8,

    flags: u32,

    reset_reg: GenericAddressStructure,
    reset_value: u8,
    reserved3: [3]u8,

    x_firmware_control: u64,
    x_dsdt: u64,

    x_pm1a_event_block: GenericAddressStructure,
    x_pm1b_event_block: GenericAddressStructure,
    x_pm1a_control_block: GenericAddressStructure,
    x_pm1b_control_block: GenericAddressStructure,
    x_pm2_control_block: GenericAddressStructure,
    x_pm_timer_block: GenericAddressStructure,
    x_gpe0_block: GenericAddressStructure,
    x_gpe1_block: GenericAddressStructure,
};

var rsdt: *const SDTHeader = undefined;
var madt: ?*const MADT = null;
var fadt: ?*const FADT = null;

pub var pm_timer_port: u16 = 0;
pub var pm_timer_mask: u32 = 0;

fn scanRange(start: usize, end: usize) ?*const RSDP {
    const kernel_console = &console.primary;
    var ptr: [*]u8 = @ptrFromInt(start);
    while (@intFromPtr(ptr) < end) {
        if (std.mem.eql(u8, ptr[0..8], "RSD PTR ")) {
            kernel_console.put(.{ "Found RSDP at ", @intFromPtr(ptr), "\n" });
            return @ptrCast(@alignCast(ptr));
        }
        ptr += 16;
    }
    return null;
}

// Cursor for mapping ACPI tables into virtual memory
const initial_table_va: usize = 0xFC00_0000;
var next_table_va: usize = initial_table_va;
const final_table_va: usize = 0xFE00_0000; // for bounds checking
const max_table_length: u32 = 1024 * 1024;

fn validateTableLength(length: u32) void {
    if (length < @sizeOf(SDTHeader)) {
        @panic("ACPI table shorter than SDT header");
    }
    if (length > max_table_length) {
        @panic("ACPI table length is implausibly large");
    }
}

fn numPagesForTable(phys_addr: u32, length: u32) u32 {
    validateTableLength(length);

    const phys_end = @addWithOverflow(phys_addr, length);
    if (phys_end[1] != 0) {
        @panic("ACPI table physical range overflows");
    }

    return paging.numPagesBetween(phys_addr, phys_end[0]);
}

fn ensureMappingCapacity(additional_pages: u32) void {
    const additional_bytes = @as(usize, additional_pages) * paging.PAGE;
    if (next_table_va > final_table_va or additional_bytes > final_table_va - next_table_va) {
        @panic("ACPI tables too large for virtual memory");
    }
}

/// Map the ACPI table at the given physical address into virtual memory and return a pointer to it.
fn mapTable(phys_addr: u32) *const SDTHeader {
    const phys_page = phys_addr & ~paging.PAGE_MASK;
    const phys_offset = phys_addr & paging.PAGE_MASK;

    // Check previous table VA for possible reuse
    const prev_table_va = next_table_va - paging.PAGE;
    var header: *const SDTHeader = undefined;

    if (next_table_va > initial_table_va and paging.hasPte(prev_table_va) and paging.virtualToPhysical(@ptrFromInt(prev_table_va)) == phys_page) {
        // The last mapped page already has the physical address we need
        // (common with several small ACPI tables packed together in the same physical page)
        header = @ptrFromInt(prev_table_va + phys_offset);
    } else {
        // Different physical page (or none mapped yet), so create a new mapping
        ensureMappingCapacity(1);
        paging.mapContiguousRangeAt(next_table_va, phys_page, 1, false, false, false);
        header = @ptrFromInt(next_table_va + phys_offset);
        next_table_va += paging.PAGE;
    }

    // Is the table longer than 1 page? Then we need to map additional memory
    const total_pages = numPagesForTable(phys_addr, header.length);
    if (total_pages > 1) {
        ensureMappingCapacity(total_pages - 1);
        paging.mapContiguousRangeAt(next_table_va, phys_page + paging.PAGE, total_pages - 1, false, false, false);
        next_table_va += (total_pages - 1) * paging.PAGE;
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

fn printGAS(gas: GenericAddressStructure) void {
    const kernel_console = &console.primary;
    kernel_console.put(.{
        "space=",        @tagName(gas.address_space),
        " bit_width=",   gas.bit_width,
        " bit_offset=",  gas.bit_offset,
        " access_size=", gas.access_size,
        " address=0x",   gas.address,
        "\n",
    });
}

fn parseFadt(table: *const FADT) void {
    const kernel_console = &console.primary;
    kernel_console.put(.{ "    FADT found: DSDT: ", table.dsdt, " FACS: ", table.firmware_ctrl, "\n" });
    kernel_console.put(.{ "      SCI irq: ", table.sci_interrupt, " SMI port: 0x", table.smi_command_port, "\n" });
    kernel_console.put(.{ "      ACPI enable: 0x", table.acpi_enable, " disable: 0x", table.acpi_disable, "\n" });
    kernel_console.put(.{ "      PM1a event block: 0x", table.pm1a_event_block, " PM1a cntl block: 0x", table.pm1a_control_block, "\n" });
    kernel_console.put(.{ "      PM timer block: 0x", table.pm_timer_block, " length: ", table.pm_timer_length, "\n" });
    kernel_console.put(.{ "      GPE0 block: 0x", table.gpe0_block, " len: ", table.gpe0_block_length, "\n" });

    if (table.pm_timer_block != 0 and table.pm_timer_length == 4) {
        pm_timer_port = @truncate(table.pm_timer_block);
        pm_timer_mask = 0x00FFFFFF; // 24 bit by default
    }

    if (table.header.revision >= 2) {
        kernel_console.put(.{ "      flags: 0x", table.flags, " boot arch: 0x", table.boot_architecture_flags, "\n" });
        kernel_console.put(.{ "      reset reg: addr=0x", table.reset_reg.address, " value=0x", table.reset_value, "\n" });
        kernel_console.put(.{ "      preferred PM profile: ", table.preferred_pm_profile, "\n" });

        kernel_console.puts("      pm1a event GAS:   ");
        printGAS(table.x_pm1a_event_block);
        kernel_console.puts("      pm1a control GAS: ");
        printGAS(table.x_pm1a_control_block);
        kernel_console.puts("      pm timer GAS:     ");
        printGAS(table.x_pm_timer_block);

        if (pm_timer_port != 0 and table.flags & 0x100 != 0) {
            // 32 bit flag set for the timer?
            pm_timer_mask = 0xFFFFFFFF;
        }
    }
}

pub fn readPmTimer() u32 {
    if (pm_timer_port == 0) {
        @panic("No ACPI PM timer found");
    }
    return io.inl(pm_timer_port) & pm_timer_mask;
}

pub fn init() void {
    const kernel_console = &console.primary;
    kernel_console.puts("Scanning ACPI tables...\n");
    const ebda_short_ptr: *const u16 = @ptrFromInt(0x40E);
    const ebda_addr = @as(usize, ebda_short_ptr.*) << 4;
    const rsdp_from_ebda = if (ebda_addr != 0 and ebda_addr < 0x000A_0000)
        scanRange(ebda_addr, @min(ebda_addr + 1024, 0x000A_0000))
    else
        null;
    const rsdp =
        rsdp_from_ebda orelse
        scanRange(0x000E_0000, 0x0010_0000) orelse
        @panic("ACPI RSDP not found");
    kernel_console.put(.{ "RSDP OEMID: ", &rsdp.oemid, " revision: ", rsdp.revision, " RSDT address: ", rsdp.rsdt_address, "\n" });

    rsdt = mapTable(rsdp.rsdt_address);

    const rsdt_entries: [*]u32 = @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(SDTHeader));
    const num_entries = (rsdt.length - @sizeOf(SDTHeader)) / 4;

    kernel_console.put(.{ "RSDT OEMID: ", &rsdt.oemid, " revision: ", rsdt.revision, " num entries: ", num_entries, "\n" });
    for (rsdt_entries[0..num_entries]) |entry_phys_ptr| {
        const entry_header = mapTable(entry_phys_ptr);
        kernel_console.put(.{ "  Entry: ", &entry_header.signature, " OEMID: ", &entry_header.oemid, " length: ", entry_header.length, " revision: ", entry_header.revision, "\n" });
        if (std.mem.eql(u8, entry_header.signature[0..4], "FACP")) {
            fadt = @ptrCast(entry_header);
            parseFadt(fadt.?);
        } else if (std.mem.eql(u8, entry_header.signature[0..4], "APIC")) {
            madt = @ptrCast(entry_header);
            kernel_console.put(.{ "    MADT found: local APIC address: ", madt.?.local_apic_address, " flags: ", madt.?.flags, "\n" });
            apic.parseApicEntries(madt.?);
        }
    }

    apic.initApic();
}
