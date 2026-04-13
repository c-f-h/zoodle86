const gdt = @import("gdt.zig");
const kernel = @import("kernel.zig");

pub const kernel_code_selector: u16 = 1 << 3;
pub const kernel_data_selector: u16 = 2 << 3;
pub const user_code_selector: u16 = (3 << 3) | 3;
pub const user_data_selector: u16 = (4 << 3) | 3;
pub const tss_selector: u16 = 5 << 3;

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
    tss.init(kernel_data_selector, stack_top);
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

    pub fn init(task: *Task) void {
        // initialize data members in code rather than via .data to reduce binary size
        task.gdt = .{
            // 0: null descriptor - required
            @bitCast(@as(u64, 0)),
            // 1: kernel code segment
            gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = false, .executable = true }, gdt.Flags{}),
            // 2: kernel data segment
            gdt.makeSegment(0, 0xFFFFF, gdt.AccessFlags{ .read_write = true, .executable = false }, gdt.Flags{}),
            // 3: user code segment
            @bitCast(@as(u64, 0)),
            // 4: user data segment
            @bitCast(@as(u64, 0)),
            // 5: task state segment (TSS) - describes entry point into kernel stack
            // access_byte 0x89 for system segment: present = 1, dpl = ring 0, S = 0 (system), type = 0x9 (32-bit TSS - available)
            gdt.makeSystemSegment(@intFromPtr(&tss), @sizeOf(gdt.Tss) - 1, 0x89, gdt.Flags{ .size_flag = false, .granularity = false }),
        };
    }

    /// Configures the user-mode code and data descriptors.
    pub fn setUserSegments(task: *Task, code: []u8, data: []u8) void {
        const code_base = @intFromPtr(code.ptr);
        const code_pages = @divExact(code.len, 4 * 1024);

        const data_base = @intFromPtr(data.ptr);
        const data_pages = @divExact(data.len, 4 * 1024);

        task.gdt[3] = gdt.makeSegment(code_base, @truncate(code_pages - 1), gdt.AccessFlags{ .read_write = false, .executable = true, .dpl = 3 }, gdt.Flags{});
        task.gdt[4] = gdt.makeSegment(data_base, @truncate(data_pages - 1), gdt.AccessFlags{ .read_write = true, .executable = false, .dpl = 3 }, gdt.Flags{});
    }

    pub fn getKernelStack(task: *Task) *align(KERNEL_STACK_SIZE) KernelStack {
        _ = task;
        return &kernel_stack;
    }

    /// Loads the GDT and sets the task register for the current CPU.
    pub fn set(task: *Task) void {
        task.gdtr.initAndLoad(&task.gdt);
        gdt.ltr(tss_selector);

        // write *Task into the first word in the kernel stack
        @as(**Task, @ptrCast(task.getKernelStack())).* = task;
    }
};
