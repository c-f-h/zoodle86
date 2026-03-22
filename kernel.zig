const console = @import("console.zig");
const readline = @import("readline.zig");
const keyboard = @import("keyboard.zig");
const app_keylog = @import("app_keylog.zig");
const app = @import("app.zig");
const ide = @import("ide.zig");

const std = @import("std");

const VGA_ATTR: u8 = 0x07;

// External interrupt setup from interrupts.asm
extern fn interrupts_init() void;

// Global application context
var cur_app: app.AppContext = undefined;

var alloc: std.mem.Allocator = undefined;

/// Keyboard event consumer called by interrupt handler
export fn consume_key_event(event: *const keyboard.KeyEvent) callconv(.c) void {
    if (cur_app.key_event_handler != null) {
        _ = cur_app.key_event_handler.?(event);
    }
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

    ide.selectDrive(ide.Drive.master);
    const sector_buffer = try alloc.create([512]u8);
    try ide.readSectorLba28(ide.Drive.master, 0, sector_buffer);

    console.dumpMem(@intFromPtr(sector_buffer), 16);

    //_ = app_keylog.app_keylog_init(&cur_app);
    _ = readline.app_launcher_init(&cur_app, 1);

    while (true) {
        keyboard.keyboard_poll();
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
