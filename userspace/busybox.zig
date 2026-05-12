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

fn err_toolFailedTo(tool: []const u8, action: []const u8, path: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: failed to {s} {s}\n", .{ tool, action, path }) catch
        "failure\n";
    sys.writeAll(sys.STDERR, msg) catch {};
}

// ---------------------------------------------------------------------------
// cat
// ---------------------------------------------------------------------------

fn catCopyFd(fd: u32) bool {
    var buf: [128]u8 = undefined;
    while (true) {
        const count = sys.read(fd, &buf) catch return false;
        if (count == 0) return true;
        sys.writeAll(sys.STDOUT, buf[0..@intCast(count)]) catch return false;
    }
}

fn catWriteIsDirectoryError(path: []const u8) void {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cat: {s}: Is a directory\n", .{path}) catch "cat: is a directory\n";
    sys.writeAll(sys.STDERR, msg) catch {};
}

/// Copies stdin when no filenames are provided, or prints each named file to stdout.
fn catMain(argv: []const []const u8) noreturn {
    if (argv.len <= 1) {
        if (!catCopyFd(sys.STDIN)) {
            err_toolFailedTo("cat", "read from", "stdin");
            sys.exit(1);
        }
        sys.exit(0);
    }

    for (argv[1..]) |path| {
        const fd = sys.open(path, .{}) catch |err| {
            if (err == error.EISDIR) {
                catWriteIsDirectoryError(path);
            } else {
                err_toolFailedTo("cat", "open", path);
            }
            sys.exit(1);
        };

        if (!catCopyFd(fd)) {
            var st: sys.Stat = undefined;
            if (sys.fstat(fd, &st)) |_| {
                if (st.kind == .Directory) {
                    catWriteIsDirectoryError(path);
                } else {
                    err_toolFailedTo("cat", "read", path);
                }
            } else |_| {
                err_toolFailedTo("cat", "read", path);
            }
            sys.close(fd) catch {};
            sys.exit(1);
        }

        sys.close(fd) catch {};
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
    sys.writeAll(sys.STDOUT, line) catch return false;
    return true;
}

fn lsListDirectory(fd: u32) bool {
    var found_any = false;
    var entry: sys.DirEntry = undefined;
    while (sys.readdir(fd, &entry) catch return false) {
        found_any = true;
        if (!lsPrintEntry(entry.name[0..entry.name_len], entry.kind, entry.size)) return false;
    }
    if (found_any) return true;
    sys.writeAll(sys.STDOUT, "(empty)\n") catch return false;
    return true;
}

fn lsListPath(path: []const u8) bool {
    const fd = sys.open(path, .{}) catch {
        err_toolFailedTo("ls", "open", path);
        return false;
    };
    defer sys.close(fd) catch {};

    var stat: sys.Stat = undefined;
    sys.fstat(fd, &stat) catch {
        err_toolFailedTo("ls", "stat", path);
        return false;
    };

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
            if (index != 0) sys.writeAll(sys.STDOUT, "\n") catch {
                ok = false;
            };
            sys.writeAll(sys.STDOUT, lsDisplayName(path)) catch {
                ok = false;
            };
            sys.writeAll(sys.STDOUT, ":\n") catch {
                ok = false;
            };
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
        sys.writeAll(sys.STDERR, "Usage: ln <existing-path> <new-path>\n") catch {};
        sys.exit(1);
    }

    sys.link(argv[1], argv[2]) catch {
        err_toolFailedTo("ln", "link", argv[2]);
        sys.exit(1);
    };

    sys.exit(0);
}

// ---------------------------------------------------------------------------
// rm
// ---------------------------------------------------------------------------

/// Removes one or more files by unlinking them from the filesystem.
fn rmMain(argv: []const []const u8) noreturn {
    if (argv.len < 2) {
        sys.writeAll(sys.STDERR, "Usage: rm <path> ...\n") catch {};
        sys.exit(1);
    }

    var ok = true;
    for (argv[1..]) |path| {
        sys.unlink(path) catch {
            err_toolFailedTo("rm", "remove", path);
            ok = false;
        };
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// stat
// ---------------------------------------------------------------------------

fn statKindStr(kind: sys.FileKind) []const u8 {
    return switch (kind) {
        .Unknown => "unknown",
        .Regular => "regular file",
        .Directory => "directory",
        .CharDevice => "character special",
        .BlockDevice => "block special",
        .Pipe => "pipe",
        .Symlink => "symbolic link",
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
        sys.writeAll(sys.STDERR, "Usage: stat <path> ...\n") catch {};
        sys.exit(1);
    }

    var ok = true;
    for (argv[1..]) |path| {
        var st: sys.Stat = undefined;
        sys.stat(path, &st) catch {
            err_toolFailedTo("stat", "stat", path);
            ok = false;
            continue;
        };

        var buf: [256]u8 = undefined;

        const line1 = std.fmt.bufPrint(&buf, "  File: {s}\n", .{path}) catch continue;
        sys.writeAll(sys.STDOUT, line1) catch {
            ok = false;
            continue;
        };

        const line2 = std.fmt.bufPrint(&buf, "  Size: {d:<15} Blocks: {d:<10} IO Block: {d:<6} {s}\n", .{
            st.size, st.blocks, st.blksize, statKindStr(st.kind),
        }) catch continue;
        sys.writeAll(sys.STDOUT, line2) catch {
            ok = false;
            continue;
        };

        var dev_buf: [32]u8 = undefined;
        const dev_str = if (st.device.isEmpty())
            ""
        else
            std.fmt.bufPrint(&dev_buf, "Device: {x:02},{x:02}", .{ st.on_device.major, st.on_device.minor }) catch "unknown device";

        const line3 = std.fmt.bufPrint(&buf, "  On Dev: {x:02},{x:02}   Inode: {d:<10} Links: {d:<4} {s}\n", .{
            @intFromEnum(st.on_device.major), st.on_device.minor, st.inode, st.nlink, dev_str,
        }) catch continue;
        sys.writeAll(sys.STDOUT, line3) catch {
            ok = false;
            continue;
        };

        const line4 = std.fmt.bufPrint(&buf, "  Access: {s}\n", .{statAccessStr(st.flags)}) catch continue;
        sys.writeAll(sys.STDOUT, line4) catch {
            ok = false;
            continue;
        };
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// mv
// ---------------------------------------------------------------------------

/// Moves (renames) src to dst, placing src inside dst when dst is a directory.
fn mvMain(argv: []const []const u8) noreturn {
    if (argv.len != 3) {
        sys.writeAll(sys.STDERR, "Usage: mv <src> <dst>\n") catch {};
        sys.exit(1);
    }

    const src = argv[1];
    var dst_buf: [256]u8 = undefined;
    var dst: []const u8 = argv[2];

    // If dst is a directory, append the basename of src to form the full destination path.
    var dst_stat: sys.Stat = undefined;
    var dst_has_stat = true;
    sys.stat(dst, &dst_stat) catch {
        dst_has_stat = false;
    };
    if (dst_has_stat and dst_stat.kind == .Directory) {
        dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
            std.mem.trimEnd(u8, dst, "/"),
            baseName(src),
        }) catch {
            sys.writeAll(sys.STDERR, "mv: path too long\n") catch {};
            sys.exit(1);
        };
    }

    sys.rename(src, dst) catch {
        err_toolFailedTo("mv", "move", src);
        sys.exit(1);
    };

    sys.exit(0);
}

// ---------------------------------------------------------------------------
// cp
// ---------------------------------------------------------------------------

/// Copies src to dst, placing the copy inside dst when dst is a directory.
fn cpMain(argv: []const []const u8) noreturn {
    if (argv.len != 3) {
        sys.writeAll(sys.STDERR, "Usage: cp <src> <dst>\n") catch {};
        sys.exit(1);
    }

    const src = argv[1];
    var dst_buf: [256]u8 = undefined;
    var dst: []const u8 = argv[2];

    // If dst is a directory, append the basename of src to form the full destination path.
    var dst_stat: sys.Stat = undefined;
    var dst_has_stat = true;
    sys.stat(dst, &dst_stat) catch {
        dst_has_stat = false;
    };
    if (dst_has_stat and dst_stat.kind == .Directory) {
        dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
            std.mem.trimEnd(u8, dst, "/"),
            baseName(src),
        }) catch {
            sys.writeAll(sys.STDERR, "cp: path too long\n") catch {};
            sys.exit(1);
        };
    }

    const src_fd = sys.open(src, .{}) catch {
        err_toolFailedTo("cp", "open", src);
        sys.exit(1);
    };
    defer sys.close(src_fd) catch {};

    const dst_fd = sys.open(dst, .{ .open_mode = .WriteOnly, .create = true, .truncate = true }) catch {
        err_toolFailedTo("cp", "create", dst);
        sys.exit(1);
    };
    defer sys.close(dst_fd) catch {};

    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(src_fd, &buf) catch {
            sys.writeAll(sys.STDERR, "cp: read error\n") catch {};
            sys.exit(1);
        };
        if (n == 0) break;
        sys.writeAll(dst_fd, buf[0..@intCast(n)]) catch {
            sys.writeAll(sys.STDERR, "cp: write error\n") catch {};
            sys.exit(1);
        };
    }

    sys.exit(0);
}

// ---------------------------------------------------------------------------
// mkdir
// ---------------------------------------------------------------------------

/// Creates one or more directories.
fn mkdirMain(argv: []const []const u8) noreturn {
    if (argv.len < 2) {
        sys.writeAll(sys.STDERR, "Usage: mkdir <path> ...\n") catch {};
        sys.exit(1);
    }

    var ok = true;
    for (argv[1..]) |path| {
        sys.mkdir(path) catch {
            err_toolFailedTo("mkdir", "create directory", path);
            ok = false;
        };
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// rmdir
// ---------------------------------------------------------------------------

/// Removes one or more empty directories.
fn rmdirMain(argv: []const []const u8) noreturn {
    if (argv.len < 2) {
        sys.writeAll(sys.STDERR, "Usage: rmdir <path> ...\n") catch {};
        sys.exit(1);
    }

    var ok = true;
    for (argv[1..]) |path| {
        sys.rmdir(path) catch {
            err_toolFailedTo("rmdir", "remove directory", path);
            ok = false;
        };
    }

    sys.exit(if (ok) 0 else 1);
}

// ---------------------------------------------------------------------------
// echo
// ---------------------------------------------------------------------------

/// Prints arguments separated by spaces, followed by a newline.
fn echoMain(argv: []const []const u8) noreturn {
    for (argv[1..], 0..) |arg, i| {
        if (i > 0) sys.writeAll(sys.STDOUT, " ") catch sys.exit(1);
        sys.writeAll(sys.STDOUT, arg) catch sys.exit(1);
    }
    sys.writeAll(sys.STDOUT, "\n") catch sys.exit(1);
    sys.exit(0);
}

// ---------------------------------------------------------------------------
// busybox dispatch
// ---------------------------------------------------------------------------

/// Multi-call binary: dispatches to cat, cp, echo, ln, ls, mkdir, mv, rm, rmdir, or stat based on argv[0] basename.
pub fn main(argv: []const []const u8) noreturn {
    const name = if (argv.len > 0) baseName(argv[0]) else "";

    if (std.mem.eql(u8, name, "cat")) catMain(argv);
    if (std.mem.eql(u8, name, "cp")) cpMain(argv);
    if (std.mem.eql(u8, name, "echo")) echoMain(argv);
    if (std.mem.eql(u8, name, "ln")) lnMain(argv);
    if (std.mem.eql(u8, name, "ls")) lsMain(argv);
    if (std.mem.eql(u8, name, "mkdir")) mkdirMain(argv);
    if (std.mem.eql(u8, name, "mv")) mvMain(argv);
    if (std.mem.eql(u8, name, "rm")) rmMain(argv);
    if (std.mem.eql(u8, name, "rmdir")) rmdirMain(argv);
    if (std.mem.eql(u8, name, "stat")) statMain(argv);

    sys.writeAll(
        sys.STDERR,
        "busybox: available tools: cat, cp, echo, ln, ls, mkdir, mv, rm, rmdir, stat\n" ++
            "Invoke via a named link.\n",
    ) catch {};
    sys.exit(1);
}

comptime {
    _ = sys._start;
}
