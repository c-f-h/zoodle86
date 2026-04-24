const console = @import("console.zig");
const filedesc = @import("filedesc.zig");
const keyboard = @import("keyboard.zig");
const ide = @import("ide.zig");
const fs = @import("fs.zig");
const gdt = @import("gdt.zig");
const task = @import("task.zig");
const taskman = @import("taskman.zig");
const elf32 = @import("elf32.zig");
const shell = @import("shell.zig");
const idt = @import("idt.zig");
const paging = @import("paging.zig");
const pageallocator = @import("pageallocator.zig");
const serial = @import("serial.zig");
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
var disk_block_device: ide.IdeBlockDevice = undefined;

/// Returns the kernel allocator used for filesystem-backed syscall scratch buffers.
pub fn getAllocator() std.mem.Allocator {
    return alloc;
}

/// Returns the mounted filesystem instance.
pub fn getFileSystem() *fs.FileSystem {
    return &disk_fs;
}

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
    serial.puts(&err);
    serial.puts("\n");

    // The original cs tells us whether the fault happened in userspace (ring 3); in that
    // case we should terminate only the userspace program and continue.
    if ((cs & 3) == 3) {
        console.setAttr(0x0f);
        console.puts(&err);
        console.setAttr(VGA_ATTR);
        console.puts("\nTerminating program.\n");
        exitCurrentTask(0xFFFF_FFFF);
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

/// Like memcpy but handles overlapping source and destination regions.
pub export fn memmove(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src) or @intFromPtr(dest) >= @intFromPtr(src) + len) {
        var i: usize = 0;
        while (i < len) : (i += 1) dest[i] = src[i];
    } else {
        var i: usize = len;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
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
        const max_physical = 0x10_0000; // for now map only the low 1MiB - requires only one page table
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

const LINE = 0x10;

pub const USER_DATA_START: u32 = 0x1000_0000; // start of userspace data segment
pub const USER_STACK_BOTTOM: u32 = 0x7000_0000; // start of userspace stack
pub const USER_STACK_TOP: u32 = 0x8000_0000; // end of userspace stack (and end of userspace virtual address space)

// Preliminary physical memory location for initial Page Directory.
// This is within conventional memory, with 256k of space until 0x80000.
// The initial identity Page Table Entries for the first 1 MiB of RAM are stored immediately afterwards.
const page_dir_phys: u32 = 0x4_0000;

const memory_bitmap_va: [*]u32 = @ptrFromInt(0xC005_0000); // virtual address where the physical memory bitmap will be stored

fn kernel_main() !void {
    zero_bss();
    serial.init();
    serial.puts("zoodle86 serial online\n");
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
    taskman.init();
    filedesc.init();

    console.console_init(VGA_ATTR);
    console.puts(" -------- zoodle86 loaded --------\n\n");

    const mem_base, const mem_size = findUsableMemoryWindow(false);
    pageallocator.init(memory_bitmap_va[0..256]); // 1 page is enough to map 128 MiB of RAM
    pageallocator.setPhysicalMemoryRange(mem_base, mem_base + mem_size);

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
    //try launchUserspaceElf("userspace.elf");
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

// Re-run the kernel shell.
// TODO/BUG: This may run in a terminated task's kernel stack, which could get overwritten.
fn kernel_reenter() noreturn {
    // Switch back to the kernel page directory (without userspace mapping)
    paging.loadPageDir(page_dir_phys);

    console.puts("Returned to kernel, esp = ");
    console.putHexU32(getRegister("esp".*));
    console.newline();

    shell.run(alloc, &disk_fs) catch |err| {
        panicOnError(err);
    };
}

/// Switch to the next active task, if any, or re-enter the kernel if no other task is runnable.
pub fn reschedule() noreturn {
    const current_task = task.getCurrentTask();
    if (taskman.getNextActiveTask(current_task)) |next_task| {
        next_task.switchTo(&tss_cpu0);
    } else if (current_task.state == .active) {
        // No other task is runnable; switch back to the current one if it is still active
        current_task.switchTo(&tss_cpu0);
    } else {
        // No more active tasks; return to the kernel shell
        kernel_reenter();
    }
}

/// Performs a full userspace process exit: orphans children, releases resources,
/// determines zombie vs. auto-reap, and reschedules.  Never returns.
pub fn exitCurrentTask(exit_code: u32) noreturn {
    const current = task.getCurrentTask();

    // Reparent (and auto-free zombie) children of this task.
    taskman.orphanChildrenOf(current.pid);

    // Release all resources.
    current.cleanup();

    // Decide whether to auto-reap or become a zombie.
    // Auto-reap if: no real parent (shell-spawned), or parent set the reap_children flag.
    const auto_reap = blk: {
        if (current.parent_pid == 0) break :blk true;
        const parent = taskman.findTask(current.parent_pid) orelse break :blk true;
        break :blk parent.reap_children;
    };

    if (auto_reap) {
        current.state = .free;
        current.pid = 0;
    } else if (taskman.wakeWaiterFor(current.pid, exit_code)) {
        // Parent was already blocked in waitpid; wake it and free this slot.
        current.state = .free;
        current.pid = 0;
    } else {
        // Parent will call waitpid later; preserve exit status as a zombie.
        current.exit_status = exit_code;
        current.state = .zombie;
    }

    reschedule();
}

/// Loads an ELF file into a fresh task with an isolated user address space.
/// Returns with the kernel page directory reloaded so the caller can decide when to run it.
pub fn loadUserspaceElf(fname: []const u8, args: []const []const u8) !*task.Task {
    // Task initialization clones the currently active page directory, so start
    // from the kernel-only page tables instead of whatever user task was most
    // recently loaded.
    paging.loadPageDir(page_dir_phys);
    defer paging.loadPageDir(page_dir_phys);

    const ptask = try taskman.newTask();
    errdefer {
        ptask.loadPageDir();
        ptask.terminate();
    }

    console.put(.{ "Loading ", fname, "...\n" });
    const elf_data = try disk_fs.readFile(alloc, fname);
    defer alloc.free(elf_data);

    const ehdr: *align(1) elf32.Elf32_Ehdr = @ptrCast(elf_data.ptr);

    // compute image extents and locate stack and heap
    const code_start, const code_end, const data_start, const data_end = ehdr.computeImageExtents(elf_data.ptr);
    ptask.heap_start = paging.roundToNext(data_end, paging.PAGE);
    ptask.heap_brk = ptask.heap_start;
    if (ptask.heap_start >= USER_STACK_BOTTOM) {
        return error.OutOfMemory;
    }

    // user code and data
    ptask.loadPageDir();
    _ = ptask.code_mem.allocate(0x0040_0000, code_end, true, true);
    _ = ptask.data_mem.allocate(USER_DATA_START, data_end, true, true);
    // Reserve a fixed stack window and map only its top page initially.
    ptask.stack_top = USER_STACK_TOP;
    ptask.stack_bottom = USER_STACK_BOTTOM;
    _ = ptask.stack_mem.allocate(ptask.stack_top - paging.PAGE, ptask.stack_top, true, true);

    console.put(.{
        "CODE:  ",   code_start,         " - ", code_end,        ", DATA: ",   data_start,           " - ", data_end,        "; entry: 0x", ehdr.e_entry,
        "\nStack: ", ptask.stack_bottom, " - ", ptask.stack_top, " (mapped: ", ptask.stack_mem.base, " - ", ptask.stack_top, ")\n",
    });

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

    // mark code segment read-only after initialization
    ptask.code_mem.changePermissions(true, false);

    const initial_esp = try ptask.setArgs(args);
    ptask.setEntryPoint(ehdr.e_entry, initial_esp);
    return ptask;
}

pub fn run(ptask: *task.Task) void {
    ptask.switchTo(&tss_cpu0);
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

    disk_block_device = ide.IdeBlockDevice.init(drive, drive_info.max_lba28);
    disk_fs = try fs.FileSystem.mountOrFormat(&disk_block_device.block_dev);
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = trace;
    _ = return_address;
    serial.puts("KERNEL PANIC:\n");
    serial.puts(message);
    serial.puts("\nSystem halted.\n");
    console.setCursor(0, 0);
    console.setAttr(0x4F); // Red background, white text
    console.put(.{ "KERNEL PANIC:\n", message, "\nSystem halted." });
    while (true) {}
}
