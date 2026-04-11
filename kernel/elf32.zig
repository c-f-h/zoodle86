// Segment type - p_type
pub const PT_NULL = 0;
pub const PT_LOAD = 1;

// Segment flags - p_flags
pub const P_X = 1 << 0;
pub const P_W = 1 << 1;
pub const P_R = 1 << 2;

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
};

pub const Elf32_Phdr = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};
