const io = @import("io.zig");
const block_device = @import("block_device.zig");
const kernel = @import("kernel.zig");
const paging = @import("paging.zig");
const abi = @import("abi");
const interrupt_frame = @import("interrupt_frame.zig");

const BlockDevice = block_device.BlockDevice;
const BlockError = block_device.BlockError;

pub const Bus = struct {
    // Base I/O port for the 8 REG_xxx registers
    io_base: u16,
    control_base: u16,
    // IRQ number for DMA completion
    irq: u8 = 0,
    // Base I/O port for busmaster IDE DMA registers.
    busmaster_base: u16 = 0,

    pub inline fn writeIdeCommand(self: *const Bus, cmd: u8) void {
        io.outb(ioPort(self.*, REG_COMMAND), cmd);
    }

    pub inline fn writeBmCommandRaw(self: *const Bus, cmd: u8) void {
        io.outb(self.busmaster_base + BM_REG_COMMAND, cmd);
    }
    pub fn writeBmCommand(self: *const Bus, write: bool, start: bool) void {
        var cmd: u8 = 0;
        // Note: the spec says bit 3 is 1 for write, but apparently this is from the
        // DMA controller's perspective and means "write from device to memory".
        if (!write) cmd |= 0x08;
        if (start) cmd |= 0x01;
        self.writeBmCommandRaw(cmd);
    }

    pub fn writeBmStatus(self: *const Bus, status: u8) void {
        io.outb(self.busmaster_base + BM_REG_STATUS, status);
    }
    pub fn readBmStatus(self: *const Bus) u8 {
        return io.inb(self.busmaster_base + BM_REG_STATUS);
    }
};

pub var Primary: Bus = .{
    .io_base = 0x1F0, // 8 data ports
    .control_base = 0x3F6, // 4 control ports
    .irq = 14,
};

pub var Secondary: Bus = .{
    .io_base = 0x170,
    .control_base = 0x376,
    .irq = 15,
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
    capabilities: u16, // if 0x200 is set, drive supports LBA
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
const REG_DATA: u16 = 0; // read/write
const REG_ERROR: u16 = 1; // read
const REG_FEATURES: u16 = 1; // write - used for CMD_SET_FEATURES
const REG_SECTOR_COUNT: u16 = 2; // read/write - number of sectors to read/write
const REG_LBA0: u16 = 3;
const REG_LBA1: u16 = 4;
const REG_LBA2: u16 = 5;
const REG_DRIVE_HEAD: u16 = 6; // read/write - contains drive number (1 bit) and head (4 bits)
const REG_STATUS: u16 = 7; // read - see STATUS_xxx bits below
const REG_COMMAND: u16 = 7; // write - command to send to the drive (CMD_xxx)

// Commands to be sent to port REG_COMMAND
const CMD_IDENTIFY: u8 = 0xEC;
const CMD_READ_SECTORS: u8 = 0x20;
const CMD_WRITE_SECTORS: u8 = 0x30;
const CMD_READ_DMA: u8 = 0xC8; // 28 bit LBA DMA read
const CMD_WRITE_DMA: u8 = 0xCA; // 28 bit LBA DMA write
const CMD_CACHE_FLUSH: u8 = 0xE7;
const CMD_SET_FEATURES: u8 = 0xEF;

// Bit flags on REG_STATUS
const STATUS_ERR: u8 = 0x01; // Error - previous command failed, REG_ERROR contains additional information
const STATUS_IDX: u8 = 0x02; // Index - set when the index mark is detected once per disk revolution
const STATUS_CORR: u8 = 0x04; // Corrected data
const STATUS_DRQ: u8 = 0x08; // Data request - ready to transfer data to/from the data port
const STATUS_DSC: u8 = 0x10; // Drive seek complete
const STATUS_DF: u8 = 0x20; // Drive write fault
const STATUS_DRDY: u8 = 0x40; // Drive ready - can accept commands
const STATUS_BSY: u8 = 0x80; // Busy - drive is working, do not access control ports

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

// Busmastering port offsets
const BM_REG_COMMAND = 0;
const BM_REG_STATUS = 2;
const BM_REG_PRDT = 4;

// Bit flags in BM_REG_STATUS - set by the controller when:
const BM_STATUS_IRQ = 0x04; // An interrupt has been triggered (reset by writing 1)
const BM_STATUS_ERROR = 0x02; // A busmastering error has occurred (reset by writing 1)
const BM_STATUS_ACTIVE = 0x01; // The DMA controller is working

// One entry in the Physical Region Descriptor Table for busmaster IDE DMA.
const PrdtEntry = extern struct {
    phys_addr: u32, // Physical address of the data buffer
    num_bytes: u16, // Number of bytes to transfer
    flags: u16, // 0x8000 = end of table, otherwise 0
};

var dma_buf: []u8 = undefined;
var dma_buf_phys: u32 = 0;

pub fn initDmaBusmastering() !void {
    if (Primary.busmaster_base == 0) @panic("No DMA busmastering base address");
    if (dma_buf_phys == 0) {
        const alloc = kernel.getAllocator();
        dma_buf = try alloc.alloc(u8, paging.PAGE);
        dma_buf_phys = paging.virtualToPhysical(dma_buf.ptr);
        kernel.log("IDE DMA buffer: {x} virtual, {x} physical\n", .{ @intFromPtr(dma_buf.ptr), dma_buf_phys });
    }
}

var dma_done = false;
var dma_error = false;

pub fn ide_dispatch(frame: *const interrupt_frame.InterruptFrame) void {
    const bus = if (frame.vector == kernel.VECTOR_IDE_PRIMARY) &Primary else &Secondary;
    const bm_status = bus.readBmStatus(); // get busmastering status
    const ide_status = readStatus(bus.*); // get IDE status - acknowledges interrupt

    // Stop DMA engine
    bus.writeBmCommandRaw(0);
    // Reset error and interrupt bits
    bus.writeBmStatus(bm_status | (BM_STATUS_ERROR | BM_STATUS_IRQ));

    // "Active" and "error" bits should be clear on both IDE and DMA busmaster
    dma_error = (bm_status & (BM_STATUS_ERROR | BM_STATUS_ACTIVE) != 0) or (ide_status & (STATUS_BSY | STATUS_ERR) != 0);

    const log_all = false;

    if (dma_error or log_all) {
        kernel.log("IDE irq: {s} - status {x} {x}", .{ if (frame.vector == kernel.VECTOR_IDE_PRIMARY) "primary" else "secondary", bm_status, ide_status });
    }

    dma_done = true;
}

inline fn dataPort(bus: Bus) u16 {
    return bus.io_base + REG_DATA;
}

inline fn ioPort(bus: Bus, offset: u16) u16 {
    return bus.io_base + offset;
}

inline fn readStatus(bus: Bus) u8 {
    return io.inb(ioPort(bus, REG_STATUS));
}

/// Contains the same information as the status register, but reading it does not acknowledge
/// an interrupt or clear a pending interrupt.
inline fn readAltStatus(bus: Bus) u8 {
    return io.inb(bus.control_base);
}

/// Bits: [ HOB 0 0 0 0 SRST nIEN 0 ]
inline fn writeDeviceControlRegister(bus: Bus, value: u8) void {
    io.outb(bus.control_base, value);
}

fn ata400nsDelay(bus: Bus) void {
    _ = readAltStatus(bus);
    _ = readAltStatus(bus);
    _ = readAltStatus(bus);
    _ = readAltStatus(bus);
}

fn hdDevSel(drive: Drive, lba_high4: u8) u8 {
    const drive_bit: u8 = if (drive == .slave) 0x10 else 0x00;
    // bits: [ 1 LBA 1 SLAVE HEAD(4) ]
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
    io.outb(ioPort(Primary, REG_DRIVE_HEAD), hdDevSel(drive, 0));
    ata400nsDelay(Primary);
    writeDeviceControlRegister(Primary, 0);
}

/// Identifies an ATA drive and returns parsed IDENTIFY data.
pub fn identifyDrive(drive: Drive) IdeError!DriveInfo {
    var words: [256]u16 = undefined;

    selectDrive(drive);

    io.outb(ioPort(Primary, REG_SECTOR_COUNT), 0);
    io.outb(ioPort(Primary, REG_LBA0), 0);
    io.outb(ioPort(Primary, REG_LBA1), 0);
    io.outb(ioPort(Primary, REG_LBA2), 0);
    io.outb(ioPort(Primary, REG_COMMAND), CMD_IDENTIFY);

    try waitUntilReady(Primary);

    if (readStatus(Primary) == 0) {
        return error.NoDevice;
    }

    if (io.inb(ioPort(Primary, REG_LBA1)) != 0 or io.inb(ioPort(Primary, REG_LBA2)) != 0) {
        return error.NotAtaDevice;
    }

    try waitUntilDataRequest(Primary);

    io.repInsw(dataPort(Primary), &words, words.len);

    return parseDriveInfo(&words);
}

fn writeAtaTaskFile(drive: Drive, lba: u32, sectors: u8) !void {
    io.outb(ioPort(Primary, REG_DRIVE_HEAD), hdDevSel(drive, @truncate(lba >> 24)));
    ata400nsDelay(Primary);
    try waitUntilReady(Primary);
    io.outb(ioPort(Primary, REG_SECTOR_COUNT), sectors);
    io.outb(ioPort(Primary, REG_LBA0), @truncate(lba));
    io.outb(ioPort(Primary, REG_LBA1), @truncate(lba >> 8));
    io.outb(ioPort(Primary, REG_LBA2), @truncate(lba >> 16));
}

/// Reads one 512-byte sector at `lba` using ATA PIO LBA28 mode.
pub fn readSectorLba28(drive: Drive, lba: u32, out_sector: *[512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    try writeAtaTaskFile(drive, lba, 1);
    io.outb(ioPort(Primary, REG_COMMAND), CMD_READ_SECTORS);

    try waitUntilDataRequest(Primary);
    io.repInsw(dataPort(Primary), @ptrCast(@alignCast(out_sector)), 256);
}

/// Reads or writes one 512-byte sector at `lba` using ATA DMA LBA28 mode.
fn transferSectorLba28Dma(drive: Drive, lba: u32, write: bool, sector: *[512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    dma_done = false;
    dma_error = false;

    if (write) { // copy write data from input buffer (might cross page boundary) to DMA buffer
        @memcpy(dma_buf[0..512], sector);
    }

    const prdt: [*]PrdtEntry = @ptrCast(@alignCast(dma_buf.ptr + 512));
    prdt[0] = .{
        .phys_addr = dma_buf_phys,
        .num_bytes = 512,
        .flags = 0x8000, // end of table
    };

    const bus = Primary;

    // Stop DMA engine
    bus.writeBmCommandRaw(0);
    // Reset error and interrupt bits
    bus.writeBmStatus(bus.readBmStatus() | (BM_STATUS_ERROR | BM_STATUS_IRQ));
    // Write PRDT physical address (PRDT lives after the 512-byte data region)
    io.outl(bus.busmaster_base + BM_REG_PRDT, dma_buf_phys + 512);
    // Set READ direction; don't start yet
    bus.writeBmCommand(write, false);
    // Program LBA and number of sectors
    try writeAtaTaskFile(drive, lba, 1);
    // Send DMA read command
    bus.writeIdeCommand(if (write) CMD_WRITE_DMA else CMD_READ_DMA);
    // Start DMA engine
    bus.writeBmCommand(write, true);

    // When this is called from an interrupt handler (in particular a syscall),
    // the interrupt flag is off here and the hlt loop will hang.
    // Enable interrupts to work around this.
    asm volatile ("sti");

    var timeout: u32 = 0;
    while (!dma_done) : (timeout += 1) {
        if (timeout >= 1000) {
            dma_done = false;
            dma_error = false;
            kernel.log("DMA timeout waiting for IRQ on LBA {d}\n", .{lba});
            return error.Timeout;
        }
        asm volatile ("hlt" ::: .{ .memory = true });
    }

    const err = dma_error;
    dma_done = false;
    dma_error = false;
    if (err) return error.ControllerError;

    if (!write) { // copy read data from DMA buffer to output buffer
        @memcpy(sector, dma_buf[0..512]);
    }
}

/// Writes one 512-byte sector at `lba` using ATA PIO LBA28 mode.
pub fn writeSectorLba28(drive: Drive, lba: u32, in_sector: *const [512]u8) IdeError!void {
    if ((lba & 0xF0000000) != 0) return error.InvalidLba;

    try writeAtaTaskFile(drive, lba, 1);
    io.outb(ioPort(Primary, REG_COMMAND), CMD_WRITE_SECTORS);

    try waitUntilDataRequest(Primary);
    io.repOutsw(dataPort(Primary), @ptrCast(@alignCast(in_sector)), 256);

    io.outb(ioPort(Primary, REG_COMMAND), CMD_CACHE_FLUSH);
    try waitUntilReady(Primary);
}

/// Concrete BlockDevice implementation backed by an ATA IDE drive.
///
/// Embeds a `BlockDevice` as its first field so that vtable functions can
/// recover the outer struct via `@fieldParentPtr("block_dev", ptr)`.
pub const IdeBlockDevice = struct {
    block_dev: BlockDevice,
    drive: Drive,

    const vtable = BlockDevice.VTable{
        .readBlock = readBlockDma,
        .writeBlock = writeBlockDma,
    };

    const vtable_readOnly = BlockDevice.VTable{
        .readBlock = readBlock,
        .writeBlock = undefined,
    };

    /// Initializes an IdeBlockDevice for `drive` with `sector_count` total blocks.
    pub fn init(drive: Drive, sector_count: u32) IdeBlockDevice {
        return .{
            .block_dev = .{
                .vtable = &vtable,
                .block_count = sector_count,
                .device = .{ .major = abi.DeviceMajor.Ide, .minor = if (drive == .master) 0 else 1 },
            },
            .drive = drive,
        };
    }

    pub fn initReadOnly(drive: Drive, sector_count: u32) IdeBlockDevice {
        return .{
            .block_dev = .{
                .vtable = &vtable_readOnly,
                .block_count = sector_count,
                .device = .{ .major = abi.DeviceMajor.Ide, .minor = if (drive == .master) 0 else 1 },
            },
            .drive = drive,
        };
    }

    const root = @import("root");
    const should_log = @hasDecl(root, "log");

    fn readBlock(bd: *BlockDevice, lba: u32, buf: *[block_device.BLOCK_SIZE]u8) BlockError!void {
        //if (comptime should_log) root.log("IdeBlockDevice read: LBA {d}", .{lba});
        const self: *IdeBlockDevice = @fieldParentPtr("block_dev", bd);
        readSectorLba28(self.drive, lba, buf) catch return error.ReadError;
    }

    fn readBlockDma(bd: *BlockDevice, lba: u32, buf: *[block_device.BLOCK_SIZE]u8) BlockError!void {
        //if (comptime should_log) root.log("IdeBlockDevice read DMA: LBA {d}", .{lba});
        const self: *IdeBlockDevice = @fieldParentPtr("block_dev", bd);
        transferSectorLba28Dma(self.drive, lba, false, buf) catch return error.ReadError;
    }

    fn writeBlock(bd: *BlockDevice, lba: u32, buf: *const [block_device.BLOCK_SIZE]u8) BlockError!void {
        const self: *IdeBlockDevice = @fieldParentPtr("block_dev", bd);
        writeSectorLba28(self.drive, lba, buf) catch return error.WriteError;
    }

    fn writeBlockDma(bd: *BlockDevice, lba: u32, buf: *const [block_device.BLOCK_SIZE]u8) BlockError!void {
        //if (comptime should_log) root.log("IdeBlockDevice write DMA: LBA {d}", .{lba});
        const self: *IdeBlockDevice = @fieldParentPtr("block_dev", bd);
        transferSectorLba28Dma(self.drive, lba, true, @constCast(buf)) catch return error.WriteError;
    }
};
