// Segment type - p_type
pub const PT_NULL = 0;
pub const PT_LOAD = 1;

// Segment flags - p_flags
pub const P_X = 1 << 0; // executable
pub const P_W = 1 << 1; // writable
pub const P_R = 1 << 2; // readable

pub const Elf32_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,

    pub fn phdrPtr(ehdr: *align(1) const Elf32_Ehdr, elf: [*]u8, i: u32) *align(1) const Elf32_Phdr {
        return @ptrCast(elf + ehdr.e_phoff + i * ehdr.e_phentsize);
    }

    /// Compute the start and end addresses of a contiguous virtual memory block into which the program image fits.
    pub fn computeImageExtents(ehdr: *align(1) const Elf32_Ehdr, elf: [*]u8) struct { u32, u32 } {
        var vstart: u32 = 0xffff_ffff;
        var vend: u32 = 0;
        var i: u32 = 0;
        while (i < ehdr.e_phnum) : (i += 1) {
            const phdr = ehdr.phdrPtr(elf, i);
            if (phdr.p_type == PT_LOAD) {
                if (phdr.p_vaddr < vstart) vstart = phdr.p_vaddr;
                const end = phdr.p_vaddr + phdr.p_memsz;
                if (end > vend) vend = end;
            }
        }
        return .{ vstart, vend };
    }
};

pub const Elf32_Phdr = extern struct {
    p_type: u32, // PT_xxxx - for us only PT_LOAD is of interest
    p_offset: u32, // offset of the segment data within the file
    p_vaddr: u32, // virtual address where the segment should be places
    p_paddr: u32, // physical address - ignored
    p_filesz: u32, // number of bytes in the file image of the segment
    p_memsz: u32, // number of bytes in the memory image of the segment (>= p_filesz)
    p_flags: u32, // any combination of P_[RWX]
    p_align: u32, // alignment (in bytes) both in memory and in file
};
