const io = @import("io.zig");
const console = @import("console.zig");
const std = @import("std");
const ide = @import("ide.zig");

const CONFIG_ADDRESS = 0xCF8;
const CONFIG_DATA = 0xCFC;
const BUS_COUNT = 256;

const PciAddress = packed struct {
    register: u8,
    function: u3,
    device: u5,
    bus: u8,
    reserved: u7 = 0,
    enable: u1 = 1,
};

const PciHeader = extern struct {
    vendor_id: u16,
    device_id: u16,
    command: u16,
    status: u16,
    revision_id: u8,
    prog_if: u8,
    sub_class: u8,
    base_class: u8,
    cache_line_size: u8,
    latency_timer: u8,
    header_type: u8,
    bist: u8,
};

const GeneralDevice = extern struct {
    bar: [6]u32,
    cardbus_cis_pointer: u32,
    subsystem_vendor_id: u16,
    subsystem_id: u16,
    expansion_rom_base_address: u32,
    capabilties_pointers: u8,
    reserved: [7]u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    min_grant: u8,
    max_latency: u8,
};

const CommandRegister = packed struct {
    io_space: bool,
    memory_space: bool,
    bus_master: bool,
    special_cycles: bool,
    memory_write_invalidate: bool,
    vga_palette_snoop: bool,
    parity_error_response: bool,
    reserved0: bool,
    serr_enable: bool,
    fast_back_to_back_enable: bool,
    interrupt_disable: bool,
    reserved1: u5,
};

const StatusRegister = packed struct {
    reserved0: u3,
    interrupt_status: bool,
    capabilities_list: bool,
    capable_66mhz: bool,
    reserved1: bool,
    fast_back_to_back_capable: bool,
    master_data_parity_error: bool,
    devsel_timing: u2,
    signaled_target_abort: bool,
    received_target_abort: bool,
    received_master_abort: bool,
    signaled_system_error: bool,
    detected_parity_error: bool,
};

fn readMem(bus: u8, device: u5, function: u3, ofs: u8, mem: []u8) void {
    if (mem.len % 4 != 0) @panic("invalid PCI memory read size");
    var addr = PciAddress{
        .register = ofs,
        .function = function,
        .device = device,
        .bus = bus,
    };
    var ptr: [*]u32 = @ptrCast(@alignCast(mem));
    var i: usize = 0;
    while (i < mem.len) : (i += 4) {
        io.outl(CONFIG_ADDRESS, @bitCast(addr));
        ptr[0] = io.inl(CONFIG_DATA);
        ptr += 1;
        addr.register += 4;
    }
}

fn read32(bus: u8, device: u5, function: u3, register: u8) u32 {
    io.outl(CONFIG_ADDRESS, @bitCast(PciAddress{
        .register = register,
        .function = function,
        .device = device,
        .bus = bus,
    }));
    return io.inl(CONFIG_DATA);
}

fn read16(bus: u8, device: u5, function: u3, register: u8) u16 {
    const offset: u5 = @truncate((register & 0b10) * 8); // either high or low word
    return @truncate(read32(bus, device, function, register & 0b11111100) >> offset);
}

fn read8(bus: u8, device: u5, function: u3, register: u8) u8 {
    const offset: u5 = @truncate((register & 0b11) * 8); // one of four bytes
    return @truncate(read32(bus, device, function, register & 0b11111100) >> offset);
}

fn getVendorId(bus: u8, device: u5, function: u3) u16 {
    return read16(bus, device, function, 0x00);
}

fn getHeaderType(bus: u8, device: u5, function: u3) u8 {
    return read8(bus, device, function, 0x0E);
}

fn getSecondaryBus(bus: u8, device: u5, function: u3) u8 {
    return read8(bus, device, function, 0x19);
}

fn write32(bus: u8, device: u5, function: u3, ofs: u8, value: u32) void {
    io.outl(CONFIG_ADDRESS, @bitCast(PciAddress{
        .register = ofs,
        .function = function,
        .device = device,
        .bus = bus,
    }));
    io.outl(CONFIG_DATA, value);
}

fn writeCommandAndStatus(bus: u8, device: u5, function: u3, cmd: CommandRegister, status: StatusRegister) void {
    const cmd_u32: u32 = @bitCast(cmd);
    const status_u32: u32 = @bitCast(status);
    write32(bus, device, function, 0x04, status_u32 << 16 | cmd_u32);
}

fn readBar(bus: u8, device: u5, function: u3, index: u3) u32 {
    return read32(bus, device, function, @sizeOf(PciHeader) + @as(u8, index) * 4);
}

fn writeBar(bus: u8, device: u5, function: u3, index: u3, value: u32) void {
    write32(bus, device, function, @sizeOf(PciHeader) + @as(u8, index) * 4, value);
}

const BaseClass = enum(u8) {
    Unclassified = 0x0,
    MassStorage = 0x1,
    Network = 0x2,
    Display = 0x3,
    Multimedia = 0x4,
    Memory = 0x5,
    Bridge = 0x6,
    SimpleCommunication = 0x7,
    BaseSystemPeripheral = 0x8,
    InputDevice = 0x9,
    DockingStation = 0xA,
    Processor = 0xB,
    SerialBus = 0xC,
    Wireless = 0xD,
    IntelligentIO = 0xE,
    SatelliteCommunication = 0xF,
    EncryptionController = 0x10,
    SignalProcessingController = 0x11,
};

// Subclasses:
// Mass Storage
const SUB_MASSSTORAGE_IDE = 0x1;
const SUB_MASSSTORAGE_FLOPPY = 0x2;
const SUB_MASSSTORAGE_ATA = 0x5;
const SUB_MASSSTORAGE_SATA = 0x6;
const SUB_MASSSTORAGE_NVME = 0x8;

// Network
const SUB_NETWORK_ETHERNET = 0x0;
const SUB_NETWORK_WIFI = 0x80;

// Display
const SUB_DISPLAY_VGA = 0x0;
const SUB_DISPLAY_XGA = 0x1;

// Bridge
const SUB_BRIDGE_PCITOPCI = 0x4;

fn scanFunction(con: *console.Console, visited: *[BUS_COUNT]bool, bus: u8, device: u5, function: u3) void {
    var hdr: PciHeader = undefined;
    readMem(bus, device, function, 0, std.mem.asBytes(&hdr));

    if ((hdr.base_class == @intFromEnum(BaseClass.Bridge)) and (hdr.sub_class == SUB_BRIDGE_PCITOPCI)) {
        // PCI-to-PCI bridge, scan secondary bus
        const secondary_bus = getSecondaryBus(bus, device, function);
        scanBus(con, visited, secondary_bus);
    }

    con.put(.{
        "PCI ",           bus,
        ":",              @as(u8, device),
        ":",              @as(u4, function),
        " - Vendor ID: ", hdr.vendor_id,
        ", Device ID: ",  hdr.device_id,
        " Class: ",       hdr.base_class,
        ".",              hdr.sub_class,
        " Prog IF: ",     hdr.prog_if,
        " Command: ",     hdr.command,
        " Status: ",      hdr.status,
        "\n",
    });

    if (hdr.header_type & 0x7F == 0x00) {
        // Type 0: normal device, can have BARs
        var info: GeneralDevice = undefined;
        readMem(bus, device, function, @intCast(@sizeOf(PciHeader)), std.mem.asBytes(&info));
        //con.put(.{ "  Interrupt Line: ", info.interrupt_line, ", Interrupt Pin: ", info.interrupt_pin, "\n" });

        for (0..6) |i| {
            const bar = info.bar[i];
            if (bar != 0) {
                // determine size of address space
                writeBar(bus, device, function, @truncate(i), 0xFFFFFFFF);
                const size = ~(readBar(bus, device, function, @truncate(i)) & 0xFFFF_FFFC) + 1;
                // restore original BAR value
                writeBar(bus, device, function, @truncate(i), bar);

                con.put(.{ "  BAR ", @as(u4, @truncate(i)), ": ", bar, ", size: ", size, "\n" });
            }
        }

        // detect DMA ports for IDE controller
        if (hdr.base_class == @intFromEnum(BaseClass.MassStorage) and
            hdr.sub_class == SUB_MASSSTORAGE_IDE)
        {
            if (info.bar[0] != 0) ide.Primary.io_base = @truncate(info.bar[0] & 0xFFFF_FFFC);
            if (info.bar[1] != 0) ide.Primary.control_base = @truncate(info.bar[1] & 0xFFFF_FFFC);
            if (info.bar[2] != 0) ide.Secondary.io_base = @truncate(info.bar[2] & 0xFFFF_FFFC);
            if (info.bar[3] != 0) ide.Secondary.control_base = @truncate(info.bar[3] & 0xFFFF_FFFC);

            if (hdr.prog_if & 0x80 != 0 and // busmastering supported
                info.bar[4] != 0 and // busmaster BAR present
                info.bar[4] & 0x01 != 0) // busmaster BAR is I/O space
            {
                // Enable PCI bus mastering so DMA transfers work
                if (hdr.command & 0x04 == 0) {
                    const cur_csr = read32(bus, device, function, 0x04);
                    const new_cmd = cur_csr | 0x04; // set bit 2 (Bus Master)
                    write32(bus, device, function, 0x04, new_cmd);
                }

                // Save the base addresses for both IDE channels
                ide.Primary.busmaster_base = @truncate(info.bar[4] & 0xFFFF_FFFC);
                ide.Secondary.busmaster_base = ide.Primary.busmaster_base + 8;
            }
        }
    }
}

fn scanDevice(con: *console.Console, visited: *[BUS_COUNT]bool, bus: u8, device: u5) void {
    const vendor_id = getVendorId(bus, device, 0);
    if (vendor_id != 0xFFFF) {
        scanFunction(con, visited, bus, device, 0);
        const header_type = getHeaderType(bus, device, 0);

        if ((header_type & 0x80) != 0) {
            // Multi-function device, scan remaining functions
            for (1..8) |function| {
                if (getVendorId(bus, device, @truncate(function)) != 0xFFFF) {
                    scanFunction(con, visited, bus, device, @truncate(function));
                }
            }
        }
    }
}

fn scanBus(con: *console.Console, visited: *[BUS_COUNT]bool, bus: u8) void {
    if (visited[bus]) {
        return;
    }
    visited[bus] = true;

    for (0..32) |device| {
        scanDevice(con, visited, bus, @truncate(device));
    }
}

pub fn scan(con: *console.Console) void {
    var visited = [_]bool{false} ** BUS_COUNT;
    const root_vendor_id = getVendorId(0, 0, 0);

    if (root_vendor_id == 0xFFFF) {
        return;
    }

    const root_header_type = getHeaderType(0, 0, 0);
    // Check for single-function host controller (most common case)
    if ((root_header_type & 0x80) == 0) {
        scanBus(con, &visited, 0);
        return;
    }

    // On systems with multiple host controllers, each function of 0:0 maps to a root bus.
    for (0..8) |function| {
        if (getVendorId(0, 0, @truncate(function)) != 0xFFFF) {
            scanBus(con, &visited, @truncate(function));
        }
    }
}
