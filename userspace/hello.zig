const std = @import("std");
const sys = @import("sys.zig");

pub fn main() !void {
    var buf: [80]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Hello, world from process {0}!\n", .{sys.getpid()});
    var count: u32 = 10;
    while (count > 0) : (count -= 1) {
        _ = sys.write(sys.STDOUT, msg);
        sys.yield();
    }
}

comptime {
    _ = sys._start;
}
