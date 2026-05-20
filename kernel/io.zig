pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub inline fn repInsw(port: u16, buf: [*]u16, count: u32) void {
    asm volatile (
        \\cld
        \\rep insw
        :
        : [port] "N{dx}" (port),
          [count] "{ecx}" (count),
          [buf] "{edi}" (buf),
        : .{ .memory = true });
}

pub inline fn repOutsw(port: u16, buf: [*]const u16, count: u32) void {
    asm volatile (
        \\cld
        \\rep outsw
        :
        : [port] "N{dx}" (port),
          [count] "{ecx}" (count),
          [buf] "{esi}" (buf),
        : .{ .memory = true });
}
