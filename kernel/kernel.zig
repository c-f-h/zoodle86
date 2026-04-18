const console = @import("console.zig");
const keyboard = @import("keyboard.zig");
const ide = @import("ide.zig");
const fs = @import("fs.zig");
const gdt = @import("gdt.zig");
const task = @import("task.zig");
const elf32 = @import("elf32.zig");
const shell = @import("shell.zig");
const idt = @import("idt.zig");
const paging = @import("paging.zig");
const pageallocator = @import("pageallocator.zig");
const syscall = @import("syscall.zig");

const std = @import("std");

const VGA_ATTR: u8 = 0x07;

// GDT selectors
pub const kernel_code_selector: u16 = 1 << 3;
pub const kernel_data_selector: u16 = 2 << 3;
pub const user_code_selector: u16 = (3 << 3) | 3;
pub const user_data_selector: u16 = (4 << 3) | 3;
pub const tss_selector_cpu0: u16 = 5 << 3;

// interrupt vectors
pub const VECTOR_DOUBLE_FAULT = 0x08;
pub const VECTOR_INVALID_TSS = 0x0A;
pub const VECTOR_NOSEGMENT = 0x0B; // Segment Not Present
pub const VECTOR_SS_FAULT = 0x0C; // Stack Segment Fault
pub const VECTOR_GPF = 0x0D; // General Protection Fault
pub const VECTOR_PAGEFAULT = 0x0E; // Page Fault
pub const VECTOR_KEYBOARD = 0x21;
pub const VECTOR_SYSCALL = 0x80;

// External interrupt setup from interrupts.asm
extern fn zero_bss() void;
extern fn interrupts_init() void;
extern fn task_switch() callconv(.naked) noreturn;

// Interrupt handler addresses from interrupts.asm
extern fn exception_isr_int08() void;
extern fn exception_isr_int0A() void;
extern fn exception_isr_int0B() void;
extern fn exception_isr_int0C() void;
extern fn exception_isr_int0D() void;
extern fn page_fault_isr() void;
extern fn keyboard_isr() void;
extern fn syscall_isr() void;

// Keyboard handler
pub const KeyboardHandler = struct {
    handler: *const fn (?*anyopaque, *const keyboard.KeyEvent) u32,
    ctx: ?*anyopaque,
};

var cur_kb_handler: ?KeyboardHandler = null;

pub fn setKeyboardHandler(handler: *const fn (?*anyopaque, *const keyboard.KeyEvent) u32, ctx: ?*anyopaque) void {
    if (cur_kb_handler != null) {
        @panic("Keyboard handler already set");
    }
    cur_kb_handler = KeyboardHandler{
        .handler = handler,
        .ctx = ctx,
    };
}

pub fn clearKeyboardHandler() void {
    cur_kb_handler = null;
}

var alloc: std.mem.Allocator = undefined;
var disk_fs: fs.FileSystem = undefined;

/// Keyboard event consumer called by interrupt handler
export fn consume_key_event(event: *const keyboard.KeyEvent) void {
    if (cur_kb_handler) |handler| {
        _ = handler.handler(handler.ctx, event);
    }
}

// GDT can be global; should contain one TSS entry per CPU
var the_gdt: [6]gdt.Descriptor = undefined;
var gdtr: gdt.GDTR = undefined;

// need one TSS per CPU - esp0 is updated on task switch
var tss_cpu0: gdt.Tss = undefined;

/// Set up the Global Descriptor Table
/// The bootloader already set up a basic one with only the kernel segments.
/// We extend it with user segments and a TSS for user->kernel switches.
fn initGdt() void {
    tss_cpu0.init(kernel_data_selector);
    the_gdt = .{
        // 0: null descriptor - required
        @bitCast(@as(u64, 0)),
        // 1: kernel code segment
        gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = false, .executable = true }, gdt.Flags{}),
        // 2: kernel data segment
        gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = true, .executable = false }, gdt.Flags{}),
        // 3: user code segment
        gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = false, .executable = true, .dpl = 3 }, gdt.Flags{}),
        // 4: user data segment
        gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = true, .executable = false, .dpl = 3 }, gdt.Flags{}),
        // 5: task state segment (TSS) - contains entry point into kernel stack for first CPU
        // access_byte 0x89 for system segment: present = 1, dpl = ring 0, S = 0 (system), type = 0x9 (32-bit TSS - available)
        gdt.makeSystemSegment(@intFromPtr(&tss_cpu0), @sizeOf(gdt.Tss) - 1, 0x89, gdt.Flags{ .size_flag = false, .granularity = false }),
    };
    gdtr.init(&the_gdt);
    gdtr.load();
    gdt.ltr(tss_selector_cpu0); // load TSS for the first CPU and marks the TSS as busy
}

export fn exception_handler(vector: u8, errcode: u32, eip: u32, cs: u16) callconv(.c) noreturn {
    const err_template = "Exception: 00, error code: 00000000. Source: cs=0000 eip=00000000";
    var err: [err_template.len]u8 = undefined;
    @memcpy(&err, err_template);
    console.formatHexU(1, vector, err[11..13]);
    console.formatHexU(4, errcode, err[27..35]);
    console.formatHexU(2, cs, err[48..52]);
    console.formatHexU(4, eip, err[57..65]);

    // The original cs tells us whether the fault happened in userspace (ring 3); in that
    // case we should terminate only the userspace program and continue.
    if ((cs & 3) == 3) {
        console.setAttr(0x0f);
        console.puts(&err);
        console.setAttr(VGA_ATTR);
        console.puts("\nTerminating program.\n");
        kernel_reenter();
    } else {
        // The fault occurred in the kernel; panic!
        @panic(&err);
    }
}

pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

pub export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = val;
    }
    return dest;
}

const E820MemoryMapEntry = struct {
    base: u64, // 8 bytes
    length: u64, // 8 bytes
    type_: u32, // 4 bytes
    acpi_attrs: u32, // 4 bytes
};

fn getMemoryMap() []align(2) E820MemoryMapEntry {
    const mem_map_address = 0x7e00;
    const num_entries = @as(*align(1) u16, @ptrFromInt(mem_map_address)).*;
    return @as([*]align(2) E820MemoryMapEntry, @ptrFromInt(mem_map_address + 2))[0..num_entries];
}

/// Finds the largest contiguous usable memory region below 4GB using the
/// E820 memory map provided by the bootloader.
/// Panics if no suitable region of at least 8MB is found.
fn findUsableMemoryWindow(verbose: bool) struct { u32, u32 } {
    const entries = getMemoryMap();

    var largest_usable_base: u64 = 0;
    var largest_usable_length: u64 = 0;

    for (entries) |*entry| {
        if (verbose) {
            console.put(.{ "  ", entry.base, " - ", entry.base + entry.length, " - type ", entry.type_, "\n" });
        }

        if (entry.type_ == 1) {
            if (entry.base < (1 << 32)) {
                const real_usable_length = @min(entry.length, (1 << 32) - entry.base);
                // Usable RAM below 4GB
                if (real_usable_length > largest_usable_length) {
                    largest_usable_base = entry.base;
                    largest_usable_length = real_usable_length;
                }
            }
        }
    }

    if (largest_usable_length < 8 * 1024 * 1024) {
        @panic("Not enough memory found: 8MB required");
    }

    return .{ @intCast(largest_usable_base), @intCast(largest_usable_length) };
}

fn panicOnError(err: anyerror) noreturn {
    @panic(switch (err) {
        error.OutOfMemory => "Out of memory",
        error.BufferTooSmall => "Buffer too small",
        ide.IdeError.Timeout => "IDE timeout",
        ide.IdeError.DeviceFault => "IDE device fault",
        ide.IdeError.ControllerError => "IDE controller error",
        else => "Unknown error",
    });
}

/// Kernel entry point.
export fn _start() void {
    // This function is initially loaded and invoked at 0x8000 + ofs, even though the code is positioned at
    // 0xC0008000 by the linker script. The initial paging code below does not depend on any data segment
    // addresses or long jumps; therefore it is position independent. Its purpose is to set up paging:
    // the physical lower 1MiB of memory is mapped both at 0x0 virtual and at 0xC0000000 virtual.
    // Then, via assembly, we add 0xC0000000 to esp (which is essentially a no-op) and force a non-relative
    // jump to an address beyond 0xC0000000 by loading it into eax and jumping to it.
    // In other words, we also add 0xC0000000 to eip.
    //
    // All this achieves that the kernel then runs in the higher half, as intended by the linker script.
    // We couldn't load the kernel there directly because paging has to be set up first.
    {
        const max_physical = 0x10_0000; // for now map only the low 1MiB
        const page_tables = @as([*]paging.PageTable, @ptrFromInt(page_dir_phys + 4096));
        paging.initIdentityPaging(@ptrFromInt(page_dir_phys), page_tables, max_physical);
        paging.loadPageDir(page_dir_phys);
        paging.enable();
        asm volatile (
            \\ add $0xC0000000, %%esp
            \\ leal higher_half_jump_target, %%eax
            \\ jmp *%%eax
            \\ higher_half_jump_target:
            ::: .{ .eax = true });
    }

    kernel_main() catch |err| {
        panicOnError(err);
    };
    _ = syscall.syscall_dispatch; // force compiler to emit function
}

const Task = task.Task;

pub var current_task: Task = undefined;

const LINE = 0x10;
const PAGE = 0x1000;

// Preliminary physical memory location for initial Page Directory.
// This is within conventional memory, with 256k of space until 0x80000.
// The initial identity Page Table Entries for the first 1 MiB of RAM are stored immediately afterwards.
const page_dir_phys: u32 = 0x4_0000;

pub inline fn roundDown(p: u32, comptime size: u32) u32 {
    return p & (~(size - 1));
}
pub inline fn roundToNext(p: u32, comptime size: u32) u32 {
    return (p + size - 1) & (~(size - 1));
}

fn kernel_main() !void {
    zero_bss();
    initGdt();

    {
        const cs = kernel_code_selector;
        idt.init();

        // exception handlers
        idt.set(VECTOR_DOUBLE_FAULT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int08), cs, 0);
        idt.set(VECTOR_INVALID_TSS, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0A), cs, 0);
        idt.set(VECTOR_NOSEGMENT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0B), cs, 0);
        idt.set(VECTOR_SS_FAULT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0C), cs, 0);
        idt.set(VECTOR_GPF, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0D), cs, 0);
        idt.set(VECTOR_PAGEFAULT, idt.GateType.TrapGate32, @intFromPtr(&page_fault_isr), cs, 0);

        idt.set(VECTOR_KEYBOARD, idt.GateType.InterruptGate32, @intFromPtr(&keyboard_isr), cs, 0);
        idt.set(VECTOR_SYSCALL, idt.GateType.InterruptGate32, @intFromPtr(&syscall_isr), cs, 3);
        idt.load();
    }

    // remap PIC IRQs into vectors 0x20-0x30, unmask keyboard IRQ, and enable interrupts
    interrupts_init();

    console.console_init(VGA_ATTR);
    console.puts(" -------- zoodle86 loaded --------\n\n");

    const mem_base, const mem_size = findUsableMemoryWindow(false);
    pageallocator.addMemory(mem_base, mem_base + mem_size);

    // kernel data
    const kernel_data = paging.allocateMemoryAt(0xE000_0000, 1024, true, true);
    @memset(kernel_data, 0xDD);
    var fba = std.heap.FixedBufferAllocator.init(kernel_data);
    alloc = fba.allocator();

    const MiB = 1024 * 1024;
    console.put(.{
        "Usable memory: ", mem_base,
        " - ",             mem_base + mem_size,
        ", size=",
    });
    console.putDecU32(@divTrunc(mem_size, MiB));
    console.puts(" MiB\n\n");

    try mountFs();
    //try launchUserspaceElf("userspace.elf", &current_task);
    try shell.run(alloc, &disk_fs);
}

pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

pub inline fn getRegister(comptime reg: [3]u8) u32 {
    // return spec "={eax}" cannot be a comptime string, so we need a mov instruction
    const asm_str = "mov %%" ++ reg ++ ", %%eax";
    return asm volatile (asm_str
        : [ret] "={eax}" (-> u32),
    );
}

pub fn kernel_reenter() noreturn {
    // Switch back to the kernel page directory (without userspace mapping)
    paging.loadPageDir(page_dir_phys);

    console.puts("Returned to kernel, esp = ");
    console.putHexU32(getRegister("esp".*));
    console.newline();

    shell.run(alloc, &disk_fs) catch |err| {
        panicOnError(err);
    };
}

fn numPagesBetween(va0: usize, va1: usize) u32 {
    const va_begin = roundDown(va0, PAGE);
    const va_end = roundToNext(va1, PAGE);
    return @divExact(va_end - va_begin, PAGE);
}

pub fn launchUserspaceElf(fname: []const u8, ptask: *Task) !void {
    var entry: u32 = 0;

    current_task.init();
    // TODO: this should only get the kernel mappings, not any existing userspace mappings
    @memcpy(&current_task.page_dir, paging.getMappedPageDirectory());

    // fix the recursive mapping entry to point to the new page directory
    const new_dir_phys = paging.virtualToPhysical(&current_task.page_dir);
    current_task.page_dir[1023] = paging.PDE{
        .writable = true,
        .user = false,
        .page_table_addr = @truncate(new_dir_phys >> 12),
    };
    paging.loadPageDir(new_dir_phys);

    {
        console.put(.{ "Loading ", fname, "...\n" });
        const elf_data = try disk_fs.readFile(alloc, fname);
        defer alloc.free(elf_data);

        const ehdr: *elf32.Elf32_Ehdr = @ptrCast(@alignCast(elf_data.ptr));

        // compute image extents and locate stack and heap
        const code_start, const code_end, const data_start, const data_end = ehdr.computeImageExtents(elf_data.ptr);
        entry = ehdr.e_entry;
        ptask.stack_top = data_end;
        ptask.stack_bottom = ptask.stack_top - 16 * 1024; // 16 KiB stack space (guaranteed by linker script)
        ptask.heap_top = roundToNext(ptask.stack_top, PAGE); // any remaining space in page can be used for heap

        // user code and data
        const code_pages = numPagesBetween(code_start, code_end);
        const data_pages = numPagesBetween(data_start, data_end);
        const code_mem = paging.allocateMemoryAt(0x40_0000, code_pages, true, true);
        const data_mem = paging.allocateMemoryAt(0x1000_0000, data_pages, true, true);

        @memset(code_mem, 0xC0);
        @memset(data_mem, 0x00);

        console.put(.{ "CODE:  ", code_start, " - ", code_end, ", DATA: ", data_start, " - ", data_end, "; entry: 0x", entry, "\nStack: ", ptask.stack_bottom, " - ", ptask.stack_top, "\n" });

        var i: u32 = 0;

        while (i < ehdr.e_phnum) : (i += 1) {
            const phdr = ehdr.phdrPtr(elf_data.ptr, i);
            if (phdr.p_type != elf32.PT_LOAD) continue;

            const file_start = elf_data.ptr + phdr.p_offset;
            const memsz = phdr.p_memsz;
            const filesz = phdr.p_filesz;

            // TODO: needs bounds checking
            const dest: [*]u8 = @ptrFromInt(phdr.p_vaddr);

            @memcpy(dest[0..filesz], file_start[0..filesz]);
            @memset(dest[filesz..memsz], 0);

            if (phdr.p_flags & elf32.P_X != 0) {
                console.puts("Loaded code segment: ");
            } else {
                console.puts("Loaded data segment: ");
            }
            console.putHexU32(phdr.p_vaddr);
            console.puts(" (");
            console.putDecU32(filesz);
            console.puts(" + ");
            console.putDecU32(memsz - filesz);
            console.puts(" bss bytes)");
            console.newline();
        }
        // Here we can already free the kernel allocation with the file contents
    }

    current_task.updateTss(&tss_cpu0);

    console.puts("\nSwitching to user mode...\n");
    current_task.setEntryPoint(entry, ptask.stack_top);
    current_task.switchTo();
}

fn mountFs() !void {
    const drive = ide.Drive.master;
    ide.selectDrive(drive);

    const drive_info = try ide.identifyDrive(drive);
    console.puts("Drive model:     ");
    console.puts(&drive_info.model);
    console.puts("\nDrive serial:    ");
    console.puts(&drive_info.serial);
    console.puts("\nSectors (LBA28): ");
    console.putDecU32(drive_info.max_lba28);
    console.newline();

    disk_fs = try fs.FileSystem.mountOrFormat(drive);
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = trace;
    _ = return_address;
    console.setCursor(0, 0);
    console.setAttr(0x4F); // Red background, white text
    console.put(.{ "KERNEL PANIC:\n", message, "\nSystem halted." });
    while (true) {}
}
