const std = @import("std");
const sys = @import("sys.zig");

fn writeAll(fd: u32, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const chunk = sys.write(fd, data[written..]);
        if (chunk == sys.FAIL or chunk == 0) return false;
        written += @intCast(chunk);
    }
    return true;
}

fn copyFd(fd: u32) bool {
    var buf: [128]u8 = undefined;
    while (true) {
        const count = sys.read(fd, &buf);
        if (count == sys.FAIL) return false;
        if (count == 0) return true;
        if (!writeAll(sys.STDOUT, buf[0..@intCast(count)])) return false;
    }
}

fn writeOpenError(path: []const u8) void {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cat: failed to open {s}\n", .{path}) catch "cat: failed to open file\n";
    _ = writeAll(sys.STDERR, msg);
}

/// Copies stdin when no filenames are provided, or prints each named file to stdout.
pub fn main(argv: []const []const u8) noreturn {
    if (argv.len <= 1) {
        sys.exit(if (copyFd(sys.STDIN)) 0 else 1);
    }

    for (argv[1..]) |path| {
        const fd = sys.open(path, .{});
        if (fd == sys.FAIL) {
            writeOpenError(path);
            sys.exit(1);
        }

        if (!copyFd(fd)) {
            _ = sys.close(fd);
            sys.exit(1);
        }

        _ = sys.close(fd);
    }

    sys.exit(0);
}

comptime {
    _ = sys._start;
}
