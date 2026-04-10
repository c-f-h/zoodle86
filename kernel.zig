const console = @import("console.zig");
const readline = @import("readline.zig");
const keyboard = @import("keyboard.zig");
const app_keylog = @import("app_keylog.zig");
const app = @import("app.zig");
const ide = @import("ide.zig");
const fs = @import("fs.zig");
const io = @import("io.zig");
const gdt = @import("gdt.zig");

const std = @import("std");

const VGA_ATTR: u8 = 0x07;

// External interrupt setup from interrupts.asm
extern fn interrupts_init() void;

// Global application context
var cur_app: app.AppContext = undefined;

var alloc: std.mem.Allocator = undefined;
var disk_fs: fs.FileSystem = undefined;

/// Keyboard event consumer called by interrupt handler
export fn consume_key_event(event: *const keyboard.KeyEvent) void {
    if (cur_app.key_event_handler) |handler| {
        _ = handler(&cur_app, event);
    }
}

pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

const E820MemoryMapEntry = struct {
    base: u64, // 8 bytes
    length: u64, // 8 bytes
    type_: u32, // 4 bytes
    acpi_attrs: u32, // 4 bytes
};

/// Finds the largest contiguous usable memory region below 4GB using the
/// E820 memory map provided by the bootloader.
/// Panics if no suitable region of at least 8MB is found.
fn findUsableMemoryWindow() struct { u32, u32 } {
    const mem_map_address = 0x7e00;
    const num_entries = @as(*align(1) u16, @ptrFromInt(mem_map_address)).*;
    const entries = @as([*]align(1) E820MemoryMapEntry, @ptrFromInt(mem_map_address + 2))[0..num_entries];

    var largest_usable_base: u64 = 0;
    var largest_usable_length: u64 = 0;

    for (entries) |*entry| {
        if (entry.type_ == 1 and entry.base < (1 << 32)) {
            const real_usable_length = @min(entry.length, (1 << 32) - entry.base);
            // Usable RAM below 4GB
            if (real_usable_length > largest_usable_length) {
                largest_usable_base = entry.base;
                largest_usable_length = real_usable_length;
            }
        }
    }

    if (largest_usable_length < 8 * 1024 * 1024) {
        @panic("Not enough memory found: 8MB required");
    }

    return .{ @intCast(largest_usable_base), @intCast(largest_usable_length) };
}

/// Kernel entry point
export fn _start() void {
    kernel_main() catch |err| {
        @panic(switch (err) {
            error.OutOfMemory => "Out of memory",
            ide.IdeError.Timeout => "IDE timeout",
            ide.IdeError.DeviceFault => "IDE device fault",
            ide.IdeError.ControllerError => "IDE controller error",
            else => "Unknown error",
        });
    };
}

fn kernel_main() !void {
    interrupts_init();

    console.console_init(VGA_ATTR);
    console.puts(" -------- zoodle86 loaded --------\n\n");

    const mem_base, const mem_size = findUsableMemoryWindow();
    console.puts("Usable memory: base=");
    console.putHexU32(mem_base);
    console.puts(", size=");
    console.putHexU32(mem_size);
    console.newline();

    var mem_start: [*]u8 = @ptrFromInt(mem_base);
    var fba = std.heap.FixedBufferAllocator.init(mem_start[0..mem_size]);
    alloc = fba.allocator();

    gdt.set();

    try mountFs();

    while (true) {
        const cmdline = readLine();

        var tokens = std.mem.tokenizeAny(u8, cmdline, " \t");
        if (tokens.next()) |cmd| {
            if (std.mem.eql(u8, cmd, "keylog")) {
                runKeylog();
            } else if (std.mem.eql(u8, cmd, "ls")) {
                try listFiles();
            } else if (std.mem.eql(u8, cmd, "cat")) {
                if (tokens.next()) |name| {
                    try catFile(name);
                } else {
                    console.puts("Usage: cat <name>\n");
                }
            } else if (std.mem.eql(u8, cmd, "write")) {
                if (tokens.next()) |name| {
                    // TODO: fix memory handling
                    var fname_buf = [1]u8{0} ** 128;
                    const fname = fname_buf[0..name.len];
                    @memcpy(fname, name); // copy because readline() is used internally; not reentrant currently
                    try writeFileFromConsole(fname);
                } else {
                    console.puts("Usage: write <name>\n");
                }
            } else if (std.mem.eql(u8, cmd, "rm")) {
                if (tokens.next()) |name| {
                    deleteFile(name);
                } else {
                    console.puts("Usage: rm <name>\n");
                }
            } else if (std.mem.eql(u8, cmd, "mv")) {
                if (tokens.next()) |old_name| {
                    if (tokens.next()) |new_name| {
                        renameFile(old_name, new_name);
                    } else {
                        console.puts("Usage: mv <old> <new>\n");
                    }
                } else {
                    console.puts("Usage: mv <old> <new>\n");
                }
            } else if (std.mem.eql(u8, cmd, "mkfs")) {
                try disk_fs.format();
                console.puts("Filesystem reformatted.\n");
            } else if (std.mem.eql(u8, cmd, "dumpmem")) {
                if (tokens.next()) |addr_str| {
                    if (std.fmt.parseInt(u32, addr_str, 16)) |addr| {
                        console.dumpMem(addr, 16);
                    } else |_| {
                        console.puts("Enter a hex address.\n");
                    }
                } else {
                    console.puts("Usage: dumpmem <hex-address>\n");
                }
            } else if (std.mem.eql(u8, cmd, "shutdown")) {
                io.outw(0xB004, 0x2000); // Bochs specific
                io.outw(0x604, 0x2000); // QEMU specific
                // TODO: General ACPI shutdown is more involved...
            } else {
                console.puts("Unknown command ");
                console.puts(cmd);
                console.newline();
            }
        }
    }
}

fn readLine() []const u8 {
    _ = readline.initReadlineApp(&cur_app);
    while (!cur_app.done) {
        keyboard.keyboard_poll();
    }
    console.newline();
    return readline.readline.result();
}

fn mountFs() !void {
    const drive = ide.Drive.master;
    ide.selectDrive(drive);

    const drive_info = try ide.identifyDrive(drive);
    console.puts("Drive model:     ");
    console.puts(&drive_info.model);
    console.newline();
    console.puts("Drive serial:    ");
    console.puts(&drive_info.serial);
    console.newline();
    console.puts("Sectors (LBA28): ");
    console.putDecU32(drive_info.max_lba28);
    console.newline();

    disk_fs = try fs.FileSystem.mountOrFormat(drive);
}

fn runKeylog() void {
    _ = app_keylog.initKeylogApp(&cur_app);
    while (true) {
        keyboard.keyboard_poll();
    }
}

fn listFiles() !void {
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

fn catFile(name: []const u8) !void {
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

fn writeFileFromConsole(name: []const u8) !void {
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(alloc);

    console.puts("Enter file contents. Single '.' line saves.\n");

    while (true) {
        const line = readLine();
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

fn deleteFile(name: []const u8) void {
    disk_fs.deleteFile(name) catch |err| {
        printFsError(err);
        return;
    };

    console.puts("Deleted ");
    console.puts(name);
    console.puts(".\n");
}

fn renameFile(old_name: []const u8, new_name: []const u8) void {
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

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = trace;
    _ = return_address;
    console.setCursor(0, 0);
    console.setAttr(0x4F); // Red background, white text
    console.puts("KERNEL PANIC:\n");
    console.puts(message);
    console.puts("\nSystem halted.");
    while (true) {}
}
