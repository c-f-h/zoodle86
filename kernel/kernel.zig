/// Proper kernel entry point and runtime.
/// This file is compiled into kernel.elf and loaded from the filesystem by the stage2
/// boot loader.  It owns all kernel functionality: GDT/IDT setup, paging, memory
/// management, task management, syscalls, filesystem, and the interactive shell.
const console = @import("console.zig");
const filedesc = @import("filedesc.zig");
const framebuf = @import("gfx/framebuf.zig");
const vconsole = @import("gfx/vconsole.zig");
const interrupt_frame = @import("interrupt_frame.zig");
const keyboard = @import("keyboard.zig");
const kprof = @import("kprof.zig");
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
const pit = @import("pit.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");

const std = @import("std");

var graphical = false;

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
pub const VECTOR_TIMER = 0xE8;
pub const VECTOR_KEYBOARD = 0xD8;
pub const VECTOR_SYSCALL = 0x80;
pub const VECTOR_SPURIOUS = 0xFF;

// Interrupt handler addresses from interrupts.asm
extern fn exception_isr_int08() void;
extern fn exception_isr_int0A() void;
extern fn exception_isr_int0B() void;
extern fn exception_isr_int0C() void;
extern fn exception_isr_int0D() void;
extern fn page_fault_isr() void;
extern fn timer_isr() void;
extern fn keyboard_isr() void;
extern fn syscall_isr() void;
extern fn spurious_isr() void;

/// Keyboard event handler vtable entry.
pub const KeyboardHandler = struct {
    handler: *const fn (?*anyopaque, *const keyboard.KeyEvent) u32,
    ctx: ?*anyopaque,
};

var cur_kb_handler: ?KeyboardHandler = null;
var task_switch_count: u32 = 0;

var timer_ticks: u32 = 0;

fn timerIrqHandler(frame: *const interrupt_frame.InterruptFrame) void {
    timer_ticks += 1;
    kprof.onTimerTick(frame.eip);
    //const attr: u8 = if ((timer_ticks & 0x100) != 0) 0x70 else 0x07;
    //console.putCharAt(0, 79, @truncate(timer_ticks & 0xFF), attr);
}

/// Install the global keyboard event handler.  Only one handler may be active at a time.
pub fn setKeyboardHandler(handler: *const fn (?*anyopaque, *const keyboard.KeyEvent) u32, ctx: ?*anyopaque) void {
    if (cur_kb_handler != null) {
        @panic("Keyboard handler already set");
    }
    cur_kb_handler = KeyboardHandler{
        .handler = handler,
        .ctx = ctx,
    };
}

/// Remove the previously installed keyboard event handler.
pub fn clearKeyboardHandler() void {
    cur_kb_handler = null;
}

var kernel_fba: std.heap.FixedBufferAllocator = undefined;
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

/// Keyboard event consumer called by the interrupt handler.
pub fn consumeKeyEvent(event: *const keyboard.KeyEvent) void {
    if (cur_kb_handler) |handler| {
        _ = handler.handler(handler.ctx, event);
    }
}

// GDT can be global; should contain one TSS entry per CPU
var the_gdt: [6]gdt.Descriptor = undefined;
var gdtr: gdt.GDTR = undefined;

// need one TSS per CPU - esp0 is updated on task switch
var tss_cpu0: gdt.Tss = undefined;

/// Set up the Global Descriptor Table with kernel, user, and TSS segments.
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

/// Single entry point into the kernel from IRQs/exceptions/syscalls.
export fn interrupt_dispatch(frame: *interrupt_frame.InterruptFrame) callconv(.c) void {
    if (frame.vector == VECTOR_KEYBOARD or frame.vector == VECTOR_TIMER) {
        // Acknowledge EOI on LAPIC interrups
        apic.lapic_eoi();
    }
    if (frame.fromUserMode())
        task.saveReturnFrame(@ptrCast(frame));

    switch (frame.vector) {
        VECTOR_TIMER => {
            timerIrqHandler(frame);
            if (frame.fromUserMode())
                reschedule();
        },
        VECTOR_KEYBOARD => keyboard.keyboard_dispatch(frame),
        VECTOR_SYSCALL => syscall.syscall_dispatch(@ptrCast(frame)),
        VECTOR_DOUBLE_FAULT, VECTOR_INVALID_TSS, VECTOR_NOSEGMENT, VECTOR_SS_FAULT, VECTOR_GPF => exception_handler(frame),
        VECTOR_PAGEFAULT => page_fault_handler(frame),
        else => @panic("Unknown interrupt vector"),
    }
}

fn exception_handler(frame: *const interrupt_frame.InterruptFrame) noreturn {
    const vector: u8 = @truncate(frame.vector);
    const errcode = frame.error_code;
    const eip = frame.eip;
    const cs: u16 = @truncate(frame.cs);
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
    if (frame.fromUserMode()) {
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
        error.FileNotFound => "File not found",
        error.BufferTooSmall => "Buffer too small",
        error.InvalidELF => "Invalid ELF",
        ide.IdeError.Timeout => "IDE timeout",
        ide.IdeError.DeviceFault => "IDE device fault",
        ide.IdeError.ControllerError => "IDE controller error",
        else => "Unknown error",
    });
}

const Task = task.Task;

pub const USER_DATA_START: u32 = 0x1000_0000; // start of userspace data segment
pub const USER_STACK_BOTTOM: u32 = 0x7000_0000; // start of userspace stack
pub const USER_STACK_TOP: u32 = 0x8000_0000; // end of userspace stack (and end of userspace virtual address space)

const KERNEL_SHELL_STACK_SIZE = 16 * 1024;
var kernel_shell_stack: [KERNEL_SHELL_STACK_SIZE]u8 align(4096) = undefined;

const memory_bitmap_va: [*]u32 = @ptrFromInt(0xC005_0000); // virtual address where the physical memory bitmap will be stored

// Physical address of the bootstrap page directory set up by the stage2 loader.
// Passed in by kernel_init and used by kernel_reenter to reload the kernel-only PD.
var page_dir_phys: u32 = undefined;

fn kernel_enter() !noreturn {
    // NB: This function runs on a temporary stack; its locals won't survive into the kernel shell.
    serial.init();
    serial.puts(" --- kernel_enter  ---\n");
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

        idt.set(VECTOR_TIMER, idt.GateType.InterruptGate32, @intFromPtr(&timer_isr), cs, 0);
        idt.set(VECTOR_KEYBOARD, idt.GateType.InterruptGate32, @intFromPtr(&keyboard_isr), cs, 0);
        idt.set(VECTOR_SYSCALL, idt.GateType.InterruptGate32, @intFromPtr(&syscall_isr), cs, 3);
        idt.set(VECTOR_SPURIOUS, idt.GateType.InterruptGate32, @intFromPtr(&spurious_isr), cs, 0);
        idt.load();
    }

    console.init(VGA_ATTR);
    if (video_info_phys_addr != 0) {
        graphical = true;
        console.enableBufferedBackend();
    }

    console.puts(" -------- zoodle86 loaded --------\n\n");

    const mem_base, const mem_size = findUsableMemoryWindow(false);
    // The page allocator must only manage extended memory (above 1 MB) so that
    // conventional memory (boot structures, stage2, kernel code) is never overwritten.
    if (mem_base < 0x10_0000) @panic("page allocator would manage conventional memory");
    pageallocator.init(memory_bitmap_va[0..256]); // 1 page is enough to map 128 MiB of RAM
    pageallocator.setPhysicalMemoryRange(mem_base, mem_base + mem_size);

    // kernel data
    const kernel_data = paging.allocateMemoryAt(0xE000_0000, 1024, false, true);
    @memset(kernel_data, 0xDD);
    kernel_fba = std.heap.FixedBufferAllocator.init(kernel_data);
    alloc = kernel_fba.allocator();
    kprof.init(alloc);
    taskman.init();

    console.put(.{
        "Usable memory: ", mem_base,
        " - ",             mem_base + mem_size,
        ", size=",
    });
    console.putDecU32(@divTrunc(mem_size, 1024 * 1024));
    console.puts(" MiB\n\n");

    acpi.init();
    filedesc.init();

    //apic.assignInterruptVector(0, 0, VECTOR_TIMER); // IRQ0: timer
    apic.assignInterruptVector(0, 1, VECTOR_KEYBOARD); // IRQ1: keyboard

    // The APIC timer frequency should be calibrated, e.g., from PIT.
    // This appears to be inconsistent on emulators. For now I'm using a hardcoded value
    // that seems to produce a timer frequency in the ballpark of 100 Hz on Bochs and QEMU.
    apic.initTimer(VECTOR_TIMER, apic.Divider.div16);
    apic.startTimer(100000);
    asm volatile ("sti");

    try mountFs();

    if (graphical) {
        try framebuf.init(video_info_phys_addr);
        // Font size must be known before determining console panel dimensions
        try vconsole.loadFont(alloc, &disk_fs, "cp850-8x14.psf");
        const text_size = try vconsole.preferredTextSize();
        try console.enableFramebufBackend(alloc, text_size.cols, text_size.rows);
        try vconsole.init();
        console.refresh();
    }
    _ = syscall.syscall_dispatch; // referenced by interrupts.asm's syscall_isr; force inclusion
    enterKernelShell();
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

fn runKernelShell() noreturn {
    shell.run(alloc, &disk_fs) catch |err| {
        panicOnError(err);
    };
}

fn enterKernelShell() noreturn {
    const stack_top = @intFromPtr(&kernel_shell_stack) + kernel_shell_stack.len;
    asm volatile (
        \\ mov %[stack_top], %%esp
        \\ call *%[entry]
        :
        : [stack_top] "r" (stack_top),
          [entry] "r" (@intFromPtr(&runKernelShell)),
        : .{ .memory = true });
    unreachable;
}

// Re-run the kernel shell on the dedicated kernel shell stack rather than the just-exited task stack.
fn kernel_reenter() noreturn {
    // Switch back to the kernel page directory (without userspace mapping)
    paging.loadPageDir(page_dir_phys);

    console.puts("Returned to kernel, esp = ");
    console.putHexU32(getRegister("esp".*));
    console.newline();

    enterKernelShell();
}

/// Return the number of scheduler-driven task-to-task switches since boot.
pub fn getTaskSwitchCount() u32 {
    return task_switch_count;
}

/// Return the number of timer IRQ ticks handled since boot.
pub fn getTimerTicks() u32 {
    return timer_ticks;
}

/// Switch to the next active task, if any, or re-enter the kernel if no other task is runnable.
pub fn reschedule() noreturn {
    const current_task = task.getCurrentTask();
    if (taskman.getNextActiveTask(current_task)) |next_task| {
        if (next_task != current_task) {
            task_switch_count += 1;
        }
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

/// Start running the given task by switching its page directory and restoring its register state.
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

// ---- Page fault handler (moved from paging.zig) ----

/// Attempt to handle a page fault in userspace, e.g. by growing the stack.
/// Returns true if the fault was handled and execution can resume.
fn handlePageFault(va: usize, errcode: u32) bool {
    if (errcode != 6) {
        // 6 = page not present, write access, user mode - for stack growth
        return false;
    }
    const ptask = task.getCurrentTask();
    const fault_page = paging.roundDown(va, paging.PAGE);
    // Only allow growing the stack down to the predefined limit (stack_bottom)
    if (fault_page >= ptask.stack_bottom and fault_page < ptask.stack_mem.base) {
        const additional_pages = paging.numPagesBetween(fault_page, ptask.stack_mem.base);
        ptask.stack_mem.growDown(additional_pages);
        return true;
    }
    return false;
}

/// Page fault dispatcher: handles growable user stacks; terminates the program on
/// unrecoverable faults; panics if the fault happened in kernel mode.
fn page_fault_handler(frame: *const interrupt_frame.InterruptFrame) void {
    const errcode = frame.error_code;
    const eip = frame.eip;

    // Read CR2 to get faulting address
    const fault_va = asm volatile ("mov %%cr2, %%eax"
        : [ret] "={eax}" (-> u32),
    );

    if (handlePageFault(fault_va, errcode))
        return;

    const old_mirror_state = console.isSerialMirrorEnabled();
    console.setSerialMirrorEnabled(true);
    console.put(.{
        "\n!!! PAGE FAULT !!!\nError code: ", errcode,
        "\nAddress:    ",                     fault_va,
        "\neip:        ",                     eip,
    });
    console.setSerialMirrorEnabled(old_mirror_state);

    if (frame.fromUserMode()) {
        console.puts("\nTerminating program.\n");
        console.setSerialMirrorEnabled(old_mirror_state);
        exitCurrentTask(0xFFFF_FFFF);
    } else {
        console.puts("\nHalting.\n");
        while (true) {
            asm volatile ("hlt");
        }
    }
}

// ---- Kernel entry point ----

fn kernel_enter_trampoline() noreturn {
    kernel_enter() catch |err| panicOnError(err);
}

var video_info_phys_addr: u32 = 0;

/// Kernel entry point called by the stage2 boot loader after loading this ELF.
/// `pd_phys` is the physical address of the bootstrap page directory set up by stage2.
/// `video_info_phys` points to boot video metadata prepared by the bootloader.
pub export fn kernel_init(pd_phys: u32, video_info_phys: u32) callconv(.c) noreturn {
    page_dir_phys = pd_phys;
    video_info_phys_addr = video_info_phys;

    // Switch to the kernel's own initial stack before touching any globals.
    const stack_top = @intFromPtr(&kernel_shell_stack) + kernel_shell_stack.len;
    asm volatile (
        \\ mov %[stack_top], %%esp
        \\ call *%[entry]
        :
        : [stack_top] "r" (stack_top),
          [entry] "r" (@intFromPtr(&kernel_enter_trampoline)),
        : .{ .memory = true });
    unreachable;
}
