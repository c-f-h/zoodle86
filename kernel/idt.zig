pub const NUM_IDT_ENTRIES = 256;

pub const GateType = enum(u4) {
    TaskGate = 0b0101, // only used for hardware task switching
    InterruptGate16 = 0b0110,
    TrapGate16 = 0b0111,
    InterruptGate32 = 0b1110, // clears interrupt flag; return address is *after* the interrupted instruction
    TrapGate32 = 0b1111, // does not clear interrupt flag; may have an error code pushed to the stack; return *at* the instruction
};

pub const Attrs = packed struct {
    type: GateType,
    reserved: bool = false,
    dpl: u2 = 0, // descriptor privilege level (0-3)
    present: bool = true,
};

pub const Descriptor = packed struct {
    offset_low: u16,
    selector: u16,
    reserved: u8 = 0,
    attrs: Attrs,
    offset_high: u16,
};

comptime {
    if (@sizeOf(Descriptor) != 8) @compileError("IDT Descriptor size should be 8 bytes");
}

pub fn makeDescriptor(gatetype: GateType, offset: u32, selector: u16, dpl: u2) Descriptor {
    return .{
        .offset_low = @truncate(offset),
        .selector = selector,
        .attrs = .{
            .type = gatetype,
            .dpl = dpl,
            .present = true,
        },
        .offset_high = @truncate(offset >> 16),
    };
}

pub const IDTR = packed struct {
    limit: u16,
    base: u32,

    pub fn init(self: *IDTR, p_idt: []Descriptor) void {
        self.limit = @truncate(p_idt.len * @sizeOf(Descriptor) - 1);
        self.base = @intFromPtr(p_idt.ptr);
    }

    pub fn load(self: *IDTR) void {
        lidt(@intFromPtr(self));
    }
};

var idtr: IDTR = undefined;

inline fn lidt(addr: usize) void {
    asm volatile (
        \\lidt (%[addr])
        :
        : [addr] "r" (addr),
    );
}

var idt: [NUM_IDT_ENTRIES]Descriptor align(8) = undefined;

pub fn init() void {
    @memset(&idt, @bitCast(@as(u64, 0)));
    idtr.init(&idt);
}

pub fn set(vector: u8, gatetype: GateType, offset: u32, selector: u16, dpl: u2) void {
    idt[vector] = makeDescriptor(gatetype, offset, selector, dpl);
}

pub fn load() void {
    idtr.load();
}
