const std = @import("std");
const sys = @import("sys.zig");

fn fibValue(n: u32) u32 {
    if (n < 2) return n;
    return fibValue(n - 1) + fibValue(n - 2);
}

/// Print a short CPU-bound Fibonacci sequence and optionally spawn a child to do the same.
pub fn main(argv: []const []const u8) !void {
    var count: u32 = 4;
    if (argv.len > 1) {
        count = try std.fmt.parseInt(u32, argv[1], 10);
    }

    var child_count: u32 = 0;
    if (argv.len > 2) {
        child_count = try std.fmt.parseInt(u32, argv[2], 10);
    }

    var start_n: u32 = 28;
    if (argv.len > 3) {
        start_n = try std.fmt.parseInt(u32, argv[3], 10);
    }

    const child_pid = if (child_count != 0) blk: {
        var child_count_buf: [16]u8 = undefined;
        var child_start_buf: [16]u8 = undefined;
        const child_count_arg = try std.fmt.bufPrint(&child_count_buf, "{d}", .{child_count});
        const child_start_arg = try std.fmt.bufPrint(&child_start_buf, "{d}", .{start_n});
        break :blk try sys.spawn("fib", &.{ child_count_arg, "0", child_start_arg });
    } else 0;

    var line_buf: [96]u8 = undefined;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const n = start_n + index;
        const value = fibValue(n);
        const line = try std.fmt.bufPrint(&line_buf, "pid {d}: fib({d}) = {d}\n", .{ sys.getpid(), n, value });
        _ = sys.write(sys.STDOUT, line);
    }

    if (child_pid != 0) {
        const exit_status = sys.waitpid(child_pid);
        var wait_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&wait_buf, "Child {d} exited with status {d}\n", .{ child_pid, exit_status });
        _ = sys.write(sys.STDOUT, line);
    }
}

comptime {
    _ = sys._start;
}
