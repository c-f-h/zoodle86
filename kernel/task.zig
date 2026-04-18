const gdt = @import("gdt.zig");
const paging = @import("paging.zig");
const kernel = @import("kernel.zig");

const KERNEL_STACK_SIZE = 4096;
const KernelStack = [KERNEL_STACK_SIZE]u8;

/// Given a pointer which points to within a kernel stack, finds the pointer to the associated *Task
pub fn getPointerToTaskPtr(sp: usize) **Task {
    const kss: usize = @sizeOf(KernelStack);
    comptime {
        if ((kss & (kss - 1)) != 0) @compileError("Kernel stack size must be power of 2");
    }
    // NB: This is incorrect if sp points just past the end of the stack, but if we are in
    // kernel space then the kernel stack cannot be empty.
    const stack_base = sp & (~(kss - 1));
    // current Task pointer is stored at the bottom of the kernel stack
    return @as(**Task, @ptrFromInt(stack_base));
}

pub inline fn getCurrentTask() *Task {
    const sp = kernel.getRegister("esp".*);
    return getPointerToTaskPtr(sp).*;
}

var next_pid: u32 = 1;

pub const Task = struct {
    // Each process gets its own kernel stack.
    // The first word in the kernel stack stores a pointer to the current Task.
    kernel_stack: KernelStack align(4096) = undefined,

    // Virtual memory mappings for this task
    page_dir: paging.PageDirectory align(4096) = undefined,

    pid: u32 = undefined, // unique process id
    kernel_esp: usize = undefined, // kernel stack pointer on entry

    stack_bottom: u32 = undefined, // virtual address of the beginning of the stack
    stack_top: u32 = undefined, // virtual address of the end of the stack
    heap_top: u32 = undefined, // virtual address of the end of the heap (page-aligned; can grow upwards)

    // Memory layout: code - rodata - data - bss - stack - heap

    pub fn init(task: *Task) void {
        // write *Task into the first word in the kernel stack
        @as(**Task, @ptrCast(&task.kernel_stack)).* = task;
        task.pid = next_pid;
        next_pid += 1;

        // Fill the initial stack frame which will be used to enter user mode
        // Standard stack frame expected by iretd for user mode return (5 words):
        const stack_frame = @as([*]u32, @ptrCast(&task.kernel_stack)) + KERNEL_STACK_SIZE / 4 - 5;
        stack_frame[4] = kernel.user_data_selector; // user SS
        stack_frame[3] = 0; // user ESP - set by process loader
        stack_frame[2] = 0x202; // eflags
        stack_frame[1] = kernel.user_code_selector; // user CS
        stack_frame[0] = 0; // user EIP (entry point) - set by process loader

        // ds, es, pushad
        const regs = (stack_frame - 10)[0..10];
        @memset(regs, 0);
        regs[8] = kernel.user_data_selector;
        regs[9] = kernel.user_data_selector;

        task.kernel_esp = @intFromPtr(regs);
    }

    /// Set up the TSS to point to the kernel stack associated to this task.
    pub fn updateTss(task: *Task, tss: *gdt.Tss) void {
        const stack_top = @intFromPtr(&task.kernel_stack) + @sizeOf(KernelStack);
        tss.setKernelStack(stack_top);
    }

    /// Set the initial instruction and stack pointers for entry into user space.
    pub fn setEntryPoint(task: *Task, eip: u32, esp: u32) void {
        const stack_frame = @as([*]u32, @ptrCast(&task.kernel_stack)) + KERNEL_STACK_SIZE / 4 - 5;
        stack_frame[3] = esp;
        stack_frame[0] = eip;
    }

    pub inline fn switchTo(task: *Task) noreturn {
        asm volatile (
            \\ jmp task_switch
            :
            : [kernel_esp] "{eax}" (task.kernel_esp),
        );
        unreachable;
    }

    /// Access a slice of memory within the task's user memory segment.
    pub fn getUserMem(task: *Task, ofs: u32, len: u32) []u8 {
        _ = task;
        const start: [*]u8 = @ptrFromInt(ofs);
        return start[0..len];
    }
};

/// Save the kernel stack pointer for the current task (for task switching).
pub export fn save_kernel_stack_ptr(kernel_esp: usize) callconv(.c) void {
    getCurrentTask().kernel_esp = kernel_esp;
}
