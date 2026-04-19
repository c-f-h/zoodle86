const kernel = @import("kernel.zig");
const console = @import("console.zig");
const task = @import("task.zig");

const Syscall = enum(u32) {
    Write = 1,
    GetPid = 39,
    Yield = 24,
    Exit = 60,
    _,
};

fn sys_write(fd: u32, ofs: u32, count: u32) u32 {
    if (fd != 1)
        return 0;

    const data = task.getCurrentTask().getUserMem(ofs, count);
    console.puts(data);
    return count;
}

/// Dispatches the int 0x80 syscall ABI invoked by user-mode executables.
pub export fn syscall_dispatch(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) callconv(.c) u32 {
    return switch (nr) {
        .Exit => {
            task.getCurrentTask().terminate();
            kernel.reschedule();
        },
        .GetPid => task.getCurrentTask().pid,
        .Write => sys_write(arg1, arg2, arg3),
        .Yield => kernel.reschedule(),
        else => 0xffff_ffff,
    };
}
