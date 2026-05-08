const io = @import("io.zig");
const console = @import("console.zig");

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

fn getBaseClass(bus: u8, device: u5, function: u3) u8 {
    return read8(bus, device, function, 0x0B);
}

fn getSubClass(bus: u8, device: u5, function: u3) u8 {
    return read8(bus, device, function, 0x0A);
}

fn getSecondaryBus(bus: u8, device: u5, function: u3) u8 {
    return read8(bus, device, function, 0x19);
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
    const base_class = getBaseClass(bus, device, function);
    const sub_class = getSubClass(bus, device, function);

    if ((base_class == @intFromEnum(BaseClass.Bridge)) and (sub_class == SUB_BRIDGE_PCITOPCI)) {
        // PCI-to-PCI bridge, scan secondary bus
        const secondary_bus = getSecondaryBus(bus, device, function);
        scanBus(con, visited, secondary_bus);
    }

    const vendor_id = getVendorId(bus, device, function);
    const device_id = read16(bus, device, function, 0x02);
    const prog_if = read8(bus, device, function, 0x09);
    con.put(.{
        "PCI ",           bus,
        ":",              @as(u8, device),
        ":",              @as(u4, function),
        " - Vendor ID: ", vendor_id,
        ", Device ID: ",  device_id,
        " Class: ",       base_class,
        ".",              sub_class,
        " Prog IF: ",     prog_if,
        "\n",
    });

    //const header_type = getHeaderType(bus, device, function);
    //if (header_type == 0x00) {
    //    // Type 0: normal device, can have BARs
    //    for (0..6) |i| {
    //        const bar = read32(bus, device, function, @truncate(0x10 + i * 4));
    //        if (bar != 0) {
    //            con.put(.{ "  BAR ", i, ": ", bar, "\n" });
    //        }
    //    }
    //}
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
