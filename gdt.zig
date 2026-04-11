pub const AccessFlags = packed struct {
    accessed: bool = true, // set by CPU when segment is accessed in case it is initially false
    read_write: bool,
    direction_conforming: bool = false, // data segments: false means grow up, true means grow down; for code segments means non-conforming vs conforming
    executable: bool,
    descr_type: bool = true, // 0 for system segments, 1 for code/data segments
    dpl: u2 = 0, // descriptor privilege level (0-3)
    present: bool = true,
};

pub const Flags = packed struct {
    reserved: bool = false, // unused
    long_mode: bool = false, // for 64-bit mode
    size_flag: bool = true, // 0 for 16-bit segment, 1 for 32-bit segment
    granularity: bool = true, // 0 for byte granularity, 1 for 4KiB granularity (applies to limit only)
};

pub const Descriptor = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: AccessFlags,
    limit_high_flags: u8,
    base_high: u8,
};

comptime {
    if (@sizeOf(Descriptor) != 8) @compileError("GDT Descriptor size should be 8 bytes");
}

fn makeSegment(base: u32, limit: u20, access: AccessFlags, flags: Flags) Descriptor {
    const high_nibble = @as(u8, @truncate(limit >> 16));
    const limit_high_flags = (@as(u8, @as(u4, @bitCast(flags))) << 4) | high_nibble;

    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .limit_high_flags = limit_high_flags,
        .base_high = @truncate(base >> 24),
    };
}

pub var gdt: [5]Descriptor = .{
    @bitCast(@as(u64, 0)), // null descriptor
    makeSegment(0, 0xFFFFF, AccessFlags{ .read_write = false, .executable = true }, Flags{}), // kernel code segment
    makeSegment(0, 0xFFFFF, AccessFlags{ .read_write = true, .executable = false }, Flags{}), // kernel data segment
    @bitCast(@as(u64, 0)), // user code segment
    @bitCast(@as(u64, 0)), // user data segment
};

pub fn setUserSegments(code: []u8, data: []u8) void {
    const code_base = @intFromPtr(code.ptr);
    const code_pages = @divTrunc(code.len, 4 * 1024);

    const data_base = @intFromPtr(data.ptr);
    const data_pages = @divTrunc(data.len, 4 * 1024);

    gdt[3] = makeSegment(code_base, @truncate(code_pages), AccessFlags{ .read_write = false, .executable = true, .dpl = 3 }, Flags{});
    gdt[4] = makeSegment(data_base, @truncate(data_pages), AccessFlags{ .read_write = true, .executable = false, .dpl = 3 }, Flags{});
}

const GDTR = packed struct {
    limit: u16,
    base: u32,
};
var gdtr: GDTR = undefined;

pub fn set() void {
    gdtr = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    lgdt(@intFromPtr(&gdtr));
}

inline fn lgdt(addr: usize) void {
    asm volatile (
        \\lgdt (%[addr])
        :
        : [addr] "r" (addr),
    );
}
