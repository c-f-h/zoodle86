const gdt = @import("gdt.zig");
const paging = @import("paging.zig");
const kernel = @import("kernel.zig");
const filedesc = @import("filedesc.zig");

const KERNEL_STACK_SIZE = 4096;

/// Stable 32-bit ABI slice representation used for initial-stack argv passing.
/// Must match the definition in userspace/sys.zig.
pub const AbiSlice = extern struct {
    ptr: u32,
    len: u32,
};

/// Maximum number of arguments that can be passed to a process via setArgs.
pub const MAX_ARGV_COUNT = 128;
const KernelStack = [KERNEL_STACK_SIZE]u8;

pub const MAX_FDS = 16;

pub const FdKind = enum(u8) {
    empty,
    stdin,
    stdout,
    stderr,
    file,
};

pub const FdSlot = struct {
    kind: FdKind = .empty,
    file_index: u8 = 0,
};

/// Given a pointer which points to within a kernel stack, finds the pointer to the associated *Task.
pub fn getPointerToTaskPtr(sp: usize) **Task {
    const kss: usize = @sizeOf(KernelStack);
    comptime {
        if ((kss & (kss - 1)) != 0) @compileError("Kernel stack size must be power of 2");
    }
    const stack_base = sp & (~(kss - 1));
    return @as(**Task, @ptrFromInt(stack_base));
}

/// Returns the task associated with the current kernel stack.
pub inline fn getCurrentTask() *Task {
    const sp = kernel.getRegister("esp".*);
    return getPointerToTaskPtr(sp).*;
}

var next_pid: u32 = 1;

pub const Task = struct {
    kernel_stack: KernelStack align(4096) = undefined,
    page_dir: paging.PageDirectory align(4096) = undefined,
    page_dir_phys_addr: u32 = undefined,
    pid: u32 = undefined,
    kernel_esp: usize = 0,
    stack_bottom: u32 = undefined, // lower bound for stack growth in virtual memory
    stack_top: u32 = undefined, // top of stack in virtual memory
    heap_top: u32 = undefined,

    code_mem: paging.VMemRange = .{},
    data_mem: paging.VMemRange = .{},
    stack_mem: paging.VMemRange = .{}, // actual extents of current stack (may grow downwards)

    fd_table: [MAX_FDS]FdSlot = [_]FdSlot{.{}} ** MAX_FDS,

    /// Initializes a fresh task slot and its initial userspace context.
    pub fn init(task: *Task) void {
        @as(**Task, @ptrCast(&task.kernel_stack)).* = task;
        task.pid = next_pid;
        next_pid += 1;
        task.initFdTable();

        const stack_frame = @as([*]u32, @ptrCast(&task.kernel_stack)) + KERNEL_STACK_SIZE / 4 - 5;
        stack_frame[4] = kernel.user_data_selector;
        stack_frame[3] = 0;
        stack_frame[2] = 0x202;
        stack_frame[1] = kernel.user_code_selector;
        stack_frame[0] = 0;

        const regs = (stack_frame - 10)[0..10];
        @memset(regs, 0);
        regs[8] = kernel.user_data_selector;
        regs[9] = kernel.user_data_selector;

        task.kernel_esp = @intFromPtr(regs);
        task.initPaging();
    }

    fn initPaging(task: *Task) void {
        // Clone the currently active page directory.
        // NB: This should be the kernel-only page directory to avoid cross-task contamination.
        @memcpy(&task.page_dir, paging.getMappedPageDirectory());
        task.page_dir_phys_addr = paging.virtualToPhysical(&task.page_dir);
        // Restore the recursive mapping to the new page directory
        task.page_dir[1023] = paging.PDE{
            .writable = true,
            .user = false,
            .page_table_addr = @truncate(task.page_dir_phys_addr >> 12),
        };
    }

    fn initFdTable(task: *Task) void {
        for (&task.fd_table) |*slot| {
            slot.* = .{};
        }
        task.fd_table[0] = .{ .kind = .stdin };
        task.fd_table[1] = .{ .kind = .stdout };
        task.fd_table[2] = .{ .kind = .stderr };
    }

    /// Makes this task's page directory active on the current CPU.
    pub fn loadPageDir(task: *Task) void {
        paging.loadPageDir(task.page_dir_phys_addr);
    }

    /// Terminates a task and releases any resources owned by it.
    pub fn terminate(task: *Task) void {
        filedesc.closeTaskFiles(task);
        task.initFdTable();
        task.pid = 0;
        task.kernel_esp = 0;
        task.code_mem.freePages();
        task.data_mem.freePages();
        task.stack_mem.freePages();
    }

    /// Finds the first free userspace-visible file descriptor slot.
    pub fn findFreeFd(task: *Task) ?u32 {
        var fd: u32 = 3;
        while (fd < task.fd_table.len) : (fd += 1) {
            if (task.fd_table[fd].kind == .empty) {
                return fd;
            }
        }
        return null;
    }

    /// Binds a task-local file descriptor to a kernel open-file table slot.
    pub fn setFileFd(task: *Task, fd: u32, file_index: usize) void {
        task.fd_table[fd] = .{
            .kind = .file,
            .file_index = @truncate(file_index),
        };
    }

    /// Returns the descriptor slot for a task-local fd, or null if it is out of range.
    pub fn getFdSlot(task: *Task, fd: u32) ?*FdSlot {
        if (fd >= task.fd_table.len) return null;
        return &task.fd_table[fd];
    }

    /// Clears a task-local file descriptor slot.
    pub fn clearFd(task: *Task, fd: u32) void {
        if (fd >= task.fd_table.len) return;
        task.fd_table[fd] = .{};
    }

    /// Sets the initial instruction and stack pointers for entry into user space.
    pub fn setEntryPoint(task: *Task, eip: u32, esp: u32) void {
        const stack_frame = @as([*]u32, @ptrCast(&task.kernel_stack)) + KERNEL_STACK_SIZE / 4 - 5;
        stack_frame[3] = esp;
        stack_frame[0] = eip;
    }

    /// Writes argv onto the top mapped stack page and returns the adjusted initial
    /// ESP (pointing to an AbiSlice that describes the full argv array).
    /// Must be called after the task's top stack page has been mapped.
    /// Call the returned ESP value with setEntryPoint to complete task setup.
    pub fn setArgs(task: *Task, args: []const []const u8) error{ArgsTooLarge}!u32 {
        if (args.len > MAX_ARGV_COUNT) return error.ArgsTooLarge;

        // Compute total bytes needed: string data (4-byte-rounded) + slice array + outer AbiSlice.
        var string_bytes: u32 = 0;
        for (args) |arg| string_bytes += @intCast(arg.len);
        const strings_rounded = (string_bytes + 3) & ~@as(u32, 3);
        const needed: u32 = strings_rounded +
            @as(u32, @intCast(args.len)) * @sizeOf(AbiSlice) +
            @sizeOf(AbiSlice);
        if (needed > paging.PAGE - 16) return error.ArgsTooLarge;

        // Layout on the top stack page (built top-down):
        //   [page_top - strings_rounded .. page_top)   : packed string bytes
        //   [array_base .. array_base + argc*8)        : per-arg AbiSlice records
        //   [sp .. sp+8)                               : outer AbiSlice (argv descriptor)  <- initial ESP
        var sp: u32 = task.stack_top;

        // Write string bytes and record their addresses.
        sp -= strings_rounded;
        var write_pos: u32 = sp;
        var string_ptrs: [MAX_ARGV_COUNT]u32 = undefined;
        for (args, 0..) |arg, i| {
            const dest: [*]u8 = @ptrFromInt(write_pos);
            @memcpy(dest[0..arg.len], arg);
            string_ptrs[i] = write_pos;
            write_pos += @intCast(arg.len);
        }

        // Write per-arg AbiSlice array.
        sp -= @as(u32, @intCast(args.len)) * @sizeOf(AbiSlice);
        const array_base = sp;
        if (args.len > 0) {
            const slice_array: [*]AbiSlice = @ptrFromInt(array_base);
            for (args, 0..) |arg, i| {
                slice_array[i] = .{ .ptr = string_ptrs[i], .len = @intCast(arg.len) };
            }
        }

        // Write the outer AbiSlice (the argv descriptor).
        sp -= @sizeOf(AbiSlice);
        const argv_desc: *AbiSlice = @ptrFromInt(sp);
        argv_desc.* = .{ .ptr = array_base, .len = @intCast(args.len) };

        return sp;
    }

    /// Switches execution to this task and resumes userspace from its saved kernel stack.
    pub inline fn switchTo(task: *Task, tss: *gdt.Tss) noreturn {
        task.updateTss(tss);
        paging.loadPageDir(task.page_dir_phys_addr);
        asm volatile (
            \\ jmp task_switch
            :
            : [kernel_esp] "{eax}" (task.kernel_esp),
        );
        unreachable;
    }

    /// Accesses a slice of memory within the task's user memory segment.
    pub fn getUserMem(task: *Task, ofs: u32, len: u32) []u8 {
        _ = task;
        const start: [*]u8 = @ptrFromInt(ofs);
        return start[0..len];
    }

    /// Updates the active CPU TSS to use this task's kernel stack.
    fn updateTss(task: *Task, tss: *gdt.Tss) void {
        const stack_top = @intFromPtr(&task.kernel_stack) + @sizeOf(KernelStack);
        tss.setKernelStack(stack_top);
    }
};

/// Saves the kernel stack pointer for the current task so it can be resumed later.
pub export fn save_kernel_stack_ptr(kernel_esp: usize) callconv(.c) void {
    getCurrentTask().kernel_esp = kernel_esp;
}
