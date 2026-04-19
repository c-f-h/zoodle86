const std = @import("std");
const sys = @import("sys.zig");

fn main() !void {
    var buf: [80]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Hello, world from process {0}!\n", .{sys.getpid()});
    var count: u32 = 10;
    while (count > 0) : (count -= 1) {
        _ = sys.write(sys.STDOUT, msg);
        sys.yield();
    }
}

pub export fn _start() void {
    main() catch {
        _ = sys.write(sys.STDOUT, "Error occurred.\n");
        sys.exit(1);
    };
    sys.exit(0);
}
