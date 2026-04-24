const task = @import("task.zig");

var tasks: [8]task.Task = undefined;

/// Initialize the task managers.
pub fn init() void {
    for (&tasks) |*t| {
        t.* = .{};
    }
}

/// Creates and initializes a new task, or reports that the fixed task pool is full.
pub fn newTask() error{NoTaskSlots}!*task.Task {
    for (&tasks) |*t| {
        if (t.state == .free) {
            t.init();
            return t;
        }
    }
    return error.NoTaskSlots;
}

/// Return the next runnable task after `ptask`, or null if none exists.
/// Tasks in the .waiting or .zombie states are not considered runnable.
pub fn getNextActiveTask(ptask: *task.Task) ?*task.Task {
    const cur_idx = ptask - &tasks[0];
    var idx = (cur_idx + 1) % tasks.len;
    while (idx != cur_idx) : (idx = (idx + 1) % tasks.len) {
        if (tasks[idx].state == .active) {
            return &tasks[idx];
        }
    }
    return null;
}

/// Returns a pointer to the task with the given PID, searching all non-free slots.
pub fn findTask(pid: u32) ?*task.Task {
    for (&tasks) |*t| {
        if (t.state != .free and t.pid == pid) {
            return t;
        }
    }
    return null;
}

/// Wakes a parent task that is blocked in waitpid waiting for the given child PID.
/// Writes the exit status as the waitpid return value and transitions the task to active.
/// Returns true if a waiter was found and woken, false otherwise.
pub fn wakeWaiterFor(child_pid: u32, exit_status: u32) bool {
    for (&tasks) |*t| {
        if (t.state == .waiting and t.waiting_for_pid == child_pid) {
            t.setSyscallReturn(exit_status);
            t.waiting_for_pid = 0;
            t.state = .active;
            return true;
        }
    }
    return false;
}

/// Reparents all children of the exiting task (identified by pid) to parent_pid=0.
/// Zombie children are freed immediately since no one will collect their exit status.
pub fn orphanChildrenOf(pid: u32) void {
    for (&tasks) |*t| {
        if (t.parent_pid == pid) {
            t.parent_pid = 0;
            if (t.state == .zombie) {
                t.state = .free;
                t.pid = 0;
            }
        }
    }
}
