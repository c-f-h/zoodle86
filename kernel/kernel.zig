const console = @import("console.zig");
const keyboard = @import("keyboard.zig");
const ide = @import("ide.zig");
const fs = @import("fs.zig");
const task = @import("task.zig");
const elf32 = @import("elf32.zig");
const shell = @import("shell.zig");
const idt = @import("idt.zig");

const std = @import("std");

const VGA_ATTR: u8 = 0x07;

// GDT selectors
pub const kernel_code_selector: u16 = 1 << 3;
pub const kernel_data_selector: u16 = 2 << 3;
pub const user_code_selector: u16 = (3 << 3) | 3;
pub const user_data_selector: u16 = (4 << 3) | 3;
pub const tss_selector: u16 = 5 << 3;

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
extern fn enter_user_mode(user_eip: u32, user_esp: u32) noreturn;

// Interrupt handler addresses from interrupts.asm
extern fn exception_isr_int08() void;
extern fn exception_isr_int0A() void;
extern fn exception_isr_int0B() void;
extern fn exception_isr_int0C() void;
extern fn exception_isr_int0D() void;
extern fn exception_isr_int0E() void;
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

fn sys_write(fd: u32, ofs: u32, count: u32) u32 {
    if (fd != 1)
        return 0;

    const data = task.getCurrentTask().getUserMem(ofs, count);
    console.puts(data);
    return count;
}

/// Dispatches the int 0x80 syscall ABI invoked by user-mode executables.
export fn syscall_dispatch(nr: u32, arg1: u32, arg2: u32, arg3: u32) callconv(.c) u32 {
    switch (nr) {
        1 => { // write
            return sys_write(arg1, arg2, arg3);
        },
        60 => { // exit
            kernel_reenter();
        },
        else => return 0xffff_ffff,
    }
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
            console.puts("  ");
            console.putHexU64(entry.base);
            console.puts(" - ");
            console.putHexU64(entry.base + entry.length);
            console.puts(" - type ");
            console.putDecU32(entry.type_);
            console.newline();
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

/// Kernel entry point
export fn _start() void {
    kernel_main() catch |err| {
        panicOnError(err);
    };
}

var user_mem: []u8 = undefined;

const Task = task.Task;

pub var current_task: Task = undefined;

const LINE = 0x10;
const PAGE = 0x1000;

pub inline fn roundToNext(p: u32, comptime size: u32) u32 {
    return (p + size - 1) & (~(size - 1));
}

fn kernel_main() !void {
    zero_bss();

    {
        const cs = kernel_code_selector;
        idt.init();

        // exception handlers
        idt.set(VECTOR_DOUBLE_FAULT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int08), cs, 0);
        idt.set(VECTOR_INVALID_TSS, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0A), cs, 0);
        idt.set(VECTOR_NOSEGMENT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0B), cs, 0);
        idt.set(VECTOR_SS_FAULT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0C), cs, 0);
        idt.set(VECTOR_GPF, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0D), cs, 0);
        idt.set(VECTOR_PAGEFAULT, idt.GateType.TrapGate32, @intFromPtr(&exception_isr_int0E), cs, 0);

        idt.set(VECTOR_KEYBOARD, idt.GateType.InterruptGate32, @intFromPtr(&keyboard_isr), cs, 0);
        idt.set(VECTOR_SYSCALL, idt.GateType.InterruptGate32, @intFromPtr(&syscall_isr), cs, 3);
        idt.load();
    }

    // remap PIC IRQs into vectors 0x20-0x30, unmask keyboard IRQ, and enable interrupts
    interrupts_init();

    console.console_init(VGA_ATTR);
    console.puts(" -------- zoodle86 loaded --------\n\n");

    const mem_base, const mem_size = findUsableMemoryWindow(false);
    const MiB = 1024 * 1024;

    console.puts("Usable memory: ");
    console.putHexU32(mem_base);
    console.puts(" - ");
    console.putHexU32(mem_base + mem_size);
    console.puts(", size=");
    console.putDecU32(@divTrunc(mem_size, MiB));
    console.puts(" MiB");
    console.newline();

    var all_mem: []u8 = @as([*]u8, @ptrFromInt(mem_base))[0..mem_size];
    var fba = std.heap.FixedBufferAllocator.init(all_mem[0 .. 2 * MiB]);
    alloc = fba.allocator();

    user_mem = all_mem[2 * MiB ..];

    task.initTss();

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

fn kernel_reenter() noreturn {
    console.puts("Returned to kernel, esp = ");
    console.putHexU32(getRegister("esp".*));
    console.newline();

    shell.run(alloc, &disk_fs) catch |err| {
        panicOnError(err);
    };
}

pub fn launchUserspaceElf(fname: []const u8, ptask: *Task) !void {
    var entry: u32 = 0;
    {
        console.puts("Loading ");
        console.puts(fname);
        console.puts("...\n");
        const elf_data = try disk_fs.readFile(alloc, fname);
        defer alloc.free(elf_data);

        const ehdr: *elf32.Elf32_Ehdr = @ptrCast(@alignCast(elf_data.ptr));

        // compute image extents and append stack and heap
        const vstart, const vend = ehdr.computeImageExtents(elf_data.ptr);
        entry = ehdr.e_entry;
        ptask.stack_bottom = roundToNext(vend, LINE);
        ptask.stack_top = ptask.stack_bottom + 16 * 1024; // 16 kib stack space
        ptask.heap_top = roundToNext(ptask.stack_top, PAGE);

        console.puts("Extents: ");
        console.putHexU32(vstart);
        console.puts(" - ");
        console.putHexU32(vend);
        console.puts(", entry point: 0x");
        console.putHexU32(entry);
        console.puts("\nStack:   ");
        console.putHexU32(ptask.stack_bottom);
        console.puts(" - ");
        console.putHexU32(ptask.stack_top);
        console.newline();

        var i: u32 = 0;
        while (i < ehdr.e_phnum) : (i += 1) {
            const phdr = ehdr.phdrPtr(elf_data.ptr, i);
            if (phdr.p_type != elf32.PT_LOAD) continue;

            const file_start = elf_data.ptr + phdr.p_offset;
            const memsz = phdr.p_memsz;
            const filesz = phdr.p_filesz;

            const dest: [*]u8 = user_mem.ptr + phdr.p_vaddr;

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

    // TODO: keep track of allocated user memory
    const task_mem = user_mem[0..current_task.heap_top];
    current_task.init(task_mem);
    current_task.set();

    console.puts("Allocated linear memory block: ");
    console.putHexU32(@intFromPtr(task_mem.ptr));
    console.puts(" - ");
    console.putHexU32(@intFromPtr(task_mem.ptr) + task_mem.len);

    console.puts("\nSwitching to user mode...\n");
    enter_user_mode(entry, ptask.stack_top);
}

fn mountFs() !void {
    const drive = ide.Drive.master;
    ide.selectDrive(drive);

    const drive_info = try ide.identifyDrive(drive);
    console.puts("Drive model:     ");
    console.puts(&drive_info.model);
    console.newline();
    console.puts("Drive serial:    ");
    console.puts(&drive_info.serial);
    console.newline();
    console.puts("Sectors (LBA28): ");
    console.putDecU32(drive_info.max_lba28);
    console.newline();

    disk_fs = try fs.FileSystem.mountOrFormat(drive);
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = trace;
    _ = return_address;
    console.setCursor(0, 0);
    console.setAttr(0x4F); // Red background, white text
    console.puts("KERNEL PANIC:\n");
    console.puts(message);
    console.puts("\nSystem halted.");
    while (true) {}
}
