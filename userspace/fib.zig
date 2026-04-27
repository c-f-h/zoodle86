const std = @import("std");
const sys = @import("sys.zig");

fn fibValue(n: u32) u32 {
    if (n < 2) return n;
    return fibValue(n - 1) + fibValue(n - 2);
}

/// Print a short CPU-bound Fibonacci sequence.
pub fn main(argv: []const []const u8) !void {
    var count: u32 = 4;
    if (argv.len > 1) {
        count = try std.fmt.parseInt(u32, argv[1], 10);
    }

    var start_n: u32 = 28;
    if (argv.len > 2) {
        start_n = try std.fmt.parseInt(u32, argv[2], 10);
    }

    var line_buf: [96]u8 = undefined;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const n = start_n + index;
        const value = fibValue(n);
        const line = try std.fmt.bufPrint(&line_buf, "pid {d}: fib({d}) = {d}\n", .{ sys.getpid(), n, value });
        _ = sys.write(sys.STDOUT, line);
    }
}

comptime {
    _ = sys._start;
}
