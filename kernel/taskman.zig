const task = @import("task.zig");

var tasks: [8]task.Task = undefined;

/// Initialize the task managers.
pub fn init() void {
    for (&tasks) |*t| {
        t.* = .{};
    }
}

/// Create and initialize a new task.
pub fn newTask() *task.Task {
    for (&tasks) |*t| {
        if (t.kernel_esp == 0) {
            t.init();
            return t;
        }
    }
    @panic("No free task slots");
}

pub fn getNextActiveTask(ptask: *task.Task) ?*task.Task {
    const cur_idx = ptask - &tasks[0];
    var idx = cur_idx + 1;
    while (idx != cur_idx) {
        if (idx >= tasks.len) idx = 0;
        if (tasks[idx].kernel_esp != 0) {
            return &tasks[idx];
        }
        idx += 1;
    }
    return null;
}
