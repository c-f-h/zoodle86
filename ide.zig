pub const Bus = struct {
    io_base: u16,
    control_base: u16,
};

pub const PRIMARY: Bus = .{
    .io_base = 0x1F0,
    .control_base = 0x3F6,
};

pub const Drive = enum(u8) {
    master = 0,
    slave = 1,
};

pub const IdeError = error{
    Timeout,
    NoDevice,
    NotAtaDevice,
    InvalidLba,
    DeviceFault,
    ControllerError,
};

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

const CMD_IDENTIFY: u8 = 0xEC;
const CMD_READ_SECTORS: u8 = 0x20;
const CMD_WRITE_SECTORS: u8 = 0x30;
const CMD_CACHE_FLUSH: u8 = 0xE7;

const STATUS_ERR: u8 = 0x01;
const STATUS_DRQ: u8 = 0x08;
const STATUS_DF: u8 = 0x20;
const STATUS_BSY: u8 = 0x80;

const POLL_TIMEOUT: u32 = 1_000_000;

inline fn dataPort(bus: Bus) u16 {
    return bus.io_base + REG_DATA;
}

inline fn ioPort(bus: Bus, offset: u16) u16 {
    return bus.io_base + offset;
}

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

inline fn readStatus(bus: Bus) u8 {
    return inb(ioPort(bus, REG_STATUS));
}

inline fn readAltStatus(bus: Bus) u8 {
    return inb(bus.control_base);
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

fn waitUntilNotBusy(bus: Bus) IdeError!void {
    var i: u32 = 0;
    while (i < POLL_TIMEOUT) : (i += 1) {
        if ((readStatus(bus) & STATUS_BSY) == 0) return;
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
    outb(ioPort(PRIMARY, REG_DRIVE_HEAD), driveHeadValue(drive, 0));
    ata400nsDelay(PRIMARY);
}

/// Identifies an ATA drive and fills `out_words` with 256 words of IDENTIFY data.
pub fn identifyDrive(drive: Drive, out_words: *[256]u16) IdeError!void {
    selectDrive(drive);

    outb(ioPort(PRIMARY, REG_SECTOR_COUNT), 0);
    outb(ioPort(PRIMARY, REG_LBA0), 0);
    outb(ioPort(PRIMARY, REG_LBA1), 0);
    outb(ioPort(PRIMARY, REG_LBA2), 0);
    outb(ioPort(PRIMARY, REG_COMMAND), CMD_IDENTIFY);

    if (readStatus(PRIMARY) == 0) {
        return error.NoDevice;
    }

    try waitUntilNotBusy(PRIMARY);

    if (inb(ioPort(PRIMARY, REG_LBA1)) != 0 or inb(ioPort(PRIMARY, REG_LBA2)) != 0) {
        return error.NotAtaDevice;
    }

    try waitUntilDataRequest(PRIMARY);

    var i: usize = 0;
    while (i < out_words.len) : (i += 1) {
        out_words[i] = inw(dataPort(PRIMARY));
    }
}

/// Reads one 512-byte sector at `lba` using ATA PIO LBA28 mode.
pub fn readSectorLba28(drive: Drive, lba: u32, out_sector: *[512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    outb(ioPort(PRIMARY, REG_DRIVE_HEAD), driveHeadValue(drive, @truncate(lba >> 24)));
    outb(ioPort(PRIMARY, REG_FEATURES), 0);
    outb(ioPort(PRIMARY, REG_SECTOR_COUNT), 1);
    outb(ioPort(PRIMARY, REG_LBA0), @truncate(lba));
    outb(ioPort(PRIMARY, REG_LBA1), @truncate(lba >> 8));
    outb(ioPort(PRIMARY, REG_LBA2), @truncate(lba >> 16));
    outb(ioPort(PRIMARY, REG_COMMAND), CMD_READ_SECTORS);

    try waitUntilDataRequest(PRIMARY);

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const word = inw(dataPort(PRIMARY));
        out_sector[i * 2] = @truncate(word);
        out_sector[(i * 2) + 1] = @truncate(word >> 8);
    }
}

/// Writes one 512-byte sector at `lba` using ATA PIO LBA28 mode.
pub fn writeSectorLba28(drive: Drive, lba: u32, in_sector: *const [512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    outb(ioPort(PRIMARY, REG_DRIVE_HEAD), driveHeadValue(drive, @truncate(lba >> 24)));
    outb(ioPort(PRIMARY, REG_FEATURES), 0);
    outb(ioPort(PRIMARY, REG_SECTOR_COUNT), 1);
    outb(ioPort(PRIMARY, REG_LBA0), @truncate(lba));
    outb(ioPort(PRIMARY, REG_LBA1), @truncate(lba >> 8));
    outb(ioPort(PRIMARY, REG_LBA2), @truncate(lba >> 16));
    outb(ioPort(PRIMARY, REG_COMMAND), CMD_WRITE_SECTORS);

    try waitUntilDataRequest(PRIMARY);

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const lo = @as(u16, in_sector[i * 2]);
        const hi = @as(u16, in_sector[(i * 2) + 1]) << 8;
        outw(dataPort(PRIMARY), hi | lo);
    }

    outb(ioPort(PRIMARY, REG_COMMAND), CMD_CACHE_FLUSH);
    try waitUntilNotBusy(PRIMARY);
}
