const kernel_allocator = @import("allocator.zig");
const task = @import("task.zig");
const paging = @import("paging.zig");

const MAX_TASKS = 8;
const TASK_POOL_BASE = 0xE800_0000;

const TaskmanEntry = struct {
    /// Guard area placed immediately below the kernel stack.
    guard_pages: [task.KERNEL_STACK_SIZE]u8 align(task.KERNEL_STACK_SIZE) = undefined,
    task: task.Task = .{},
};

comptime {
    if (@offsetOf(TaskmanEntry, "task") != task.KERNEL_STACK_SIZE) @compileError("TaskmanEntry.task must start after the guard area");
    if (@sizeOf(TaskmanEntry) % paging.PAGE != 0) @compileError("TaskmanEntry size must be page-aligned");
}

var task_entries: []TaskmanEntry = &[_]TaskmanEntry{};

fn findTaskIndex(ptask: *task.Task) ?usize {
    for (task_entries, 0..) |*entry, idx| {
        if (&entry.task == ptask) {
            return idx;
        }
    }
    return null;
}

/// Initialize the task managers.
pub fn init() void {
    if (task_entries.len != 0) {
        @panic("taskman.init called twice");
    }

    const total_pages: u32 = @intCast((@sizeOf(TaskmanEntry) / paging.PAGE) * MAX_TASKS);
    const pool_mem = paging.allocateMemoryAt(TASK_POOL_BASE, total_pages, false, true);
    @memset(pool_mem, 0x00);

    const pool_ptr: [*]TaskmanEntry = @ptrCast(@alignCast(pool_mem.ptr));
    task_entries = pool_ptr[0..MAX_TASKS];

    for (task_entries) |*entry| {
        entry.task = .{};
        paging.unmapPagesAt(@intFromPtr(&entry.guard_pages), entry.guard_pages.len / paging.PAGE);
    }
}

/// Creates and initializes a new task, or reports that the fixed task pool is full.
pub fn newTask() error{NoTaskSlots}!*task.Task {
    for (task_entries) |*entry| {
        const ptask = &entry.task;
        if (ptask.state == .free) {
            ptask.init();
            return ptask;
        }
    }
    return error.NoTaskSlots;
}

/// Return the next runnable task after `ptask`, or null if none exists.
/// Tasks in the .waiting or .zombie states are not considered runnable.
pub fn getNextActiveTask(ptask: *task.Task) ?*task.Task {
    const cur_idx = findTaskIndex(ptask) orelse @panic("Task not managed by taskman");
    var idx = (cur_idx + 1) % task_entries.len;
    while (idx != cur_idx) : (idx = (idx + 1) % task_entries.len) {
        if (task_entries[idx].task.state == .active) {
            return &task_entries[idx].task;
        }
    }
    return null;
}

/// Returns a pointer to the task with the given PID, searching all non-free slots.
pub fn findTask(pid: u32) ?*task.Task {
    for (task_entries) |*entry| {
        const ptask = &entry.task;
        if (ptask.state != .free and ptask.pid == pid) {
            return ptask;
        }
    }
    return null;
}

/// Calls `callback` once for every non-free task slot in the pool.
/// The callback receives a const pointer to the task; it must not modify the task.
pub fn forEachTask(comptime T: type, ctx: T, callback: fn (T, *const task.Task) void) void {
    for (task_entries) |*entry| {
        if (entry.task.state != .free) {
            callback(ctx, &entry.task);
        }
    }
}

/// Reparents all children of the exiting task (identified by pid) to parent_pid=0.
/// Zombie children are freed immediately since no one will collect their exit status.
pub fn orphanChildrenOf(pid: u32) void {
    for (task_entries) |*entry| {
        const ptask = &entry.task;
        if (ptask.parent_pid == pid) {
            ptask.parent_pid = 0;
            if (ptask.state == .zombie) {
                ptask.state = .free;
                ptask.pid = 0;
            }
        }
    }
}
