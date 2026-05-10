const std = @import("std");
const sys = @import("sys.zig");

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

/// Returns the final path component (everything after the last '/').
fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

// ---------------------------------------------------------------------------
// cat
// ---------------------------------------------------------------------------

fn catCopyFd(fd: u32) bool {
    var buf: [128]u8 = undefined;
    while (true) {
        const count = sys.read(fd, &buf);
        if (count == sys.FAIL) return false;
        if (count == 0) return true;
        if (!sys.writeAll(sys.STDOUT, buf[0..@intCast(count)])) return false;
    }
}

/// Copies stdin when no filenames are provided, or prints each named file to stdout.
fn catMain(argv: []const []const u8) noreturn {
    if (argv.len <= 1) {
        sys.exit(if (catCopyFd(sys.STDIN)) 0 else 1);
    }

    for (argv[1..]) |path| {
        const fd = sys.open(path, .{});
        if (fd == sys.FAIL) {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "cat: failed to open {s}\n", .{path}) catch "cat: failed to open file\n";
            _ = sys.writeAll(sys.STDERR, msg);
            sys.exit(1);
        }

        if (!catCopyFd(fd)) {
            _ = sys.close(fd);
            sys.exit(1);
        }

        _ = sys.close(fd);
    }

    sys.exit(0);
}

// ---------------------------------------------------------------------------
// ls
// ---------------------------------------------------------------------------

fn lsEntryTag(kind: sys.FileKind) []const u8 {
    return if (kind == .Directory) "(DIR)" else ".....";
}

fn lsDisplayName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return if (trimmed.len == 0) "/" else trimmed;
}

fn lsBaseName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return "/";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
        return trimmed[idx + 1 ..];
    }
    return trimmed;
}

fn lsPrintEntry(name: []const u8, kind: sys.FileKind, size: u32) bool {
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, " {s:<16} {s:5} {d:>7}\n", .{
        name,
        lsEntryTag(kind),
        size,
    }) catch return false;
    return sys.writeAll(sys.STDOUT, line);
}

fn lsListDirectory(fd: u32) bool {
    var found_any = false;
    var entry: sys.DirEntry = undefined;
    while (sys.readdir(fd, &entry) catch return false) {
        found_any = true;
        if (!lsPrintEntry(entry.name[0..entry.name_len], entry.kind, entry.size)) return false;
    }
    return if (found_any) true else sys.writeAll(sys.STDOUT, "(empty)\n");
}

fn lsListPath(path: []const u8) bool {
    const fd = sys.open(path, .{});
    if (fd == sys.FAIL) {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ls: failed to open {s}\n", .{lsDisplayName(path)}) catch return false;
        _ = sys.writeAll(sys.STDERR, msg);
        return false;
    }
    defer _ = sys.close(fd);

    var stat: sys.Stat = undefined;
    if (sys.fstat(fd, &stat) == sys.FAIL) {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ls: failed to stat {s}\n", .{lsDisplayName(path)}) catch return false;
        _ = sys.writeAll(sys.STDERR, msg);
        return false;
    }

    if (stat.kind == .Directory) return lsListDirectory(fd);
    return lsPrintEntry(lsBaseName(path), stat.kind, stat.size);
}

/// Lists directory contents using the userspace directory-entry syscall.
fn lsMain(argv: []const []const u8) noreturn {
    var ok = true;
    const default_paths = [_][]const u8{"/"};
    const paths: []const []const u8 = if (argv.len <= 1) default_paths[0..] else argv[1..];

    for (paths, 0..) |path, index| {
        if (paths.len > 1) {
            if (index != 0 and !sys.writeAll(sys.STDOUT, "\n")) ok = false;
            if (!sys.writeAll(sys.STDOUT, lsDisplayName(path)) or !sys.writeAll(sys.STDOUT, ":\n")) ok = false;
        }
        if (!lsListPath(path)) ok = false;
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// ln
// ---------------------------------------------------------------------------

/// Creates a hard link from a new path to an existing regular file.
fn lnMain(argv: []const []const u8) noreturn {
    if (argv.len != 3) {
        _ = sys.writeAll(sys.STDERR, "Usage: ln <existing-path> <new-path>\n");
        sys.exit(1);
    }

    if (sys.link(argv[1], argv[2]) == sys.FAIL) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ln: failed to link {s} -> {s}\n", .{ argv[2], argv[1] }) catch
            "ln: failed to create link\n";
        _ = sys.writeAll(sys.STDERR, msg);
        sys.exit(1);
    }

    sys.exit(0);
}

// ---------------------------------------------------------------------------
// rm
// ---------------------------------------------------------------------------

/// Removes one or more files by unlinking them from the filesystem.
fn rmMain(argv: []const []const u8) noreturn {
    if (argv.len < 2) {
        _ = sys.writeAll(sys.STDERR, "Usage: rm <path> ...\n");
        sys.exit(1);
    }

    var ok = true;
    for (argv[1..]) |path| {
        if (sys.unlink(path) == sys.FAIL) {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "rm: failed to remove {s}\n", .{path}) catch "rm: failed to remove file\n";
            _ = sys.writeAll(sys.STDERR, msg);
            ok = false;
        }
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// stat
// ---------------------------------------------------------------------------

fn statKindStr(kind: sys.FileKind) []const u8 {
    return switch (kind) {
        .Regular => "regular file",
        .Directory => "directory",
        .CharDevice => "character special file",
        .Pipe => "pipe",
        .Unknown => "unknown",
    };
}

fn statAccessStr(flags: u32) []const u8 {
    const r = (flags & sys.STAT_FLAG_READABLE) != 0;
    const w = (flags & sys.STAT_FLAG_WRITABLE) != 0;
    if (r and w) return "rw";
    if (r) return "r-";
    if (w) return "-w";
    return "--";
}

/// Prints stat(2)-style metadata for one or more paths.
fn statMain(argv: []const []const u8) noreturn {
    if (argv.len < 2) {
        _ = sys.writeAll(sys.STDERR, "Usage: stat <path> ...\n");
        sys.exit(1);
    }

    var ok = true;
    for (argv[1..]) |path| {
        var st: sys.Stat = undefined;
        if (sys.stat(path, &st) == sys.FAIL) {
            var buf: [224]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "stat: cannot stat '{s}': No such file or directory\n", .{path}) catch
                "stat: cannot stat file\n";
            _ = sys.writeAll(sys.STDERR, msg);
            ok = false;
            continue;
        }

        var buf: [256]u8 = undefined;

        const line1 = std.fmt.bufPrint(&buf, "  File: {s}\n", .{path}) catch continue;
        if (!sys.writeAll(sys.STDOUT, line1)) {
            ok = false;
            continue;
        }

        const line2 = std.fmt.bufPrint(&buf, "  Size: {d:<15} Blocks: {d:<10} IO Block: {d:<6} {s}\n", .{
            st.size, st.blocks, st.blksize, statKindStr(st.kind),
        }) catch continue;
        if (!sys.writeAll(sys.STDOUT, line2)) {
            ok = false;
            continue;
        }

        const line3 = std.fmt.bufPrint(&buf, " Inode: {d:<15} Links: {d:<11} Access: {s}\n", .{
            st.inode, st.nlink, statAccessStr(st.flags),
        }) catch continue;
        if (!sys.writeAll(sys.STDOUT, line3)) {
            ok = false;
            continue;
        }
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// busybox dispatch
// ---------------------------------------------------------------------------

/// Multi-call binary: dispatches to cat, ls, ln, rm, or stat based on argv[0] basename.
pub fn main(argv: []const []const u8) noreturn {
    const name = if (argv.len > 0) baseName(argv[0]) else "";

    if (std.mem.eql(u8, name, "cat")) catMain(argv);
    if (std.mem.eql(u8, name, "ls")) lsMain(argv);
    if (std.mem.eql(u8, name, "ln")) lnMain(argv);
    if (std.mem.eql(u8, name, "rm")) rmMain(argv);
    if (std.mem.eql(u8, name, "stat")) statMain(argv);

    _ = sys.writeAll(
        sys.STDERR,
        "busybox: available tools: cat, ls, ln, rm, stat\n" ++
            "Invoke via a named link.\n",
    );
    sys.exit(1);
}

comptime {
    _ = sys._start;
}
