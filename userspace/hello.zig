const std = @import("std");
const sys = @import("sys.zig");

pub fn main(argv: []const []const u8) !void {
    var count: u32 = 1;
    if (argv.len > 1) {
        count = try std.fmt.parseInt(u32, argv[1], 10);
    }

    const child_pid = if (argv.len > 2)
        try sys.spawn("hello", &.{argv[2]})
    else
        0;

    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{0}", .{sys.getpid()});
    while (count > 0) : (count -= 1) {
        _ = sys.write(sys.STDOUT, msg);
        //sys.yield();
    }

    if (child_pid != 0) {
        const exit_status = sys.waitpid(child_pid);
        var wbuf: [64]u8 = undefined;
        _ = sys.write(sys.STDOUT, try std.fmt.bufPrint(&wbuf, "\nChild {0} exited with status {1}\n", .{ child_pid, exit_status }));
    }
}

comptime {
    _ = sys._start;
}
