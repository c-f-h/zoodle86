/// readline_demo: demonstrates interactive line editing in userspace using the
/// readline library backed by ANSI escape sequences and KeyEvent stdin reads.
const sys = @import("sys.zig");
const readline = @import("readline.zig");
const std = @import("std");

pub fn main(_: []const []const u8) !void {
    _ = sys.write(sys.STDOUT, "readline_demo: type lines, 'quit' to exit, Ctrl-D on empty line for EOF.\n\n");

    var rl: readline.Readline = .{};

    while (true) {
        rl.init("$ ");
        const line = rl.readLine() orelse {
            _ = sys.write(sys.STDOUT, "\n");
            break;
        };

        if (std.mem.eql(u8, line, "quit")) {
            readline.showCursor(false);
            break;
        }

        _ = sys.write(sys.STDOUT, "You entered: ");
        _ = sys.write(sys.STDOUT, line);
        _ = sys.write(sys.STDOUT, "\n");
    }
}

comptime {
    _ = sys._start;
}
