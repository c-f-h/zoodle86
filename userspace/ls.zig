const std = @import("std");
const sys = @import("sys.zig");

fn entryTag(kind: sys.FileKind) []const u8 {
    return if (kind == .Directory) "(DIR)" else ".....";
}

fn displayNameForPath(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return "/";
    return trimmed;
}

fn baseNameForPath(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return "/";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
        return trimmed[idx + 1 ..];
    }
    return trimmed;
}

fn writeLine(msg: []const u8) bool {
    sys.writeAll(sys.STDOUT, msg) catch return false;
    return true;
}

fn writeError(prefix: []const u8, desc: []const u8) void {
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ prefix, desc }) catch return;
    _ = sys.writeAll(sys.STDERR, msg);
}

fn printEntry(name: []const u8, kind: sys.FileKind, size: u32) bool {
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, " {s:<16} {s:5} {d:>7}\n", .{
        name,
        entryTag(kind),
        size,
    }) catch return false;
    return writeLine(line);
}

fn listDirectory(fd: u32) bool {
    var found_any = false;
    var entry: sys.DirEntry = undefined;
    while (sys.readdir(fd, &entry) catch return false) {
        found_any = true;
        if (!printEntry(entry.name[0..entry.name_len], entry.kind, entry.size)) return false;
    }
    return if (found_any) true else writeLine("(empty)\n");
}

fn listPath(path: []const u8) bool {
    const fd = sys.open(path, .{}) catch {
        writeError("ls: failed to open ", displayNameForPath(path));
        return false;
    };
    defer sys.close(fd) catch {};

    var stat: sys.Stat = undefined;
    sys.fstat(fd, &stat) catch {
        writeError("ls: failed to stat ", displayNameForPath(path));
        return false;
    };

    if (stat.kind == .Directory) {
        return listDirectory(fd);
    }

    return printEntry(baseNameForPath(path), stat.kind, stat.size);
}

/// Lists directory contents using the userspace directory-entry syscall.
pub fn main(argv: []const []const u8) noreturn {
    var ok = true;
    const default_paths = [_][]const u8{"/"};
    const paths: []const []const u8 = if (argv.len <= 1) default_paths[0..] else argv[1..];

    for (paths, 0..) |path, index| {
        if (paths.len > 1) {
            if (index != 0 and !writeLine("\n")) ok = false;
            if (!writeLine(displayNameForPath(path)) or !writeLine(":\n")) ok = false;
        }

        if (!listPath(path)) ok = false;
    }

    sys.exit(if (ok) 0 else 1);
}

comptime {
    _ = sys._start;
}
