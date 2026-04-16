const std = @import("std");

const app_keylog = @import("app_keylog.zig");
const console = @import("console.zig");
const fs = @import("fs.zig");
const io = @import("io.zig");
const keyboard = @import("keyboard.zig");
const readline = @import("readline.zig");
const kernel = @import("kernel.zig");

const ArgsIterator = std.mem.TokenIterator(u8, .any);

const Shell = struct {
    alloc: std.mem.Allocator,
    disk_fs: *fs.FileSystem,
};

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn (*Shell, *ArgsIterator) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "help", .description = "List available commands.", .handler = cmdHelp },
    .{ .name = "keylog", .description = "Run the key event logger.", .handler = cmdKeylog },
    .{ .name = "ls", .description = "List files in the filesystem.", .handler = cmdLs },
    .{ .name = "cat", .description = "Print a file's contents.", .handler = cmdCat },
    .{ .name = "write", .description = "Write a file from console input.", .handler = cmdWrite },
    .{ .name = "rm", .description = "Delete a file.", .handler = cmdRm },
    .{ .name = "mv", .description = "Rename a file.", .handler = cmdMv },
    .{ .name = "mkfs", .description = "Reformat the filesystem.", .handler = cmdMkfs },
    .{ .name = "dumpmem", .description = "Dump memory at a hex address.", .handler = cmdDumpmem },
    .{ .name = "run", .description = "Execute an ELF binary executable.", .handler = cmdRun },
    .{ .name = "shutdown", .description = "Power off Bochs/QEMU.", .handler = cmdShutdown },
    .{ .name = "break", .description = "Invoke a Bochs magic breakpoint.", .handler = cmdDebugBreak },
};

/// Run the interactive shell command loop.
pub fn run(alloc: std.mem.Allocator, disk_fs: *fs.FileSystem) !noreturn {
    var shell = Shell{
        .alloc = alloc,
        .disk_fs = disk_fs,
    };

    while (true) {
        var cmdline_buf = [1]u8{0} ** 128;
        const cmdline = try readLineInto(&cmdline_buf);
        var args = std.mem.tokenizeAny(u8, cmdline, " \t");
        const cmd_name = args.next() orelse continue;

        if (findCommand(cmd_name)) |command| {
            try command.handler(&shell, &args);
        } else {
            console.puts("Unknown command ");
            console.puts(cmd_name);
            console.newline();
        }
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

fn cmdKeylog(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;
    _ = args;

    var app: app_keylog.Keylog = .{};
    app.init();
    defer app.deinit();

    while (true) {
        keyboard.keyboard_poll();
    }
}

fn cmdHelp(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;
    _ = args;

    for (commands) |command| {
        console.puts(command.name);
        console.puts(" - ");
        console.puts(command.description);
        console.newline();
    }
}

fn cmdLs(shell: *Shell, args: *ArgsIterator) !void {
    _ = args;
    try listFiles(shell.disk_fs);
}

fn cmdCat(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next()) |name| {
        try catFile(shell.alloc, shell.disk_fs, name);
    } else {
        printUsage("cat");
    }
}

fn cmdWrite(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next()) |name| {
        try writeFileFromConsole(shell.alloc, shell.disk_fs, name);
    } else {
        printUsage("write");
    }
}

fn cmdRm(shell: *Shell, args: *ArgsIterator) !void {
    if (args.next()) |name| {
        deleteFile(shell.disk_fs, name);
    } else {
        printUsage("rm");
    }
}

fn cmdMv(shell: *Shell, args: *ArgsIterator) !void {
    const old_name = args.next() orelse {
        printUsage("mv");
        return;
    };
    const new_name = args.next() orelse {
        printUsage("mv");
        return;
    };
    renameFile(shell.disk_fs, old_name, new_name);
}

fn cmdMkfs(shell: *Shell, args: *ArgsIterator) !void {
    _ = args;
    try shell.disk_fs.format();
    console.puts("Filesystem reformatted.\n");
}

fn cmdDumpmem(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;
    if (args.next()) |addr_str| {
        if (std.fmt.parseInt(u32, addr_str, 16)) |addr| {
            console.dumpMem(addr, 16);
        } else |_| {
            console.puts("Enter a hex address.\n");
        }
    } else {
        printUsage("dumpmem");
    }
}

fn cmdRun(shell: *Shell, args: *ArgsIterator) !void {
    _ = shell;
    if (args.next()) |fname| {
        try kernel.launchUserspaceElf(fname, &kernel.current_task);
    } else {
        console.puts("Usage: run <executable>\n");
    }
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

fn printUsage(name: []const u8) void {
    if (findCommand(name)) |command| {
        console.puts("Usage: ");
        console.puts(command.name);
        if (std.mem.eql(u8, command.name, "cat")) {
            console.puts(" <name>");
        } else if (std.mem.eql(u8, command.name, "write")) {
            console.puts(" <name>");
        } else if (std.mem.eql(u8, command.name, "rm")) {
            console.puts(" <name>");
        } else if (std.mem.eql(u8, command.name, "mv")) {
            console.puts(" <old> <new>");
        } else if (std.mem.eql(u8, command.name, "dumpmem")) {
            console.puts(" <hex-address>");
        }
        console.puts("\n");
    }
}

fn readLineInto(buf: []u8) ![]u8 {
    var rl: readline.ReadlineApp = .{};
    rl.init();
    defer rl.deinit();

    while (!rl.done) {
        keyboard.keyboard_poll();
    }
    console.newline();

    const line = rl.readline.result();
    if (line.len > buf.len) {
        return error.BufferTooSmall;
    }
    const copy_len = @min(line.len, buf.len);
    @memcpy(buf, line[0..copy_len]);

    return buf[0..copy_len];
}

fn listFiles(disk_fs: *fs.FileSystem) !void {
    var found_any = false;
    var index: usize = 1;
    while (index < fs.DIRECTORY_ENTRY_COUNT) : (index += 1) {
        if (try disk_fs.getFileInfo(index)) |info| {
            found_any = true;
            console.puts(info.name[0..info.name_len]);
            console.puts(" (");
            console.putDecU32(info.size_bytes);
            console.puts(" bytes)\n");
        }
    }

    if (!found_any) {
        console.puts("(empty)\n");
    }
}

fn catFile(alloc: std.mem.Allocator, disk_fs: *fs.FileSystem, name: []const u8) !void {
    const data = disk_fs.readFile(alloc, name) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            else => |fs_err| {
                printFsError(fs_err);
                return;
            },
        }
    };
    defer alloc.free(data);

    console.puts(data);
    if (data.len == 0 or data[data.len - 1] != '\n') {
        console.newline();
    }
}

fn writeFileFromConsole(
    alloc: std.mem.Allocator,
    disk_fs: *fs.FileSystem,
    name: []const u8,
) !void {
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(alloc);

    console.puts("Enter file contents. Single '.' line saves.\n");

    while (true) {
        var buf = [1]u8{0} ** 128;
        const line = try readLineInto(&buf);
        if (line.len == 1 and line[0] == '.') break;
        try contents.appendSlice(alloc, line);
        try contents.append(alloc, '\n');
    }

    disk_fs.writeFile(name, contents.items) catch |err| {
        printFsError(err);
        return;
    };

    console.puts("Wrote ");
    console.puts(name);
    console.puts(".\n");
}

fn deleteFile(disk_fs: *fs.FileSystem, name: []const u8) void {
    disk_fs.deleteFile(name) catch |err| {
        printFsError(err);
        return;
    };

    console.puts("Deleted ");
    console.puts(name);
    console.puts(".\n");
}

fn renameFile(disk_fs: *fs.FileSystem, old_name: []const u8, new_name: []const u8) void {
    disk_fs.renameFile(old_name, new_name) catch |err| {
        printFsError(err);
        return;
    };

    console.puts("Renamed ");
    console.puts(old_name);
    console.puts(" to ");
    console.puts(new_name);
    console.puts(".\n");
}

fn printFsError(err: fs.FsError) void {
    switch (err) {
        error.Corrupt => console.puts("Filesystem is corrupt.\n"),
        error.DirectoryFull => console.puts("Directory is full.\n"),
        error.FileExists => console.puts("File already exists.\n"),
        error.FileNotFound => console.puts("File not found.\n"),
        error.InvalidName => console.puts("Invalid filename.\n"),
        error.InvalidSuperblock => console.puts("Filesystem superblock is invalid.\n"),
        error.NoSpace => console.puts("Filesystem is out of space.\n"),
        error.Timeout => console.puts("IDE timed out.\n"),
        error.DeviceFault => console.puts("IDE device fault.\n"),
        error.ControllerError => console.puts("IDE controller error.\n"),
        error.NoDevice => console.puts("IDE device not present.\n"),
        error.NotAtaDevice => console.puts("IDE device is not ATA.\n"),
        error.InvalidLba => console.puts("Invalid disk LBA.\n"),
    }
}
