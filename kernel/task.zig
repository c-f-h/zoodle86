const gdt = @import("gdt.zig");
const kernel = @import("kernel.zig");

const KERNEL_STACK_SIZE = 4096;
const KernelStack = [KERNEL_STACK_SIZE]u8;

// Currently we only need one kernel stack because we only run on a single CPU.
// For multithreading, each CPU core needs its own kernel stack.
// The first word in the kernel stack stores a pointer to the current Task.
var kernel_stack: KernelStack align(KERNEL_STACK_SIZE) = undefined;

var tss: gdt.Tss = undefined;

/// Set up the global TSS for the single CPU. All tasks use the same TSS.
pub fn initTss() void {
    const stack_top = @intFromPtr(&kernel_stack) + @sizeOf(KernelStack);
    tss.init(kernel.kernel_data_selector, stack_top);
}

/// Given a pointer which points to within a kernel stack, finds the pointer to the associated *Task
pub fn getPointerToTaskPtr(sp: usize) **Task {
    const Kst = @TypeOf(kernel_stack);
    const kss: usize = @sizeOf(Kst);
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
    gdt: [6]gdt.Descriptor = undefined,
    gdtr: gdt.GDTR = undefined,
    user_mem: []u8 = undefined, // slice of user memory (starting at user_cs:0 = user_ds:0) in flat addressing

    /// Configures the GDT for the kernel and the given user-mode code and data descriptors.
    pub fn init(task: *Task, mem: []u8) void {
        const mem_base = @intFromPtr(mem.ptr);
        const mem_pages = @divExact(mem.len, 4 * 1024);

        task.user_mem = mem;

        task.gdt = .{
            // 0: null descriptor - required
            @bitCast(@as(u64, 0)),
            // 1: kernel code segment
            gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = false, .executable = true }, gdt.Flags{}),
            // 2: kernel data segment
            gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = true, .executable = false }, gdt.Flags{}),
            // 3: user code segment
            gdt.makeSegment(mem_base, @truncate(mem_pages - 1), gdt.AccessFlags{ .read_write = false, .executable = true, .dpl = 3 }, gdt.Flags{}),
            // 4: user data segment
            gdt.makeSegment(mem_base, @truncate(mem_pages - 1), gdt.AccessFlags{ .read_write = true, .executable = false, .dpl = 3 }, gdt.Flags{}),
            // 5: task state segment (TSS) - describes entry point into kernel stack
            // access_byte 0x89 for system segment: present = 1, dpl = ring 0, S = 0 (system), type = 0x9 (32-bit TSS - available)
            gdt.makeSystemSegment(@intFromPtr(&tss), @sizeOf(gdt.Tss) - 1, 0x89, gdt.Flags{ .size_flag = false, .granularity = false }),
        };
        task.gdtr.init(&task.gdt);
    }

    pub fn getKernelStack(task: *Task) *align(KERNEL_STACK_SIZE) KernelStack {
        _ = task;
        return &kernel_stack;
    }

    /// Loads the GDT and sets the task register for the current CPU.
    pub fn set(task: *Task) void {
        // write *Task into the first word in the kernel stack
        @as(**Task, @ptrCast(task.getKernelStack())).* = task;

        task.gdtr.load();
        gdt.ltr(kernel.tss_selector);
    }

    /// Access a slice of memory within the task's user memory segment.
    pub fn getUserMem(task: *Task, ofs: u32, len: u32) []u8 {
        return task.user_mem[ofs .. ofs + len];
    }
};
