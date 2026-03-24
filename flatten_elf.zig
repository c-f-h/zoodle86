const std = @import("std");

const Elf32_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32, // program header offset
    e_shoff: u32, // section header offset
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16, // size per program header entry
    e_phnum: u16, // number of program header entries
    e_shentsize: u16, // size per section header entry
    e_shnum: u16, // number of section header entries
    e_shstrndx: u16,

    // Given a pointer to the ELF image, return a pointer to the ith segment header
    fn phdrPtr(ehdr: *align(1) const Elf32_Ehdr, elf: [*]u8, i: u32) *align(1) const Elf32_Phdr {
        return @ptrCast(elf + ehdr.e_phoff + i * ehdr.e_phentsize);
    }
};

const Elf32_Phdr = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

const FlattenElfError = error{
    ElfTooSmall,
    InvalidElfSignature,
    Not32BitElf,
    NotLittleEndian,
    NotExecutableElf,
    NotX86Elf,
    InvalidProgramHeaderSize,
    NoLoadSegments,
    InvalidImageBase,
    InvalidArgs,
    MetadataWriteFailed,
};

const FlattenResult = struct {
    data: []u8,
    entry_rva: u32,
    sector_count: u32,
};

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    _ = it.skip();

    var stderr = std.Io.File.stderr();

    const elf_path = it.next() orelse {
        try stderr.writeStreamingAll(init.io, "Usage: flatten_elf <input.elf> <output.bin> <metadata.txt>\n");
        return FlattenElfError.InvalidArgs;
    };
    const out_path = it.next() orelse {
        try stderr.writeStreamingAll(init.io, "Usage: flatten_elf <input.elf> <output.bin> <metadata.txt>\n");
        return FlattenElfError.InvalidArgs;
    };
    const meta_path = it.next() orelse {
        try stderr.writeStreamingAll(init.io, "Usage: flatten_elf <input.elf> <output.bin> <metadata.txt>\n");
        return FlattenElfError.InvalidArgs;
    };

    // flatten the image and write the result
    const result = try flattenElf(elf_path, init.gpa, &init.io);
    defer init.gpa.free(result.data);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = result.data });

    // write the metadata file with entry RVA and number of sectors
    var meta_buf: [64]u8 = undefined;
    const meta = try std.fmt.bufPrint(&meta_buf, "{d}\n{d}\n", .{ result.entry_rva, result.sector_count });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = meta_path, .data = meta });
}

fn flattenElf(elf_path: []const u8, allocator: std.mem.Allocator, io: *const std.Io) !FlattenResult {
    const file = try std.Io.Dir.cwd().openFile(io.*, elf_path, .{});
    defer file.close(io.*);

    const size = try file.length(io.*);
    if (size < 52) {
        return FlattenElfError.ElfTooSmall;
    }

    var elf_bytes = try allocator.alloc(u8, size);
    defer allocator.free(elf_bytes);
    const bytes_read = try file.readPositionalAll(io.*, elf_bytes, 0);
    const elf = elf_bytes[0..bytes_read];

    const ehdr = @as(*align(1) const Elf32_Ehdr, @ptrCast(elf.ptr));

    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) {
        return FlattenElfError.InvalidElfSignature;
    }
    if (ehdr.e_ident[4] != 1) {
        return FlattenElfError.Not32BitElf;
    }
    if (ehdr.e_ident[5] != 1) {
        return FlattenElfError.NotLittleEndian;
    }

    if (ehdr.e_type != 2) {
        return FlattenElfError.NotExecutableElf;
    }
    if (ehdr.e_machine != 3) {
        return FlattenElfError.NotX86Elf;
    }
    if (ehdr.e_phentsize != 32) {
        return FlattenElfError.InvalidProgramHeaderSize;
    }

    var image_base: ?u32 = null;
    var image_end: u32 = 0;

    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const phdr = ehdr.phdrPtr(elf.ptr, i);

        // print segment information to stdout
        var stdout = std.Io.File.stdout();
        var buf: [256]u8 = undefined;
        try stdout.writeStreamingAll(io.*, try std.fmt.bufPrint(&buf, " section type={x:08} offset={x:08} vaddr={x:08} paddr={x:08} filesz={x:08} memsz={x:08}  \n", .{ phdr.p_type, phdr.p_offset, phdr.p_vaddr, phdr.p_paddr, phdr.p_filesz, phdr.p_memsz }));

        // consider only LOAD segments
        if (phdr.p_type != 1) {
            continue;
        }

        // find image base as smallest virtual base address of a segment
        if (image_base == null) {
            image_base = phdr.p_vaddr;
        } else if (phdr.p_vaddr < image_base.?) {
            image_base = phdr.p_vaddr;
        }
        // find image end address similarly
        if (phdr.p_vaddr + phdr.p_memsz > image_end) {
            image_end = phdr.p_vaddr + phdr.p_memsz;
        }
    }

    if (image_base == null) {
        return FlattenElfError.NoLoadSegments;
    }

    const flat_size = image_end - image_base.?;
    var flat = try allocator.alloc(u8, flat_size);
    @memset(flat, 0);

    // copy contents of load segments into the flat image
    i = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const phdr = ehdr.phdrPtr(elf.ptr, i);

        if (phdr.p_type != 1) {
            continue;
        }

        const dest_offset = phdr.p_vaddr - image_base.?;
        @memcpy(flat[dest_offset .. dest_offset + phdr.p_filesz], elf[phdr.p_offset .. phdr.p_offset + phdr.p_filesz]);
    }

    const entry_rva = ehdr.e_entry - image_base.?;
    const sector_count: u32 = @intCast((flat_size + 511) / 512);

    return FlattenResult{
        .data = flat,
        .entry_rva = entry_rva,
        .sector_count = sector_count,
    };
}
