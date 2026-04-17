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

pub const Task = struct {
    // Each process gets its own kernel stack.
    // The first word in the kernel stack stores a pointer to the current Task.
    kernel_stack: KernelStack align(4096) = undefined,

    // Virtual memory mappings for this task
    page_dir: paging.PageDirectory align(4096) = undefined,

    stack_bottom: u32 = undefined, // virtual address of the beginning of the stack
    stack_top: u32 = undefined, // virtual address of the end of the stack
    heap_top: u32 = undefined, // virtual address of the end of the heap (page-aligned; can grow upwards)

    // Memory layout: code - rodata - data - bss - stack - heap

    pub fn init(task: *Task) void {
        // write *Task into the first word in the kernel stack
        @as(**Task, @ptrCast(&task.kernel_stack)).* = task;
    }

    /// Set up the TSS to point to the kernel stack associated to this task.
    pub fn updateTss(task: *Task, tss: *gdt.Tss) void {
        const stack_top = @intFromPtr(&task.kernel_stack) + @sizeOf(KernelStack);
        tss.setKernelStack(stack_top);
    }

    /// Access a slice of memory within the task's user memory segment.
    pub fn getUserMem(task: *Task, ofs: u32, len: u32) []u8 {
        _ = task;
        const start: [*]u8 = @ptrFromInt(ofs);
        return start[0..len];
    }
};
