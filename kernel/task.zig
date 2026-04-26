const gdt = @import("gdt.zig");
const interrupt_frame = @import("interrupt_frame.zig");
const paging = @import("paging.zig");
const kernel = @import("kernel.zig");
const filedesc = @import("filedesc.zig");
const std = @import("std");

const KERNEL_STACK_SIZE = 4096;

/// Maximum number of arguments that can be passed to a process via setArgs.
const KernelStack = [KERNEL_STACK_SIZE]u8;

/// Stable 32-bit ABI slice representation used for argv passing.
/// Must match the definition in userspace/sys.zig.
pub const AbiSlice = extern struct {
    ptr: u32,
    len: u32,
};

pub const MAX_ARGV_COUNT = 128;

pub const UserMemError = error{AccessViolation};

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

/// Lifecycle state of a task slot.
pub const TaskState = enum {
    free, // slot is available for reuse
    active, // task is runnable or currently executing
    waiting, // task is blocked in waitpid, kernel_esp is saved for resumption
    zombie, // task has exited but exit status not yet collected by parent
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
    state: TaskState = .free,
    parent_pid: u32 = 0, // PID of spawning task; 0 = created by kernel/shell (auto-reap)
    reap_children: bool = false, // if true, children are auto-reaped instead of becoming zombies
    exit_status: u32 = 0, // exit code written on exit, read by waitpid
    waiting_for_pid: u32 = 0, // PID this task is blocked waiting on (state == .waiting)
    stack_bottom: u32 = 0, // lower bound for stack growth in virtual memory
    stack_top: u32 = 0, // top of stack in virtual memory
    heap_start: u32 = 0,
    heap_brk: u32 = 0, // current program break for heap

    code_mem: paging.VMemRange = .{},
    data_mem: paging.VMemRange = .{},
    stack_mem: paging.VMemRange = .{}, // actual extents of current stack (may grow downwards)

    fd_table: [MAX_FDS]FdSlot = [_]FdSlot{.{}} ** MAX_FDS,

    /// Initializes a fresh task slot and its initial userspace context.
    pub fn init(task: *Task) void {
        task.* = .{};
        @as(**Task, @ptrCast(&task.kernel_stack)).* = task;
        task.pid = next_pid;
        next_pid += 1;
        task.initFdTable();

        const frame_addr = @intFromPtr(&task.kernel_stack) + KERNEL_STACK_SIZE - @sizeOf(interrupt_frame.UserInterruptFrame);
        const frame: *interrupt_frame.UserInterruptFrame = @ptrFromInt(frame_addr);
        frame.* = .{
            .interrupt = .{
                .regs = .{
                    .edi = 0,
                    .esi = 0,
                    .ebp = 0,
                    .esp = 0,
                    .ebx = 0,
                    .edx = 0,
                    .ecx = 0,
                    .eax = 0,
                },
                .es = kernel.user_data_selector,
                .ds = kernel.user_data_selector,
                .vector = 0,
                .error_code = 0,
                .eip = 0,
                .cs = kernel.user_code_selector,
                .eflags = 0x202,
            },
            .user = .{
                .user_esp = 0,
                .user_ss = kernel.user_data_selector,
            },
        };

        task.kernel_esp = frame_addr;
        task.state = .active;
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

    /// Closes files and frees all memory owned by the task.
    /// Does NOT change state or pid; call terminate() or set state manually after.
    pub fn cleanup(t: *Task) void {
        filedesc.closeTaskFiles(t);
        t.initFdTable();
        t.kernel_esp = 0;
        t.code_mem.freePages();
        t.data_mem.freePages();
        t.stack_mem.freePages();
    }

    /// Immediately frees a task slot, releasing all resources. Always auto-reaps.
    /// Use for errdefer paths and kernel-internal cleanup where zombie semantics are not needed.
    pub fn terminate(t: *Task) void {
        t.cleanup();
        t.state = .free;
        t.pid = 0;
    }

    /// Writes a value into the saved EAX position on the kernel stack frame so that
    /// when the task is resumed via iretd, the value is delivered as the syscall return.
    /// Only valid while the task is in the .waiting state with a saved kernel_esp.
    pub fn setSyscallReturn(t: *Task, val: u32) void {
        if (t.state != .waiting or t.kernel_esp == 0)
            @panic("setSyscallReturn called on task that is not waiting");
        const frame: *interrupt_frame.UserInterruptFrame = @ptrFromInt(t.kernel_esp);
        frame.setReturnValue(val);
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
        const frame: *interrupt_frame.UserInterruptFrame = @ptrFromInt(task.kernel_esp);
        frame.user.user_esp = esp;
        frame.interrupt.eip = eip;
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
            \\ jmp return_to_userspace
            :
            : [kernel_esp] "{esp}" (task.kernel_esp),
        );
        unreachable;
    }

    // Checks that the given range lies within the user memory segment.
    fn validateUserDataRange(_: *Task, ptr: u32, len: u32) bool {
        if (ptr < kernel.USER_DATA_START or ptr > kernel.USER_STACK_TOP) return false;
        return len <= kernel.USER_STACK_TOP - ptr;
    }

    // Checks that the given range is mapped in the current page directory with user permissions.
    fn validateUserMappingRange(_: *Task, ptr: u32, len: u32) bool {
        if (len == 0) return true;

        const last_byte = ptr + len - 1;
        const page_dir = paging.getMappedPageDirectory();
        var va = paging.roundDown(ptr, paging.PAGE);
        const end_page = paging.roundDown(last_byte, paging.PAGE);
        while (true) : (va += paging.PAGE) {
            const pde = page_dir[@truncate(va >> 22)];
            if (!pde.present or !pde.user) return false;

            const pte = paging.getPte(va);
            if (!pte.present or !pte.user) return false;

            if (va == end_page) return true;
        }
    }

    fn validateUserAccess(task: *Task, ptr: u32, len: u32) UserMemError!void {
        if (!task.validateUserDataRange(ptr, len) or !task.validateUserMappingRange(ptr, len)) {
            return error.AccessViolation;
        }
    }

    /// Accesses a slice of memory within the task's user memory segment.
    /// Only valid while the task's page directory is mapped.
    pub fn getUserMem(task: *Task, ofs: u32, len: u32) UserMemError![]u8 {
        try task.validateUserAccess(ofs, len);
        const start: [*]u8 = @ptrFromInt(ofs);
        return start[0..len];
    }

    /// Accesses a slice of type T within the task's user memory segment.
    pub fn getUserSlice(task: *Task, comptime T: type, va: u32, count: u32) UserMemError![]T {
        const elem_size: u32 = @intCast(@sizeOf(T));
        const len = std.math.mul(u32, elem_size, count) catch return error.AccessViolation;
        try task.validateUserAccess(va, len);
        const start: [*]T = @ptrFromInt(va);
        return start[0..count];
    }

    /// Returns a pointer to a value of type T within the task's user memory segment.
    pub fn getUserPtr(task: *Task, comptime T: type, va: u32) UserMemError!*T {
        const len: u32 = @intCast(@sizeOf(T));
        try task.validateUserAccess(va, len);
        return @ptrFromInt(va);
    }

    /// Updates the active CPU TSS to use this task's kernel stack.
    fn updateTss(task: *Task, tss: *gdt.Tss) void {
        const stack_top = @intFromPtr(&task.kernel_stack) + @sizeOf(KernelStack);
        tss.setKernelStack(stack_top);
    }
};

comptime {
    if (KERNEL_STACK_SIZE != paging.PAGE) @compileError("Task layout expects a one-page kernel stack");
    if (@offsetOf(Task, "kernel_stack") != 0) @compileError("Task.kernel_stack must remain the first field");
}

/// Saves the kernel stack pointer for the current task so it can be resumed later.
pub fn saveKernelStackPtr(kernel_esp: usize) void {
    getCurrentTask().kernel_esp = kernel_esp;
}
