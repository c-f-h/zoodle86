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
        if (t.kernel_esp == 0) {
            t.init();
            return t;
        }
    }
    return error.NoTaskSlots;
}

/// Return the next runnable task after `ptask`, or null if none exists.
pub fn getNextActiveTask(ptask: *task.Task) ?*task.Task {
    const cur_idx = ptask - &tasks[0];
    var idx = (cur_idx + 1) % tasks.len;
    while (idx != cur_idx) : (idx = (idx + 1) % tasks.len) {
        if (tasks[idx].kernel_esp != 0) {
            return &tasks[idx];
        }
    }
    return null;
}
