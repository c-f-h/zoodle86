const std = @import("std");
const sys = @import("sys.zig");

fn writeUsage() void {
    _ = sys.writeAll(sys.STDERR, "Usage: ln <existing-path> <new-path>\n");
}

fn writeLinkError(old_path: []const u8, new_path: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ln: failed to link {s} -> {s}\n", .{ new_path, old_path }) catch
        "ln: failed to create link\n";
    _ = sys.writeAll(sys.STDERR, msg);
}

/// Creates a hard link from a new path to an existing regular file.
pub fn main(argv: []const []const u8) noreturn {
    if (argv.len != 3) {
        writeUsage();
        sys.exit(1);
    }

    sys.link(argv[1], argv[2]) catch {
        writeLinkError(argv[1], argv[2]);
        sys.exit(1);
    };

    sys.exit(0);
}

comptime {
    _ = sys._start;
}
