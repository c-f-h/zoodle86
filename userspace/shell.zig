const std = @import("std");
const heap = @import("allocator.zig");
const readline = @import("readline.zig");
const sys = @import("sys.zig");

const executable_search_path = [_][]const u8{
    "/bin",
};
const MAX_SHELL_TOKENS = sys.MAX_ARGV_COUNT * 2 + 8;
const MAX_SHELL_STAGES = MAX_SHELL_TOKENS;
const SHELL_HISTORY_PATH = "/var/history";
const SHELL_HISTORY_MAX = 32;
const SHELL_HISTORY_LINE_MAX = readline.MAX_LINE;

const ShellHistory = struct {
    entries: [SHELL_HISTORY_MAX][SHELL_HISTORY_LINE_MAX]u8 = undefined,
    lens: [SHELL_HISTORY_MAX]u16 = [_]u16{0} ** SHELL_HISTORY_MAX,
    start: u8 = 0,
    count: u8 = 0,

    fn initEmpty() ShellHistory {
        var history = ShellHistory{};
        @memset(&history.entries, [_]u8{0} ** SHELL_HISTORY_LINE_MAX);
        return history;
    }

    fn len(self: *const ShellHistory) usize {
        return self.count;
    }

    fn push(self: *ShellHistory, line: []const u8) void {
        if (line.len == 0) return;

        var clipped = line;
        if (clipped.len > SHELL_HISTORY_LINE_MAX) {
            clipped = clipped[0..SHELL_HISTORY_LINE_MAX];
        }

        const idx = self.nextWriteIndex();
        @memcpy(self.entries[idx][0..clipped.len], clipped);
        self.lens[idx] = @intCast(clipped.len);
    }

    fn nextWriteIndex(self: *ShellHistory) usize {
        if (self.count < SHELL_HISTORY_MAX) {
            const idx = @as(usize, self.start) + @as(usize, self.count);
            self.count += 1;
            return idx % SHELL_HISTORY_MAX;
        }

        const idx = self.start;
        self.start = @intCast((@as(usize, self.start) + 1) % SHELL_HISTORY_MAX);
        return idx;
    }

    fn at(self: *const ShellHistory, index: usize) []const u8 {
        const idx = (self.start + index) % SHELL_HISTORY_MAX;
        const n = self.lens[idx];
        return self.entries[idx][0..n];
    }

    fn writeToFd(self: *const ShellHistory, fd: u32) void {
        var i: usize = 0;
        while (i < self.len()) : (i += 1) {
            const line = self.at(i);
            sys.writeAll(fd, line) catch return;
            sys.writeAll(fd, "\n") catch return;
        }
    }

    fn print(self: *const ShellHistory) void {
        var i: usize = 0;
        while (i < self.len()) : (i += 1) {
            var line_buf: [SHELL_HISTORY_LINE_MAX + 16]u8 = undefined;
            const rendered = std.fmt.bufPrint(&line_buf, "{d: >3}  {s}\n", .{ i + 1, self.at(i) }) catch continue;
            sys.writeAll(sys.STDOUT, rendered) catch return;
        }
    }
};

const RedirectionKind = enum {
    stdin_file,
    stdout_file,
    stdout_append,

    fn destinationFd(self: RedirectionKind) u32 {
        return switch (self) {
            .stdin_file => sys.STDIN,
            .stdout_file, .stdout_append => sys.STDOUT,
        };
    }

    fn openFlags(self: RedirectionKind) sys.FileOpenFlags {
        return switch (self) {
            .stdin_file => .{},
            .stdout_file => .{
                .open_mode = .WriteOnly,
                .create = true,
                .truncate = true,
            },
            .stdout_append => .{
                .open_mode = .WriteOnly,
                .create = true,
                .append = true,
            },
        };
    }

    fn errorPrefix(self: RedirectionKind) []const u8 {
        return switch (self) {
            .stdin_file => "shell: failed to redirect stdin from ",
            .stdout_file, .stdout_append => "shell: failed to redirect stdout to ",
        };
    }
};

const Operator = enum {
    pipe,
    redirect_stdin,
    redirect_stdout,
    redirect_stdout_append,

    fn fromToken(token: []const u8) ?Operator {
        if (std.mem.eql(u8, token, "|")) return .pipe;
        if (std.mem.eql(u8, token, "<")) return .redirect_stdin;
        if (std.mem.eql(u8, token, ">")) return .redirect_stdout;
        if (std.mem.eql(u8, token, ">>")) return .redirect_stdout_append;
        return null;
    }

    fn redirectionKind(self: Operator) ?RedirectionKind {
        return switch (self) {
            .pipe => null,
            .redirect_stdin => .stdin_file,
            .redirect_stdout => .stdout_file,
            .redirect_stdout_append => .stdout_append,
        };
    }
};

const Redirection = struct {
    kind: RedirectionKind,
    path: []const u8,
};

const CommandStage = struct {
    argv: []const []const u8,
    redirections: []const Redirection,
};

const ParsedCommandLine = struct {
    stages: []const CommandStage,
};

const PipeFds = struct {
    read: u32,
    write: u32,
};

const ParseError = error{
    TooManyStages,
    TooManyArgs,
    TooManyRedirections,
    MissingCommand,
    MissingRedirectionTarget,
    UnexpectedPipe,
};

/// Runs an interactive userspace shell with pipelines and file redirections.
pub fn main(_: []const []const u8) !void {
    const alloc = heap.getAllocator();

    var rl: readline.Readline = .{};
    var history = ShellHistory.initEmpty();
    loadHistory(&history);

    while (true) {
        var history_view: [SHELL_HISTORY_MAX][]const u8 = undefined;
        var history_len: usize = 0;
        while (history_len < history.len()) : (history_len += 1) {
            history_view[history_len] = history.at(history_len);
        }
        rl.setHistory(history_view[0..history_len]);

        rl.init("$ ");
        const line = rl.readLine() catch |err| {
            if (err == error.EOF) {
                _ = sys.write(sys.STDOUT, "\n") catch {};
                return;
            }
            return err;
        };

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        history.push(trimmed);
        saveHistory(&history);

        if (std.mem.eql(u8, trimmed, "history")) {
            history.print();
            continue;
        }

        if (trimmed[0] == '!') {
            // kernel shell escape
            sys.kshell(trimmed[1..]) catch {
                writeLine("shell: kernel shell command failed\n");
            };
            continue;
        }

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
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

    var stage_buf: [MAX_SHELL_STAGES]CommandStage = undefined;
    var argv_buf: [MAX_SHELL_TOKENS][]const u8 = undefined;
    var redirection_buf: [MAX_SHELL_TOKENS]Redirection = undefined;
    const parsed = parseCommandLine(tokens, &stage_buf, &argv_buf, &redirection_buf) catch |err| {
        handleParseError(err);
        return;
    };
    try runParsedCommandLine(alloc, parsed);
}

fn parseCommandLine(
    tokens: []const []const u8,
    stage_buf: *[MAX_SHELL_STAGES]CommandStage,
    argv_buf: *[MAX_SHELL_TOKENS][]const u8,
    redirection_buf: *[MAX_SHELL_TOKENS]Redirection,
) ParseError!ParsedCommandLine {
    var token_index: usize = 0;
    var stage_count: usize = 0;
    var argv_count: usize = 0;
    var redirection_count: usize = 0;

    while (token_index < tokens.len) {
        if (stage_count >= stage_buf.len) return error.TooManyStages;

        const argv_start = argv_count;
        const redirection_start = redirection_count;

        while (token_index < tokens.len and Operator.fromToken(tokens[token_index]) != .pipe) {
            if (Operator.fromToken(tokens[token_index])) |operator| {
                const kind = operator.redirectionKind().?;
                token_index += 1;
                if (token_index >= tokens.len or Operator.fromToken(tokens[token_index]) != null) {
                    return error.MissingRedirectionTarget;
                }
                if (redirection_count >= redirection_buf.len) return error.TooManyRedirections;
                redirection_buf[redirection_count] = .{
                    .kind = kind,
                    .path = tokens[token_index],
                };
                redirection_count += 1;
                token_index += 1;
                continue;
            }

            if (argv_count - argv_start >= sys.MAX_ARGV_COUNT) return error.TooManyArgs;
            argv_buf[argv_count] = tokens[token_index];
            argv_count += 1;
            token_index += 1;
        }

        if (argv_count == argv_start) return error.MissingCommand;
        stage_buf[stage_count] = .{
            .argv = argv_buf[argv_start..argv_count],
            .redirections = redirection_buf[redirection_start..redirection_count],
        };
        stage_count += 1;

        if (token_index == tokens.len) break;
        token_index += 1;
        if (token_index == tokens.len) return error.UnexpectedPipe;
    }

    if (stage_count == 0) return error.MissingCommand;
    return .{ .stages = stage_buf[0..stage_count] };
}

fn runParsedCommandLine(alloc: std.mem.Allocator, parsed: ParsedCommandLine) !void {
    var pipes: [MAX_SHELL_STAGES]PipeFds = undefined;
    var pipe_count: usize = 0;
    while (pipe_count + 1 < parsed.stages.len) : (pipe_count += 1) {
        const read_fd, const write_fd = sys.pipe() catch {
            closePipeList(pipes[0..pipe_count]);
            writeLine("shell: failed to create pipe\n");
            return;
        };
        pipes[pipe_count] = .{ .read = read_fd, .write = write_fd };
    }

    var child_pids: [MAX_SHELL_STAGES]u32 = undefined;
    var child_count: usize = 0;
    for (parsed.stages, 0..) |stage, stage_index| {
        const pid = spawnStage(alloc, stage, pipes[0..pipe_count], stage_index, parsed.stages.len) catch |err| {
            closePipeList(pipes[0..pipe_count]);
            waitForChildren(child_pids[0..child_count]);
            return err;
        };
        if (pid) |child_pid| {
            child_pids[child_count] = child_pid;
            child_count += 1;
            continue;
        }

        closePipeList(pipes[0..pipe_count]);
        waitForChildren(child_pids[0..child_count]);
        return;
    }

    closePipeList(pipes[0..pipe_count]);
    waitForChildren(child_pids[0..child_count]);
}

fn spawnStage(
    alloc: std.mem.Allocator,
    stage: CommandStage,
    pipes: []const PipeFds,
    stage_index: usize,
    stage_count: usize,
) !?u32 {
    var fd_remaps: [MAX_SHELL_TOKENS]sys.FdRemap = undefined;
    var fd_remap_count: usize = 0;

    if (stage_index > 0) {
        fd_remaps[fd_remap_count] = .{
            .dst = sys.STDIN,
            .src = pipes[stage_index - 1].read,
        };
        fd_remap_count += 1;
    }
    if (stage_index + 1 < stage_count) {
        fd_remaps[fd_remap_count] = .{
            .dst = sys.STDOUT,
            .src = pipes[stage_index].write,
        };
        fd_remap_count += 1;
    }

    var opened_fds: [MAX_SHELL_TOKENS]u32 = undefined;
    var opened_count: usize = 0;
    defer closeFdList(opened_fds[0..opened_count]);

    for (stage.redirections) |redirection| {
        const redirection_fd = openRedirectionTarget(redirection) orelse return null;
        opened_fds[opened_count] = redirection_fd;
        opened_count += 1;
        setFdRemap(
            &fd_remaps,
            &fd_remap_count,
            redirection.kind.destinationFd(),
            redirection_fd,
        );
    }

    return spawnInvocation(alloc, stage.argv, fd_remaps[0..fd_remap_count]);
}

fn setFdRemap(
    fd_remaps: *[MAX_SHELL_TOKENS]sys.FdRemap,
    fd_remap_count: *usize,
    dst: u32,
    src: u32,
) void {
    var i: usize = 0;
    while (i < fd_remap_count.*) : (i += 1) {
        if (fd_remaps[i].dst == dst) {
            fd_remaps[i].src = src;
            return;
        }
    }

    fd_remaps[fd_remap_count.*] = .{ .dst = dst, .src = src };
    fd_remap_count.* += 1;
}

fn openRedirectionTarget(redirection: Redirection) ?u32 {
    return sys.open(redirection.path, redirection.kind.openFlags()) catch {
        writeError(redirection.kind.errorPrefix(), redirection.path);
        return null;
    };
}

fn closePipeList(pipes: []const PipeFds) void {
    for (pipes) |pipe| {
        sys.close(pipe.read) catch {};
        sys.close(pipe.write) catch {};
    }
}

fn closeFdList(fds: []const u32) void {
    for (fds) |fd| {
        sys.close(fd) catch {};
    }
}

fn waitForChildren(pids: []const u32) void {
    for (pids) |pid| {
        _ = waitForChild(pid);
    }
}

fn handleParseError(err: ParseError) void {
    switch (err) {
        error.TooManyStages, error.TooManyArgs, error.TooManyRedirections => {
            writeLine("shell: too many arguments\n");
        },
        error.MissingCommand, error.MissingRedirectionTarget, error.UnexpectedPipe => {
            writeUsage();
        },
    }
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
    const fd = sys.open(path, .{}) catch return false;
    sys.close(fd) catch return false;
    return true;
}

fn waitForChild(pid: u32) bool {
    _ = sys.waitpid(pid) catch {
        writeLine("shell: failed to wait for child\n");
        return false;
    };
    return true;
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
    if (ch == '|') {
        cursor.* += 1;
        return cmdline[start..cursor.*];
    }
    if (ch == '<') {
        cursor.* += 1;
        return cmdline[start..cursor.*];
    }
    if (ch == '>') {
        cursor.* += if (cursor.* + 1 < cmdline.len and cmdline[cursor.* + 1] == '>') 2 else 1;
        return cmdline[start..cursor.*];
    }

    while (cursor.* < cmdline.len) : (cursor.* += 1) {
        const current = cmdline[cursor.*];
        if (current == ' ' or current == '\t' or current == '|' or current == '>' or current == '<') break;
    }

    return cmdline[start..cursor.*];
}

fn writeUsage() void {
    writeLine("Usage: <command> [<arg> | < <file> | > <file> | >> <file> ...]\n");
    writeLine("       [| <command> [<arg> | < <file> | > <file> | >> <file> ...] ...]\n");
    writeLine("       !<kernel command> [<arg> ...]\n");
}

fn writeError(prefix: []const u8, desc: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ prefix, desc }) catch return;
    sys.writeAll(sys.STDERR, msg) catch {};
}

fn writeLine(msg: []const u8) void {
    sys.writeAll(sys.STDOUT, msg) catch {};
}

fn loadHistory(history: *ShellHistory) void {
    const fd = sys.open(SHELL_HISTORY_PATH, .{}) catch return;
    defer sys.close(fd) catch {};

    var file_buf: [SHELL_HISTORY_MAX * (SHELL_HISTORY_LINE_MAX + 1)]u8 = undefined;
    const bytes = sys.read(fd, &file_buf) catch return;
    if (bytes == 0) return;

    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes) : (i += 1) {
        if (file_buf[i] != '\n') continue;
        const line = std.mem.trimEnd(u8, file_buf[start..i], "\r");
        history.push(line);
        start = i + 1;
    }

    if (start < bytes) {
        const tail = std.mem.trimEnd(u8, file_buf[start..bytes], "\r");
        history.push(tail);
    }
}

fn saveHistory(history: *const ShellHistory) void {
    sys.mkdir("/var") catch {};
    const fd = sys.open(SHELL_HISTORY_PATH, .{
        .open_mode = .WriteOnly,
        .create = true,
        .truncate = true,
    }) catch return;
    defer sys.close(fd) catch {};
    history.writeToFd(fd);
}

comptime {
    _ = sys._start;
}
