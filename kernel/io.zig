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

/// Copies bytes from a far pointer (segment:offset) to a location in the current
/// data segment. Uses the DS segment register with REP MOVSB to perform the copy.
/// Preserves the original DS register value (source for MOVSB).
pub noinline fn memcpy_from_segment(dest: [*]u8, src_segment: u16, src_offset: u32, len: usize) void {
    asm volatile (
        \\ push %%ds
        \\ mov %[seg], %%ax
        \\ mov %%ax, %%ds
        \\ mov %[off], %%esi
        \\ mov %[dst], %%edi
        \\ mov %[len], %%ecx
        \\ cld
        \\ rep movsb
        \\ pop %%ds
        :
        : [seg] "{ax}" (src_segment),
          [off] "{esi}" (src_offset),
          [dst] "{edi}" (@intFromPtr(dest)),
          [len] "{ecx}" (len),
        : .{ .memory = true, .eax = true, .esi = true, .edi = true, .ecx = true }); // clobber
}
