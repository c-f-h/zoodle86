const task = @import("task.zig");
const paging = @import("paging.zig");

const MAX_TASKS = 8;
const TASK_POOL_BASE = 0xE040_0000;

const TaskmanEntry = struct {
    guard_page: [paging.PAGE]u8 align(paging.PAGE) = undefined,
    task: task.Task = .{},
};

comptime {
    if (@offsetOf(TaskmanEntry, "task") != paging.PAGE) @compileError("TaskmanEntry.task must start after the guard page");
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
        paging.unmapPagesAt(@intFromPtr(&entry.guard_page), 1);
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

/// Wakes a parent task that is blocked in waitpid waiting for the given child PID.
/// Writes the exit status as the waitpid return value and transitions the task to active.
/// Returns true if a waiter was found and woken, false otherwise.
pub fn wakeWaiterFor(child_pid: u32, exit_status: u32) bool {
    for (task_entries) |*entry| {
        const ptask = &entry.task;
        if (ptask.state == .waiting and ptask.waiting_for_pid == child_pid) {
            ptask.setSyscallReturn(exit_status);
            ptask.waiting_for_pid = 0;
            ptask.state = .active;
            return true;
        }
    }
    return false;
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
