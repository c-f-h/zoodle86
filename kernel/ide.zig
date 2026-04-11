const io = @import("io.zig");

pub const Bus = struct {
    io_base: u16,
    control_base: u16,
};

pub const PRIMARY: Bus = .{
    .io_base = 0x1F0, // 8 data ports
    .control_base = 0x3F6, // 4 control ports
};

pub const Drive = enum(u8) {
    master = 0,
    slave = 1,
};

pub const DriveInfo = struct {
    device_type: u16,
    cylinders: u16,
    heads: u16,
    sectors_per_track: u16,
    serial: [20]u8,
    model: [40]u8,
    capabilities: u16,
    field_validity: u16,
    command_sets: u32,
    max_lba28: u32,
    max_lba48: u64,
    size_in_sectors: u64,
};

pub const IdeError = error{
    Timeout,
    NoDevice,
    NotAtaDevice,
    InvalidLba,
    DeviceFault,
    ControllerError,
};

// Data ports (offset io_base)
const REG_DATA: u16 = 0;
const REG_ERROR: u16 = 1;
const REG_FEATURES: u16 = 1;
const REG_SECTOR_COUNT: u16 = 2;
const REG_LBA0: u16 = 3;
const REG_LBA1: u16 = 4;
const REG_LBA2: u16 = 5;
const REG_DRIVE_HEAD: u16 = 6;
const REG_STATUS: u16 = 7;
const REG_COMMAND: u16 = 7;

// Commands to be sent to port REG_COMMAND
const CMD_IDENTIFY: u8 = 0xEC;
const CMD_READ_SECTORS: u8 = 0x20;
const CMD_WRITE_SECTORS: u8 = 0x30;
const CMD_CACHE_FLUSH: u8 = 0xE7;

// Bit flags on REG_STATUS
const STATUS_ERR: u8 = 0x01; // Error
const STATUS_IDX: u8 = 0x02; // Index
const STATUS_CORR: u8 = 0x04; // Corrected data
const STATUS_DRQ: u8 = 0x08; // Data request ready
const STATUS_DSC: u8 = 0x10; // Drive seek complete
const STATUS_DF: u8 = 0x20; // Drive write fault
const STATUS_DRDY: u8 = 0x40; // Drive ready
const STATUS_BSY: u8 = 0x80; // Busy

// Error codes on REG_ERROR
const ERR_BBK: u8 = 0x80; // Bad block
const ERR_UNC: u8 = 0x40; // Uncorrectable data
const ERR_MC: u8 = 0x20; // Media changed
const ERR_IDNF: u8 = 0x10; // ID mark not found
const ERR_MCR: u8 = 0x08; // Media change request
const ERR_ABRT: u8 = 0x04; // Command aborted
const ERR_TK0NF: u8 = 0x02; // Track 0 not found
const ERR_AMNF: u8 = 0x01; // No address mark

// Offsets within the 256 word IDENTIFY buffer
const IDENT_DEVICETYPE: u16 = 0;
const IDENT_CYLINDERS: u16 = 2;
const IDENT_HEADS: u16 = 6;
const IDENT_SECTORS: u16 = 12;
const IDENT_SERIAL: u16 = 20;
const IDENT_MODEL: u16 = 54;
const IDENT_CAPABILITIES: u16 = 98;
const IDENT_FIELDVALID: u16 = 106;
const IDENT_MAX_LBA: u16 = 120;
const IDENT_COMMANDSETS: u16 = 164;
const IDENT_MAX_LBA_EXT: u16 = 200;
const COMMANDSET_LBA48: u32 = 1 << 26;

const POLL_TIMEOUT: u32 = 1_000_000;

inline fn dataPort(bus: Bus) u16 {
    return bus.io_base + REG_DATA;
}

inline fn ioPort(bus: Bus, offset: u16) u16 {
    return bus.io_base + offset;
}

inline fn readStatus(bus: Bus) u8 {
    return io.inb(ioPort(bus, REG_STATUS));
}

inline fn readAltStatus(bus: Bus) u8 {
    return io.inb(bus.control_base);
}

fn ata400nsDelay(bus: Bus) void {
    _ = readAltStatus(bus);
    _ = readAltStatus(bus);
    _ = readAltStatus(bus);
    _ = readAltStatus(bus);
}

fn driveHeadValue(drive: Drive, lba_high4: u8) u8 {
    const drive_bit: u8 = if (drive == .slave) 0x10 else 0x00;
    return 0xE0 | drive_bit | (lba_high4 & 0x0F);
}

fn identifyWordAt(words: *const [256]u16, byte_offset: u16) u16 {
    return words[byte_offset / 2];
}

fn identifyU32At(words: *const [256]u16, byte_offset: u16) u32 {
    const lo = @as(u32, identifyWordAt(words, byte_offset));
    const hi = @as(u32, identifyWordAt(words, byte_offset + 2));
    return lo | (hi << 16);
}

fn identifyU64At(words: *const [256]u16, byte_offset: u16) u64 {
    const w0 = @as(u64, identifyWordAt(words, byte_offset));
    const w1 = @as(u64, identifyWordAt(words, byte_offset + 2));
    const w2 = @as(u64, identifyWordAt(words, byte_offset + 4));
    const w3 = @as(u64, identifyWordAt(words, byte_offset + 6));
    return w0 | (w1 << 16) | (w2 << 32) | (w3 << 48);
}

fn identifyStringAt(comptime len: usize, words: *const [256]u16, byte_offset: u16) [len]u8 {
    var out: [len]u8 = undefined;
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const word = identifyWordAt(words, byte_offset + @as(u16, @intCast(i * 2)));
        out[i * 2] = @truncate(word >> 8);
        out[(i * 2) + 1] = @truncate(word);
    }
    return out;
}

fn parseDriveInfo(words: *const [256]u16) DriveInfo {
    const command_sets = identifyU32At(words, IDENT_COMMANDSETS);
    const max_lba28 = identifyU32At(words, IDENT_MAX_LBA);
    const max_lba48 = identifyU64At(words, IDENT_MAX_LBA_EXT);
    const size_in_sectors = if ((command_sets & COMMANDSET_LBA48) != 0) max_lba48 else max_lba28;

    return .{
        .device_type = identifyWordAt(words, IDENT_DEVICETYPE),
        .cylinders = identifyWordAt(words, IDENT_CYLINDERS),
        .heads = identifyWordAt(words, IDENT_HEADS),
        .sectors_per_track = identifyWordAt(words, IDENT_SECTORS),
        .serial = identifyStringAt(20, words, IDENT_SERIAL),
        .model = identifyStringAt(40, words, IDENT_MODEL),
        .capabilities = identifyWordAt(words, IDENT_CAPABILITIES),
        .field_validity = identifyWordAt(words, IDENT_FIELDVALID),
        .command_sets = command_sets,
        .max_lba28 = max_lba28,
        .max_lba48 = max_lba48,
        .size_in_sectors = size_in_sectors,
    };
}

fn waitUntilReady(bus: Bus) IdeError!void {
    var i: u32 = 0;
    while (i < POLL_TIMEOUT) : (i += 1) {
        const status = readStatus(bus);
        if ((status & STATUS_BSY) != 0) continue;
        if ((status & STATUS_DF) != 0) return error.DeviceFault;
        if ((status & STATUS_ERR) != 0) return error.ControllerError;
        if ((status & STATUS_DRDY) != 0) return;
    }
    return error.Timeout;
}

fn waitUntilDataRequest(bus: Bus) IdeError!void {
    var i: u32 = 0;
    while (i < POLL_TIMEOUT) : (i += 1) {
        const status = readStatus(bus);

        if ((status & STATUS_BSY) != 0) continue;
        if ((status & STATUS_DF) != 0) return error.DeviceFault;
        if ((status & STATUS_ERR) != 0) return error.ControllerError;
        if ((status & STATUS_DRQ) != 0) return;
    }
    return error.Timeout;
}

/// Selects an ATA drive on the primary IDE channel.
pub fn selectDrive(drive: Drive) void {
    io.outb(ioPort(PRIMARY, REG_DRIVE_HEAD), driveHeadValue(drive, 0));
    ata400nsDelay(PRIMARY);
}

/// Identifies an ATA drive and returns parsed IDENTIFY data.
pub fn identifyDrive(drive: Drive) IdeError!DriveInfo {
    var words: [256]u16 = undefined;

    selectDrive(drive);

    io.outb(ioPort(PRIMARY, REG_SECTOR_COUNT), 0);
    io.outb(ioPort(PRIMARY, REG_LBA0), 0);
    io.outb(ioPort(PRIMARY, REG_LBA1), 0);
    io.outb(ioPort(PRIMARY, REG_LBA2), 0);
    io.outb(ioPort(PRIMARY, REG_COMMAND), CMD_IDENTIFY);

    try waitUntilReady(PRIMARY);

    if (readStatus(PRIMARY) == 0) {
        return error.NoDevice;
    }

    if (io.inb(ioPort(PRIMARY, REG_LBA1)) != 0 or io.inb(ioPort(PRIMARY, REG_LBA2)) != 0) {
        return error.NotAtaDevice;
    }

    try waitUntilDataRequest(PRIMARY);

    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        words[i] = io.inw(dataPort(PRIMARY));
    }

    return parseDriveInfo(&words);
}

/// Reads one 512-byte sector at `lba` using ATA PIO LBA28 mode.
pub fn readSectorLba28(drive: Drive, lba: u32, out_sector: *[512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    io.outb(ioPort(PRIMARY, REG_DRIVE_HEAD), driveHeadValue(drive, @truncate(lba >> 24)));
    ata400nsDelay(PRIMARY);
    try waitUntilReady(PRIMARY);
    io.outb(ioPort(PRIMARY, REG_FEATURES), 0);
    io.outb(ioPort(PRIMARY, REG_SECTOR_COUNT), 1);
    io.outb(ioPort(PRIMARY, REG_LBA0), @truncate(lba));
    io.outb(ioPort(PRIMARY, REG_LBA1), @truncate(lba >> 8));
    io.outb(ioPort(PRIMARY, REG_LBA2), @truncate(lba >> 16));
    io.outb(ioPort(PRIMARY, REG_COMMAND), CMD_READ_SECTORS);

    try waitUntilDataRequest(PRIMARY);

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const word = io.inw(dataPort(PRIMARY));
        out_sector[i * 2] = @truncate(word);
        out_sector[(i * 2) + 1] = @truncate(word >> 8);
    }
}

/// Writes one 512-byte sector at `lba` using ATA PIO LBA28 mode.
pub fn writeSectorLba28(drive: Drive, lba: u32, in_sector: *const [512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    io.outb(ioPort(PRIMARY, REG_DRIVE_HEAD), driveHeadValue(drive, @truncate(lba >> 24)));
    ata400nsDelay(PRIMARY);
    try waitUntilReady(PRIMARY);
    io.outb(ioPort(PRIMARY, REG_FEATURES), 0);
    io.outb(ioPort(PRIMARY, REG_SECTOR_COUNT), 1);
    io.outb(ioPort(PRIMARY, REG_LBA0), @truncate(lba));
    io.outb(ioPort(PRIMARY, REG_LBA1), @truncate(lba >> 8));
    io.outb(ioPort(PRIMARY, REG_LBA2), @truncate(lba >> 16));
    io.outb(ioPort(PRIMARY, REG_COMMAND), CMD_WRITE_SECTORS);

    try waitUntilDataRequest(PRIMARY);

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const lo = @as(u16, in_sector[i * 2]);
        const hi = @as(u16, in_sector[(i * 2) + 1]) << 8;
        io.outw(dataPort(PRIMARY), hi | lo);
    }

    io.outb(ioPort(PRIMARY, REG_COMMAND), CMD_CACHE_FLUSH);
    try waitUntilReady(PRIMARY);
}
