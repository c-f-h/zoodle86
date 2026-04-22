const std = @import("std");
const sys = @import("sys.zig");

pub fn main(argv: []const []const u8) !void {
    var count: u32 = 1;
    if (argv.len > 1) {
        count = try std.fmt.parseInt(u32, argv[1], 10);
    }

    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Hello, world from process {0}!\n", .{sys.getpid()});
    while (count > 0) : (count -= 1) {
        _ = sys.write(sys.STDOUT, msg);
        sys.yield();
    }
}

comptime {
    _ = sys._start;
}
