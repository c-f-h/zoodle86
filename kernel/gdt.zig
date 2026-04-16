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

pub fn makeSegment(base: u32, limit: u20, access: AccessFlags, flags: Flags) Descriptor {
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

pub fn makeSystemSegment(base: u32, limit: u20, access_byte: u8, flags: Flags) Descriptor {
    return makeSegment(base, limit, @bitCast(access_byte), flags);
}

pub const Tss = extern struct {
    prev_tss: u16 = 0,
    _reserved0: u16 = 0,
    esp0: u32 = 0,
    ss0: u16 = 0,
    _reserved1: u16 = 0,
    esp1: u32 = 0,
    ss1: u16 = 0,
    _reserved2: u16 = 0,
    esp2: u32 = 0,
    ss2: u16 = 0,
    _reserved3: u16 = 0,
    cr3: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    es: u16 = 0,
    _reserved4: u16 = 0,
    cs: u16 = 0,
    _reserved5: u16 = 0,
    ss: u16 = 0,
    _reserved6: u16 = 0,
    ds: u16 = 0,
    _reserved7: u16 = 0,
    fs: u16 = 0,
    _reserved8: u16 = 0,
    gs: u16 = 0,
    _reserved9: u16 = 0,
    ldt_selector: u16 = 0,
    _reserved10: u16 = 0,
    trap: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),

    pub fn init(tss: *Tss, ss: u16) void {
        tss.* = .{};
        tss.ss0 = ss;
        tss.iomap_base = @sizeOf(Tss);
    }

    pub fn setKernelStack(tss: *Tss, stack_top: usize) void {
        tss.esp0 = stack_top;
    }
};

comptime {
    if (@sizeOf(Tss) != 104) @compileError("TSS size should be 104 bytes");
}

pub const GDTR = packed struct {
    limit: u16,
    base: u32,

    /// Initialize the GDTR to point to the given descriptor array.
    pub fn init(self: *GDTR, p_gdt: []Descriptor) void {
        self.limit = @truncate(p_gdt.len * @sizeOf(Descriptor) - 1);
        self.base = @intFromPtr(p_gdt.ptr);
    }

    /// Load the GDT which this points to into the current CPU.
    pub fn load(self: *GDTR) void {
        lgdt(@intFromPtr(self));
    }
};
var gdtr: GDTR = undefined;

inline fn lgdt(addr: usize) void {
    asm volatile (
        \\lgdt (%[addr])
        :
        : [addr] "r" (addr),
    );
}

pub inline fn ltr(selector: u16) void {
    asm volatile (
        \\ltr %[selector]
        :
        : [selector] "r" (selector),
    );
}
