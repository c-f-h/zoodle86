/// Minimal stage-2 boot loader.
/// Responsibilities: set up 4MB identity paging (physical 0–4MB mapped at both VA 0
/// and VA 0xC0000000), mount the filesystem, load kernel.elf from the filesystem,
/// and jump into the kernel via kernel_init(page_dir_phys).
const elf32 = @import("elf32.zig");
const fs = @import("fs.zig");
const ide = @import("ide.zig");
const idt = @import("idt.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");
const vgatext = @import("vgatext.zig");

const std = @import("std");

extern const _bss_start: u8;
extern const _bss_end: u8;

// Linker-assigned physical address of the bootstrap page directory.
// Kept well above the stage2 binary (which loads at 0x8000) and its BSS.
const page_dir_phys: u32 = 0x4_0000;

var disk_fs: fs.FileSystem = undefined;
var disk_block_device: ide.IdeBlockDevice = undefined;

/// Display an error message in red and halt the CPU. Used before console is available.
fn earlyBootFail(message: []const u8) noreturn {
    vgatext.disableCursor();
    vgatext.clear(0x4F);
    var row: u32 = 0;
    var col: u32 = 0;
    for (message) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
            if (row >= vgatext.TEXT_HEIGHT) break;
            continue;
        }
        if (col >= vgatext.TEXT_WIDTH) {
            row += 1;
            col = 0;
            if (row >= vgatext.TEXT_HEIGHT) break;
        }
        vgatext.putCharAt(row, col, ch, 0x4F);
        col += 1;
    }
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Assert that stage2's BSS does not overlap the bootstrap page directory.
fn ensureStage2BssFitsBootstrapPageTables() void {
    const stage2_end_phys = paging.virtualToPhysical(@ptrCast(@constCast(&_bss_end)));
    if (stage2_end_phys > page_dir_phys) {
        earlyBootFail("PANIC: stage2 .bss overlaps bootstrap page directory");
    }
}

/// Read the "kernel" ELF from the filesystem and jump to its entry point.
/// Each PT_LOAD segment is read directly to its link-time virtual address (already mapped).
fn loadKernelElfAndJump() noreturn {
    const kernel_inode = (disk_fs.findFileInodeIndex("kernel") catch
        earlyBootFail("FS error: cannot find kernel")) orelse
        earlyBootFail("FS error: cannot find kernel");

    // Read the 52-byte ELF header
    var ehdr_buf: [@sizeOf(elf32.Elf32_Ehdr)]u8 = undefined;
    const n = disk_fs.readInodeAt(kernel_inode, 0, &ehdr_buf) catch
        earlyBootFail("FS read error: ELF header");
    if (n < @sizeOf(elf32.Elf32_Ehdr)) earlyBootFail("kernel: not an x86 ELF");

    if (!std.mem.eql(u8, ehdr_buf[0..4], "\x7FELF")) earlyBootFail("kernel: not an x86 ELF");
    if (ehdr_buf[4] != 1) earlyBootFail("kernel: not an x86 ELF");

    const ehdr: *align(1) elf32.Elf32_Ehdr = @ptrCast(&ehdr_buf);
    if (ehdr.e_machine != 3) earlyBootFail("kernel: not an x86 ELF");

    // Load each PT_LOAD segment directly to its link-time virtual address.
    // Segments must land in conventional memory (below 1 MB) and must not overlap
    // the bootstrap page directory/table or the stage2 image.
    const stage2_end_phys = paging.virtualToPhysical(@ptrCast(@constCast(&_bss_end)));
    // Reserved physical ranges that kernel segments must not touch:
    //   [0, stage2_end_phys)          stage2 code/data/BSS
    //   [page_dir_phys, page_dir_phys + 2*PAGE)   bootstrap PD + first PT
    var i: u32 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr_buf: [@sizeOf(elf32.Elf32_Phdr)]u8 = undefined;
        const phdr_off = ehdr.e_phoff + i * ehdr.e_phentsize;
        _ = disk_fs.readInodeAt(kernel_inode, phdr_off, &phdr_buf) catch
            earlyBootFail("FS read error");
        const phdr: *align(1) elf32.Elf32_Phdr = @ptrCast(&phdr_buf);
        if (phdr.p_type != elf32.PT_LOAD) continue;

        // Translate the kernel's virtual load address to its physical address.
        const seg_phys: u32 = phdr.p_vaddr - 0xC000_0000;
        const seg_end: u32 = seg_phys + phdr.p_memsz;

        // The kernel must live in conventional memory (below 1 MB).
        if (seg_end > 0x10_0000) earlyBootFail("kernel segment exceeds conventional memory");

        // Must not overlap stage2 image.
        if (seg_phys < stage2_end_phys and seg_end > 0)
            earlyBootFail("kernel segment overlaps stage2 image");

        // Must not overlap the bootstrap page directory or its first page table.
        const pd_end = page_dir_phys + 2 * paging.PAGE;
        if (seg_phys < pd_end and seg_end > page_dir_phys)
            earlyBootFail("kernel segment overlaps bootstrap page tables");

        const dest: [*]u8 = @ptrFromInt(phdr.p_vaddr);
        _ = disk_fs.readInodeAt(kernel_inode, phdr.p_offset, dest[0..phdr.p_filesz]) catch
            earlyBootFail("FS read error");
        @memset(dest[phdr.p_filesz..phdr.p_memsz], 0);
    }

    const entry: *const fn (u32) callconv(.c) noreturn = @ptrFromInt(ehdr.e_entry);
    entry(page_dir_phys);
}

fn mountFs() !void {
    const drive = ide.Drive.master;
    ide.selectDrive(drive);
    const drive_info = try ide.identifyDrive(drive);
    disk_block_device = ide.IdeBlockDevice.init(drive, drive_info.max_lba28);
    disk_fs = try fs.FileSystem.mountOrFormat(&disk_block_device.block_dev);
}

fn loader_main() noreturn {
    // Physical 0–1MB is mapped at VA 0, with the recursive page directory entry at PD[1023],
    // so that kernel.elf (linked at 0xC0010000 = physical 0x10000) is reachable after paging
    // is enabled.
    {
        const max_physical = 0x10_0000; // 1MB; one page table covers exactly this range
        const page_tables = @as([*]paging.PageTable, @ptrFromInt(page_dir_phys + paging.PAGE));
        paging.initIdentityPaging(@ptrFromInt(page_dir_phys), page_tables, max_physical);
        paging.loadPageDir(page_dir_phys);
        paging.enable();
    }

    ensureStage2BssFitsBootstrapPageTables();

    // Zero stage2 BSS
    const bss_start_addr = @intFromPtr(&_bss_start);
    const bss_end_addr = @intFromPtr(&_bss_end);
    if (bss_end_addr > bss_start_addr) {
        @memset(@as([*]u8, @ptrFromInt(bss_start_addr))[0 .. bss_end_addr - bss_start_addr], 0);
    }

    serial.init();

    // Install a null IDT; any fault triple-faults cleanly
    idt.init();
    idt.load();

    serial.puts(" --- stage2 loader ---\n");

    mountFs() catch earlyBootFail("Failed to mount filesystem");

    loadKernelElfAndJump();
}

/// Loader entry point called by the bootloader at physical 0x8000.
/// Sets up 1MB identity paging and calls loader_main.
export fn _start() void {
    loader_main();
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = trace;
    _ = return_address;
    earlyBootFail(message);
}

// Compiler-runtime builtins: LLVM generates calls to these for bulk memory ops.

pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) dest[i] = src[i];
    return dest;
}

pub export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) dest[i] = val;
    return dest;
}
