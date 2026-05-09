const std = @import("std");

const app_keylog = @import("app_keylog.zig");
const app_memmap = @import("app_memmap.zig");
const console = @import("console.zig");
const cpuid = @import("cpuid.zig");
const fs = @import("fs.zig");
const filedesc = @import("filedesc.zig");
const io = @import("io.zig");
const keyboard = @import("keyboard.zig");
const kprof = @import("kprof.zig");
const pageallocator = @import("pageallocator.zig");
const readline = @import("readline.zig");
const kernel = @import("kernel.zig");
const serial = @import("serial.zig");
const task = @import("task.zig");
const taskman = @import("taskman.zig");

const autoexec_name = "autoexec";
const executable_search_path = [_][]const u8{
    "/bin",
};
const MAX_SHELL_TOKENS = task.MAX_ARGV_COUNT * 2 + 8;

var autoexec_next_line_idx: usize = 0;
var autoexec_finished: bool = false;

const ArgsIterator = std.mem.TokenIterator(u8, .any);

pub const Shell = struct {
    alloc: std.mem.Allocator,
    disk_fs: *fs.FileSystem,
    console: *console.Console,
};

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn (*Shell, *ArgsIterator) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "help", .description = "List available commands.", .handler = cmdHelp },
    .{ .name = "keylog", .description = "Run the key event logger.", .handler = cmdKeylog },
    .{ .name = "ls", .description = "List files in a directory.", .handler = cmdLs },
    .{ .name = "write", .description = "Write a file from console input.", .handler = cmdWrite },
    .{ .name = "rm", .description = "Delete a file.", .handler = cmdRm },
    .{ .name = "mv", .description = "Rename a file.", .handler = cmdMv },
    .{ .name = "cpuid", .description = "Show CPUID clock leaves or query a raw leaf/subleaf.", .handler = cmdCpuid },
    .{ .name = "mkfs", .description = "Reformat the filesystem.", .handler = cmdMkfs },
    .{ .name = "dumpmem", .description = "Dump memory at a hex address.", .handler = cmdDumpmem },
    .{ .name = "memmap", .description = "Interactive page directory/table memory map viewer.", .handler = cmdMemmap },
    .{ .name = "memstat", .description = "Show page allocator memory statistics.", .handler = cmdMemstat },
    .{ .name = "taskswitch", .description = "Show the scheduler task-to-task switch count.", .handler = cmdTaskSwitch },
    .{ .name = "ticks", .description = "Write current timer ticks to serial, appending arguments.", .handler = cmdTicks },
    .{ .name = "profile", .description = "Kernel EIP profiler control: profile start|stop.", .handler = cmdProfile },
    .{ .name = "fontbench", .description = "Stress font rendering without scrollback: fontbench <count>.", .handler = cmdFontbench },
    .{ .name = "serial", .description = "Mirror console output to COM1: serial on|off.", .handler = cmdSerial },
    .{ .name = "run", .description = "Run an ELF executable with basic | and > redirection.", .handler = cmdRun },
    .{ .name = "multirun", .description = "Run multiple copies of an ELF executable with command-line arguments.", .handler = cmdMultiRun },
    .{ .name = "ps", .description = "List all active tasks and their status.", .handler = cmdPs },
    .{ .name = "shutdown", .description = "Power off Bochs/QEMU.", .handler = cmdShutdown },
    .{ .name = "break", .description = "Invoke a Bochs magic breakpoint.", .handler = cmdDebugBreak },
};

/// Execute a shell command with the given shell instance.
pub fn handleCommand(shell: *Shell, cmdline: []const u8) !void {
    if (tryHandleRunCommandLine(shell, cmdline)) {
        return;
    }

    var args = std.mem.tokenizeAny(u8, cmdline, " \t");
    const cmd_name = args.next() orelse return;

    if (findCommand(cmd_name)) |command| {
        command.handler(shell, &args) catch |err| {
            printErrorDesc(shell, err);
        };
    } else {
        shell.console.puts("Unknown command ");
        shell.console.puts(cmd_name);
        shell.console.newline();
    }
}

/// Run the interactive shell command loop.
pub fn run(alloc: std.mem.Allocator, disk_fs: *fs.FileSystem) !noreturn {
    var shell = Shell{
        .alloc = alloc,
        .disk_fs = disk_fs,
        .console = &console.primary,
    };

    try runAutoexec(&shell);

    while (true) {
        var cmdline_buf = [1]u8{0} ** 128;
        const cmdline = try readLineInto(&shell, &cmdline_buf);
        try handleCommand(&shell, cmdline);
    }
}

fn findCommand(name: []const u8) ?*const Command {
    for (&commands) |*command| {
        if (std.mem.eql(u8, command.name, name)) {
            return command;
        }
    }
    return null;
}

fn tryHandleRunCommandLine(shell: *Shell, cmdline: []const u8) bool {
    var tokens_buf: [MAX_SHELL_TOKENS][]const u8 = undefined;
    const tokens = tokenizeShellCommandLine(cmdline, &tokens_buf) orelse {
        shell.console.puts("Too many arguments.\n");
        return true;
    };
    if (tokens.len == 0) return true;
    if (!std.mem.eql(u8, tokens[0], "run")) return false;

    handleRunCommandLine(shell, tokens);
    return true;
}

fn handleRunCommandLine(shell: *Shell, tokens: []const []const u8) void {
    var lhs_buf: [task.MAX_ARGV_COUNT][]const u8 = undefined;
    var rhs_buf: [task.MAX_ARGV_COUNT][]const u8 = undefined;
    var token_index: usize = 1;

    // Parse command line up to the first redirection operator
    const lhs_argv = collectRunInvocation(tokens, &token_index, &lhs_buf) orelse {
        printUsage(shell, "run");
        return;
    };

    // If there is no redirection, just run the command.
    if (token_index == tokens.len) {
        const ptask = loadRunTask(shell, lhs_argv) orelse return;
        kernel.schedule_initial(ptask);
    }

    const operator = tokens[token_index];
    token_index += 1;

    // ">": redirection to a file
    if (std.mem.eql(u8, operator, ">")) {
        const output_path = tokens[token_index..];
        if (output_path.len != 1 or isRedirectionToken(output_path[0])) {
            printUsage(shell, "run");
            return;
        }

        const ptask = loadRunTask(shell, lhs_argv) orelse return;
        if (!redirectTaskStdoutToFile(shell, ptask, output_path[0])) {
            kernel.discardTask(ptask);
            return;
        }

        kernel.schedule_initial(ptask);
    }

    if (!std.mem.eql(u8, operator, "|")) {
        printUsage(shell, "run");
        return;
    }

    // "|": pipe between two commands
    const rhs_argv = collectRunInvocation(tokens, &token_index, &rhs_buf) orelse {
        printUsage(shell, "run");
        return;
    };
    if (token_index != tokens.len) {
        shell.console.puts("Basic run redirection supports only one operator.\n");
        return;
    }

    const producer = loadRunTask(shell, lhs_argv) orelse return;
    const consumer = loadRunTask(shell, rhs_argv) orelse {
        kernel.discardTask(producer);
        return;
    };

    const pipe_fds = filedesc.makePipe() catch |err| {
        shell.console.put(.{ "Failed to create pipe: ", kernel.getErrorDesc(err), "\n" });
        kernel.discardTask(consumer);
        kernel.discardTask(producer);
        return;
    };

    producer.replaceFdSlot(1, pipe_fds.@"1");
    consumer.replaceFdSlot(0, pipe_fds.@"0");

    kernel.schedule_initial(producer);
}

fn tokenizeShellCommandLine(cmdline: []const u8, buf: *[MAX_SHELL_TOKENS][]const u8) ?[]const []const u8 {
    var count: usize = 0;
    var cursor: usize = 0;

    while (nextShellToken(cmdline, &cursor)) |token| {
        if (count >= buf.len) return null;
        buf[count] = token;
        count += 1;
    }

    return buf[0..count];
}

fn nextShellToken(cmdline: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < cmdline.len and (cmdline[cursor.*] == ' ' or cmdline[cursor.*] == '\t')) : (cursor.* += 1) {}
    if (cursor.* >= cmdline.len) return null;

    const start = cursor.*;
    const ch = cmdline[cursor.*];
    if (ch == '|' or ch == '>') {
        cursor.* += 1;
        return cmdline[start..cursor.*];
    }

    while (cursor.* < cmdline.len) : (cursor.* += 1) {
        const current = cmdline[cursor.*];
        if (current == ' ' or current == '\t' or current == '|' or current == '>') break;
    }

    return cmdline[start..cursor.*];
}

fn isRedirectionToken(token: []const u8) bool {
    return token.len == 1 and (token[0] == '|' or token[0] == '>');
}

/// Collects tokens up to the next redirection operator or the end of the token list, returning them as an argv slice.
fn collectRunInvocation(
    tokens: []const []const u8,
    token_index: *usize,
    buf: *[task.MAX_ARGV_COUNT][]const u8,
) ?[]const []const u8 {
    var argc: usize = 0;
    while (token_index.* < tokens.len and !isRedirectionToken(tokens[token_index.*])) : (token_index.* += 1) {
        if (argc >= buf.len) {
            return null;
        }
        buf[argc] = tokens[token_index.*];
        argc += 1;
    }
    if (argc == 0) return null;
    return buf[0..argc];
}

fn redirectTaskStdoutToFile(shell: *Shell, ptask: *task.Task, path: []const u8) bool {
    const desc = filedesc.openFileDesc(shell.disk_fs, path, filedesc.O_WRONLY | filedesc.O_CREAT | filedesc.O_TRUNC) catch |err| {
        shell.console.put(.{ "Failed to redirect stdout to ", path, ": ", kernel.getErrorDesc(err), "\n" });
        return false;
    };
    ptask.replaceFdSlot(1, desc);
    return true;
}

fn runAutoexec(shell: *Shell) !void {
    if (autoexec_finished) return;

    const script = shell.disk_fs.readFileAt(shell.alloc, fs.ROOT_INODE_INDEX, autoexec_name) catch |err| switch (err) {
        error.FileNotFound => {
            autoexec_finished = true;
            return;
        },
        else => return err,
    };
    defer shell.alloc.free(script);

    if (autoexec_next_line_idx == 0) {
        shell.console.puts("Running autoexec.\n");
    }

    var line_idx: usize = 0;
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw_line| : (line_idx += 1) {
        if (line_idx < autoexec_next_line_idx) continue;

        autoexec_next_line_idx = line_idx + 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try handleCommand(shell, line);
    }

    autoexec_finished = true;
}

fn cmdKeylog(shell: *Shell, args: *ArgsIterator) !void {
    _ = args;

    var app: app_keylog.Keylog = .{ .console = shell.console };
    app.init();
    defer app.deinit();

    while (true) {
        keyboard.pollingLoop();
    }
}

fn cmdMemmap(shell: *Shell, args: *ArgsIterator) !void {
    _ = args;

    var app: app_memmap.Memmap = .{ .console = shell.console };
    app.init();
    defer app.deinit();

    while (!app.done) {
        keyboard.pollingLoop();
    }
}

fn cmdHelp(shell: *Shell, args: *ArgsIterator) !void {
    _ = args;

    for (commands) |command| {
        shell.console.puts(command.name);
        shell.console.puts(" - ");
        shell.console.puts(command.description);
        shell.console.newline();
    }
}

fn cmdLs(shell: *Shell, args: *ArgsIterator) !void {
    const path = args.next() orelse &.{};
    try listFiles(shell, shell.disk_fs, path);
}

fn cmdWrite(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next()) |name| {
        try writeFileFromConsole(shell, shell.alloc, shell.disk_fs, name);
    } else {
        printUsage(shell, "write");
    }
}

fn cmdRm(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next()) |name| {
        try deleteFile(shell, shell.disk_fs, name);
    } else {
        printUsage(shell, "rm");
    }
}

fn cmdMv(shell: *Shell, args: *ArgsIterator) !void {
    const old_name = args.next() orelse {
        printUsage(shell, "mv");
        return;
    };
    const new_name = args.next() orelse {
        printUsage(shell, "mv");
        return;
    };
    try renameFile(shell, shell.disk_fs, old_name, new_name);
}

fn cmdCpuid(shell: *Shell, args: *ArgsIterator) !void {
    const leaf_arg = args.next();
    if (leaf_arg) |raw_leaf| {
        const leaf = parseNumericArg(raw_leaf) catch {
            printUsage(shell, "cpuid");
            return;
        };
        const subleaf = if (args.next()) |raw_subleaf|
            parseNumericArg(raw_subleaf) catch {
                printUsage(shell, "cpuid");
                return;
            }
        else
            0;
        if (args.next() != null) {
            printUsage(shell, "cpuid");
            return;
        }
        printCpuidLeaf(shell, leaf, subleaf);
        return;
    }

    const vendor = cpuid.vendorInfo();
    shell.console.puts("CPUID vendor: ");
    shell.console.puts(vendor.vendor[0..]);
    shell.console.newline();

    shell.console.puts("Max basic leaf: ");
    shell.console.putHexU32(vendor.max_basic_leaf);
    shell.console.newline();

    const max_extended = cpuid.maxExtendedLeaf();
    shell.console.puts("Max extended leaf: ");
    shell.console.putHexU32(max_extended);
    shell.console.newline();

    if (vendor.max_basic_leaf >= 0x01) {
        const leaf1 = cpuid.query(0x01, 0);
        shell.console.puts("Local APIC present: ");
        shell.console.puts(if ((leaf1.edx & (1 << 9)) != 0) "yes" else "no");
        shell.console.newline();
    }

    if (vendor.max_basic_leaf >= 0x15) {
        const leaf15 = cpuid.query(0x15, 0);
        shell.console.put(.{ "Leaf 00000015: eax=", leaf15.eax, " ebx=", leaf15.ebx, " ecx=", leaf15.ecx, " edx=", leaf15.edx, "\n" });

        if (leaf15.eax != 0 and leaf15.ebx != 0) {
            shell.console.puts("  TSC/crystal ratio: ");
            shell.console.putDecU32(leaf15.ebx);
            shell.console.puts("/");
            shell.console.putDecU32(leaf15.eax);
            shell.console.newline();
        }
        if (leaf15.ecx != 0) {
            shell.console.puts("  Crystal clock (Hz): ");
            shell.console.putDecU32(leaf15.ecx);
            shell.console.newline();
        }
    } else {
        shell.console.puts("Leaf 00000015 not supported.\n");
    }

    if (vendor.max_basic_leaf >= 0x16) {
        const leaf16 = cpuid.query(0x16, 0);
        shell.console.put(.{ "Leaf 00000016: eax=", leaf16.eax, " ebx=", leaf16.ebx, " ecx=", leaf16.ecx, " edx=", leaf16.edx, "\n" });

        if (leaf16.eax != 0) {
            shell.console.puts("  Base frequency (MHz): ");
            shell.console.putDecU32(leaf16.eax);
            shell.console.newline();
        }
        if (leaf16.ebx != 0) {
            shell.console.puts("  Max frequency (MHz): ");
            shell.console.putDecU32(leaf16.ebx);
            shell.console.newline();
        }
        if (leaf16.ecx != 0) {
            shell.console.puts("  Bus/reference frequency (MHz): ");
            shell.console.putDecU32(leaf16.ecx);
            shell.console.newline();
        }
    } else {
        shell.console.puts("Leaf 00000016 not supported.\n");
    }
}

fn cmdMkfs(shell: *Shell, args: *ArgsIterator) !void {
    _ = args;
    try shell.disk_fs.format();
    shell.console.puts("Filesystem reformatted.\n");
}

fn cmdDumpmem(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next()) |addr_str| {
        if (std.fmt.parseInt(u32, addr_str, 16)) |addr| {
            shell.console.dumpMem(addr, 16);
        } else |_| {
            shell.console.puts("Enter a hex address.\n");
        }
    } else {
        printUsage(shell, "dumpmem");
    }
}

fn printPageUsage(shell: *Shell, page_count: usize, page_size_bytes: usize) void {
    shell.console.putDecU32(@intCast(page_count));
    shell.console.puts(" pages (");
    shell.console.putDecU32(@intCast((page_count * page_size_bytes) / 1024));
    shell.console.puts(" KiB)");
}

fn cmdMemstat(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next() != null) {
        printUsage(shell, "memstat");
        return;
    }

    const stats = pageallocator.getStats();
    const used_pages = stats.total_pages - stats.free_pages;

    shell.console.puts("Page allocator:\n");
    shell.console.puts("  range: ");
    shell.console.putHexU32(@intCast(stats.managed_start));
    shell.console.puts("..");
    shell.console.putHexU32(@intCast(stats.managed_end));
    shell.console.newline();

    shell.console.puts("  total: ");
    printPageUsage(shell, stats.total_pages, stats.page_size_bytes);
    shell.console.newline();

    shell.console.puts("  used : ");
    printPageUsage(shell, used_pages, stats.page_size_bytes);
    shell.console.newline();

    shell.console.puts("  free : ");
    printPageUsage(shell, stats.free_pages, stats.page_size_bytes);
    shell.console.newline();

    shell.console.puts("  word[");
    shell.console.putDecU32(@intCast(stats.current_word_index));
    shell.console.puts("]: ");
    shell.console.putBinaryU32(stats.current_word_bits);
    shell.console.newline();
}

fn cmdTaskSwitch(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next() != null) {
        printUsage(shell, "taskswitch");
        return;
    }

    shell.console.puts("Task switches: ");
    shell.console.putDecU32(kernel.getTaskSwitchCount());
    shell.console.newline();
}

fn cmdTicks(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;

    var tick_buf: [10]u8 = undefined;
    const tick_text = try std.fmt.bufPrint(&tick_buf, "{}", .{kernel.getTimerTicks()});
    serial.puts("ticks ");
    serial.puts(tick_text);

    while (args.next()) |arg| {
        serial.putch(' ');
        serial.puts(arg);
    }
    serial.putch('\n');
}

fn cmdProfile(shell: *Shell, args: *ArgsIterator) !void {
    const action = args.next() orelse {
        printUsage(shell, "profile");
        return;
    };

    if (args.next() != null) {
        printUsage(shell, "profile");
        return;
    }

    if (std.mem.eql(u8, action, "start")) {
        kprof.start() catch |err| {
            switch (err) {
                error.AlreadyRunning => shell.console.puts("Profiler already running.\n"),
                error.NotInitialized => shell.console.puts("Profiler not initialized.\n"),
                error.OutOfMemory => shell.console.puts("Profiler could not allocate sampling page(s).\n"),
                else => return err,
            }
            return;
        };
        shell.console.puts("Profiler started.\n");
        return;
    }

    if (std.mem.eql(u8, action, "stop")) {
        kprof.stop() catch |err| {
            switch (err) {
                error.NotRunning => shell.console.puts("Profiler is not running.\n"),
                error.NotInitialized => shell.console.puts("Profiler not initialized.\n"),
                error.OutOfMemory => shell.console.puts("Profiler aggregation ran out of memory.\n"),
                else => return err,
            }
            return;
        };
        shell.console.puts("Profiler stopped; histogram written to serial.\n");
        return;
    }

    printUsage(shell, "profile");
}

fn cmdFontbench(shell: *Shell, args: *ArgsIterator) !void {
    const raw_count = args.next() orelse {
        printUsage(shell, "fontbench");
        return;
    };
    const iterations = parseNumericArg(raw_count) catch {
        printUsage(shell, "fontbench");
        return;
    };
    if (args.next() != null) {
        printUsage(shell, "fontbench");
        return;
    }
    if (iterations == 0) {
        shell.console.puts("fontbench count must be at least 1.\n");
        return;
    }

    shell.console.stressWrite(iterations);
}

fn cmdSerial(shell: *Shell, args: *ArgsIterator) !void {
    const state = args.next() orelse {
        shell.console.puts("Serial mirroring is ");
        shell.console.puts(if (console.primary.isSerialMirrorEnabled()) "on.\n" else "off.\n");
        printUsage(shell, "serial");
        return;
    };

    if (std.mem.eql(u8, state, "on")) {
        console.primary.setSerialMirrorEnabled(true);
        kernel.secondary_console.setSerialMirrorEnabled(true);
        shell.console.puts("Serial mirroring enabled.\n");
    } else if (std.mem.eql(u8, state, "off")) {
        console.primary.setSerialMirrorEnabled(false);
        kernel.secondary_console.setSerialMirrorEnabled(false);
        shell.console.puts("Serial mirroring disabled.\n");
    } else {
        printUsage(shell, "serial");
    }
}

fn resolveProgramPath(shell: *Shell, fname: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, fname, '/') != null) {
        return try shell.alloc.dupe(u8, fname);
    }

    for (executable_search_path) |path_prefix| {
        const needs_separator = path_prefix.len != 0 and path_prefix[path_prefix.len - 1] != '/';
        const candidate = try std.mem.concat(shell.alloc, u8, &.{
            path_prefix,
            if (needs_separator) "/" else "",
            fname,
        });
        errdefer shell.alloc.free(candidate);

        if (try shell.disk_fs.pathExists(candidate)) {
            return candidate;
        }

        shell.alloc.free(candidate);
    }

    return error.FileNotFound;
}

fn tryLoadProgram(shell: *Shell, display_name: []const u8, fname: []const u8, argv: []const []const u8) ?*task.Task {
    const ptask = kernel.loadUserspaceElf(fname, argv) catch |err| {
        shell.console.put(.{ "Failed to load ", display_name, ": ", kernel.getErrorDesc(err), "\n" });
        return null;
    };
    if (kernel.secondary_console.vconsole_instance != null) {
        ptask.stdout_console = &kernel.secondary_console;
    }
    return ptask;
}

/// Does path resolution for a program invocation, then creates a new task for the program.
fn loadRunTask(shell: *Shell, argv: []const []const u8) ?*task.Task {
    const fname = argv[0];
    const resolved = resolveProgramPath(shell, fname) catch |err| {
        shell.console.put(.{ "Failed to load ", fname, ": ", kernel.getErrorDesc(err), "\n" });
        return null;
    };
    defer shell.alloc.free(resolved);

    var argv_buf: [task.MAX_ARGV_COUNT][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = resolved;
    argc += 1;

    for (argv[1..]) |arg| {
        if (argc >= argv_buf.len) {
            shell.console.puts("Too many arguments.\n");
            return null;
        }
        argv_buf[argc] = arg;
        argc += 1;
    }

    return tryLoadProgram(shell, fname, resolved, argv_buf[0..argc]);
}

fn cmdMultiRun(shell: *Shell, args: *ArgsIterator) !void {
    const raw_count = args.next() orelse {
        shell.console.puts("Usage: multirun <count> <executable> [<arg> ...]\n");
        return;
    };
    const copy_count = parseNumericArg(raw_count) catch {
        shell.console.puts("Usage: multirun <count> <executable> [<arg> ...]\n");
        return;
    };
    const fname = args.next() orelse {
        shell.console.puts("Usage: multirun <count> <executable> [<arg> ...]\n");
        return;
    };

    if (copy_count == 0) {
        shell.console.puts("multirun count must be at least 1.\n");
        return;
    }

    const resolved = resolveProgramPath(shell, fname) catch |err| {
        shell.console.put(.{ "Failed to load ", fname, ": ", kernel.getErrorDesc(err), "\n" });
        return;
    };
    defer shell.alloc.free(resolved);

    // argv[0] is the executable name; remaining tokens follow.
    var argv_buf: [task.MAX_ARGV_COUNT][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = resolved;
    argc += 1;
    while (args.next()) |arg| {
        if (argc >= argv_buf.len) {
            shell.console.puts("Too many arguments.\n");
            return;
        }
        argv_buf[argc] = arg;
        argc += 1;
    }

    var first_task: ?*task.Task = null;
    var remaining = copy_count;
    while (remaining != 0) : (remaining -= 1) {
        if (tryLoadProgram(shell, fname, resolved, argv_buf[0..argc])) |ptask| {
            if (first_task == null) first_task = ptask;
        } else {
            return;
        }
    }

    kernel.schedule_initial(first_task.?);
}

fn cmdRun(shell: *Shell, args: *ArgsIterator) !void {
    // Just a dummy command for `help` and usage printing; the actual "run" command handling is in tryHandleRunCommandLine.
    _ = shell;
    _ = args;
    return;
}

fn printTaskRow(con: *console.Console, t: *const task.Task) void {
    con.putDecU32(t.pid);
    con.puts("  ");
    switch (t.state) {
        .free => unreachable,
        .active => con.puts("active          "),
        .waiting => con.puts("waiting         "),
        .zombie => con.puts("zombie          "),
    }
    if (t.parent_pid != 0) {
        con.puts("parent=");
        con.putDecU32(t.parent_pid);
    } else {
        con.puts("parent=kernel");
    }
    con.newline();
}

fn cmdPs(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next() != null) {
        printUsage(shell, "ps");
        return;
    }
    shell.console.puts("PID  STATE            PARENT\n");
    taskman.forEachTask(*console.Console, shell.console, printTaskRow);
}

fn cmdShutdown(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;
    _ = args;
    io.outw(0xB004, 0x2000); // Bochs specific
    io.outw(0x604, 0x2000); // QEMU specific
    // TODO: General ACPI shutdown is more involved...
}

fn cmdDebugBreak(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;
    _ = args;
    kernel.bochsDebugBreak();
}

fn parseNumericArg(raw: []const u8) !u32 {
    if (std.mem.startsWith(u8, raw, "0x") or std.mem.startsWith(u8, raw, "0X")) {
        return try std.fmt.parseInt(u32, raw[2..], 16);
    }
    return try std.fmt.parseInt(u32, raw, 10);
}

fn printCpuidLeaf(shell: *Shell, leaf: u32, subleaf: u32) void {
    const regs = cpuid.query(leaf, subleaf);
    shell.console.put(.{ "CPUID ", leaf, ":", subleaf, " -> eax=", regs.eax, " ebx=", regs.ebx, " ecx=", regs.ecx, " edx=", regs.edx, "\n" });
}

fn printUsage(shell: *Shell, name: []const u8) void {
    if (findCommand(name)) |command| {
        shell.console.puts("Usage: ");
        shell.console.puts(command.name);
        if (std.mem.eql(u8, command.name, "write")) {
            shell.console.puts(" <name>");
        } else if (std.mem.eql(u8, command.name, "rm")) {
            shell.console.puts(" <name>");
        } else if (std.mem.eql(u8, command.name, "mv")) {
            shell.console.puts(" <old> <new>");
        } else if (std.mem.eql(u8, command.name, "cpuid")) {
            shell.console.puts(" [<leaf> [<subleaf>]]");
        } else if (std.mem.eql(u8, command.name, "dumpmem")) {
            shell.console.puts(" <hex-address>");
        } else if (std.mem.eql(u8, command.name, "memstat")) {
            shell.console.puts(" (no arguments)");
        } else if (std.mem.eql(u8, command.name, "taskswitch")) {
            shell.console.puts(" (no arguments)");
        } else if (std.mem.eql(u8, command.name, "profile")) {
            shell.console.puts(" <start|stop>");
        } else if (std.mem.eql(u8, command.name, "fontbench")) {
            shell.console.puts(" <count>");
        } else if (std.mem.eql(u8, command.name, "serial")) {
            shell.console.puts(" <on|off>");
        } else if (std.mem.eql(u8, command.name, "run")) {
            shell.console.puts(" <executable> [<arg> ...]\n");
            shell.console.puts("       run <executable> [<arg> ...] > <file>\n");
            shell.console.puts("       run <executable> [<arg> ...] | [run] <executable> [<arg> ...]");
            shell.console.puts("\n");
            return;
        }
        shell.console.puts("\n");
    }
}

fn readLineInto(shell: *Shell, buf: []u8) ![]u8 {
    var rl: readline.ReadlineApp = .{ .console = shell.console };
    rl.init();
    defer rl.deinit();

    while (!rl.done) {
        keyboard.pollingLoop();
    }
    shell.console.newline();

    const line = rl.readline.result();
    if (line.len > buf.len) {
        return error.BufferTooSmall;
    }
    const copy_len = @min(line.len, buf.len);
    @memcpy(buf, line[0..copy_len]);

    return buf[0..copy_len];
}

fn listFiles(shell: *Shell, disk_fs: *fs.FileSystem, path: []const u8) !void {
    var found_any = false;
    var index: usize = 0;
    var buf: [128]u8 = undefined;

    const dir_inode = try disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, path);

    while (index < fs.DIRECTORY_ENTRY_COUNT) : (index += 1) {
        if (try disk_fs.getFileInfo(dir_inode, index)) |info| {
            found_any = true;
            const str = try std.fmt.bufPrint(&buf, " {s:<16} {s:5} {d:>7}\n", .{
                info.name[0..info.name_len],
                if (info.is_directory) "(DIR)" else ".....",
                info.size_bytes,
            });
            shell.console.puts(str);
        }
    }

    if (!found_any) {
        shell.console.puts("(empty)\n");
    }
}

fn writeFileFromConsole(
    shell: *Shell,
    alloc: std.mem.Allocator,
    disk_fs: *fs.FileSystem,
    path: []const u8,
) !void {
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(alloc);

    shell.console.puts("Enter file contents. Single '.' line saves.\n");

    while (true) {
        var buf = [1]u8{0} ** 128;
        const line = try readLineInto(shell, &buf);
        if (line.len == 1 and line[0] == '.') break;
        try contents.appendSlice(alloc, line);
        try contents.append(alloc, '\n');
    }

    try disk_fs.writeFile(path, contents.items);

    shell.console.puts("Wrote ");
    shell.console.puts(path);
    shell.console.puts(".\n");
}

fn deleteFile(shell: *Shell, disk_fs: *fs.FileSystem, name: []const u8) !void {
    try filedesc.unlinkFile(disk_fs, name);

    shell.console.puts("Deleted ");
    shell.console.puts(name);
    shell.console.puts(".\n");
}

fn renameFile(shell: *Shell, disk_fs: *fs.FileSystem, old_name: []const u8, new_name: []const u8) !void {
    try disk_fs.renameFile(old_name, new_name);

    shell.console.puts("Renamed ");
    shell.console.puts(old_name);
    shell.console.puts(" to ");
    shell.console.puts(new_name);
    shell.console.puts(".\n");
}

fn printErrorDesc(shell: *Shell, err: anyerror) void {
    shell.console.puts(kernel.getErrorDesc(err));
    shell.console.newline();
}
