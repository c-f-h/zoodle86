const std = @import("std");
const heap = @import("allocator.zig");
const readline = @import("readline.zig");
const sys = @import("sys.zig");

const executable_search_path = [_][]const u8{
    "/bin",
};
const MAX_SHELL_TOKENS = sys.MAX_ARGV_COUNT * 2 + 8;

/// Runs an interactive userspace shell with basic `>` and `|` redirection.
pub fn main(_: []const []const u8) !void {
    const alloc = heap.getAllocator();

    var rl: readline.Readline = .{};

    while (true) {
        rl.init("$ ");
        const line = rl.readLine() catch |err| {
            if (err == error.EOF) {
                _ = sys.write(sys.STDOUT, "\n");
                readline.showCursor(false);
                return;
            }
            return err;
        };

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '!') {
            // kernel shell escape
            _ = sys.kshell(trimmed[1..]);
            continue;
        }

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            readline.showCursor(false);
            return;
        }

        runCommandLine(alloc, trimmed) catch |err| {
            writeError("shell: internal error: ", @errorName(err));
        };
    }
}

fn runCommandLine(alloc: std.mem.Allocator, line: []const u8) !void {
    var tokens_buf: [MAX_SHELL_TOKENS][]const u8 = undefined;
    const tokens = tokenizeShellCommandLine(line, &tokens_buf) orelse {
        writeLine("shell: too many arguments\n");
        return;
    };
    if (tokens.len == 0) return;

    var lhs_buf: [sys.MAX_ARGV_COUNT][]const u8 = undefined;
    var rhs_buf: [sys.MAX_ARGV_COUNT][]const u8 = undefined;
    var cur: usize = 0;

    // Get first command
    const lhs_argv = collectInvocation(tokens, &cur, &lhs_buf) orelse {
        writeUsage();
        return;
    };

    // If at end of command line, run it
    if (cur == tokens.len) {
        return runSingleInvocation(alloc, lhs_argv);
    }

    const operator = tokens[cur];
    cur += 1;

    // Redirect stdout to file
    if (std.mem.eql(u8, operator, ">")) {
        const output_path = tokens[cur..];
        if (output_path.len != 1 or isRedirectionToken(output_path[0])) {
            writeUsage();
            return;
        }

        try redirectStdoutToFile(alloc, lhs_argv, output_path[0]);
        return;
    }

    // Otherwise, should be pipe operator
    if (!std.mem.eql(u8, operator, "|")) {
        writeUsage();
        return;
    }

    const rhs_argv = collectInvocation(tokens, &cur, &rhs_buf) orelse {
        writeUsage();
        return;
    };
    if (cur != tokens.len) {
        writeLine("shell: basic redirection supports only one operator\n");
        return;
    }

    try runPipeline(alloc, lhs_argv, rhs_argv);
}

fn runSingleInvocation(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const pid = (try spawnInvocation(alloc, argv, &.{})) orelse return;
    _ = waitForChild(pid);
}

fn redirectStdoutToFile(alloc: std.mem.Allocator, argv: []const []const u8, path: []const u8) !void {
    const output_fd = sys.open(path, .{
        .open_mode = .WriteOnly,
        .create = true,
        .truncate = true,
    });
    if (output_fd == sys.FAIL) {
        writeError("shell: failed to redirect stdout to ", path);
        return;
    }
    defer _ = sys.close(output_fd);

    const fd_remaps = [_]sys.FdRemap{
        .{ .dst = sys.STDOUT, .src = output_fd },
    };
    const pid = (try spawnInvocation(alloc, argv, &fd_remaps)) orelse return;
    _ = waitForChild(pid);
}

fn runPipeline(alloc: std.mem.Allocator, lhs_argv: []const []const u8, rhs_argv: []const []const u8) !void {
    const read_fd, const write_fd = sys.pipe() catch {
        writeLine("shell: failed to create pipe\n");
        return;
    };
    defer _ = sys.close(read_fd);
    defer _ = sys.close(write_fd);

    const consumer_remaps = [_]sys.FdRemap{
        .{ .dst = sys.STDIN, .src = read_fd },
    };
    const consumer_pid = (try spawnInvocation(alloc, rhs_argv, &consumer_remaps)) orelse return;

    const producer_remaps = [_]sys.FdRemap{
        .{ .dst = sys.STDOUT, .src = write_fd },
    };
    const producer_pid = (try spawnInvocation(alloc, lhs_argv, &producer_remaps)) orelse {
        _ = waitForChild(consumer_pid);
        return;
    };

    _ = waitForChild(producer_pid);
    _ = waitForChild(consumer_pid);
}

fn spawnInvocation(alloc: std.mem.Allocator, argv: []const []const u8, fd_remaps: []const sys.FdRemap) !?u32 {
    const resolved = resolveProgramPath(alloc, argv[0]) catch |err| switch (err) {
        error.FileNotFound => {
            writeError("shell: command not found: ", argv[0]);
            return null;
        },
        else => return err,
    };
    defer alloc.free(resolved);

    return sys.spawnOpts(resolved, argv[1..], fd_remaps) catch |err| {
        writeError("shell: failed to spawn command: ", @errorName(err));
        return null;
    };
}

fn resolveProgramPath(alloc: std.mem.Allocator, fname: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, fname, '/') != null) {
        return try alloc.dupe(u8, fname);
    }

    for (executable_search_path) |path_prefix| {
        const needs_separator = path_prefix.len != 0 and path_prefix[path_prefix.len - 1] != '/';
        const candidate = try std.mem.concat(alloc, u8, &.{
            path_prefix,
            if (needs_separator) "/" else "",
            fname,
        });
        errdefer alloc.free(candidate);

        if (pathExists(candidate)) {
            return candidate;
        }

        alloc.free(candidate);
    }

    return error.FileNotFound;
}

fn pathExists(path: []const u8) bool {
    const fd = sys.open(path, .{});
    if (fd == sys.FAIL) return false;
    _ = sys.close(fd);
    return true;
}

fn waitForChild(pid: u32) bool {
    if (sys.waitpid(pid) != sys.FAIL) return true;
    writeLine("shell: failed to wait for child\n");
    return false;
}

fn tokenizeShellCommandLine(cmdline: []const u8, buf: *[MAX_SHELL_TOKENS][]const u8) ?[]const []const u8 {
    var count: usize = 0;
    var cursor: usize = 0;

    while (nextToken(cmdline, &cursor)) |token| {
        if (count >= buf.len) return null;
        buf[count] = token;
        count += 1;
    }

    return buf[0..count];
}

fn nextToken(cmdline: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < cmdline.len and (cmdline[cursor.*] == ' ' or cmdline[cursor.*] == '\t')) : (cursor.* += 1) {}
    if (cursor.* >= cmdline.len) return null;

    const start = cursor.*;
    const ch = cmdline[cursor.*];
    if (ch == '|' or ch == '>' or ch == '<') {
        cursor.* += 1;
        return cmdline[start..cursor.*];
    }

    while (cursor.* < cmdline.len) : (cursor.* += 1) {
        const current = cmdline[cursor.*];
        if (current == ' ' or current == '\t' or current == '|' or current == '>' or current == '<') break;
    }

    return cmdline[start..cursor.*];
}

fn isRedirectionToken(token: []const u8) bool {
    return token.len == 1 and (token[0] == '|' or token[0] == '>' or token[0] == '<');
}

/// Collect tokens until the next redirection operator or end of tokens.
fn collectInvocation(
    tokens: []const []const u8,
    token_index: *usize,
    buf: *[sys.MAX_ARGV_COUNT][]const u8,
) ?[]const []const u8 {
    var argc: usize = 0;
    while (token_index.* < tokens.len and !isRedirectionToken(tokens[token_index.*])) : (token_index.* += 1) {
        if (argc >= buf.len) return null;
        buf[argc] = tokens[token_index.*];
        argc += 1;
    }
    if (argc == 0) return null;
    return buf[0..argc];
}

fn writeUsage() void {
    writeLine("Usage: <command> [<arg> ...]\n");
    writeLine("       <command> [<arg> ...] > <file>\n");
    writeLine("       <command> [<arg> ...] | <command> [<arg> ...]\n");
    writeLine("       !<kernel command> [<arg> ...]\n");
}

fn writeError(prefix: []const u8, desc: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ prefix, desc }) catch return;
    _ = sys.writeAll(sys.STDERR, msg);
}

fn writeLine(msg: []const u8) void {
    _ = sys.writeAll(sys.STDOUT, msg);
}

comptime {
    _ = sys._start;
}
