const std = @import("std");
const sys = @import("sys.zig");
const alloc = @import("allocator.zig");
const opts = @import("opts.zig");

// PureDOOM callback-setter externs
extern fn doom_set_malloc(
    malloc_fn: ?*const fn (c_int) callconv(.c) ?*anyopaque,
    free_fn: ?*const fn (?*anyopaque) callconv(.c) void,
) void;
extern fn doom_set_file_io(
    open_fn: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    close_fn: ?*const fn (?*anyopaque) callconv(.c) void,
    read_fn: ?*const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) c_int,
    write_fn: ?*const fn (?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_int,
    seek_fn: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) c_int,
    tell_fn: ?*const fn (?*anyopaque) callconv(.c) c_int,
    eof_fn: ?*const fn (?*anyopaque) callconv(.c) c_int,
) void;
extern fn doom_set_print(print_fn: ?*const fn ([*:0]const u8) callconv(.c) void) void;
extern fn doom_set_exit(exit_fn: ?*const fn (c_int) callconv(.c) noreturn) void;
extern fn doom_set_getenv(getenv_fn: ?*const fn ([*:0]const u8) callconv(.c) ?[*:0]u8) void;
extern fn doom_set_gettime(gettime_fn: ?*const fn ([*]c_int, [*]c_int) callconv(.c) void) void;
extern fn doom_set_default_int(name: [*:0]const u8, value: c_int) void;

extern fn doom_init(argc: c_int, argv: ?[*]?[*:0]u8, flags: c_int) void;
extern fn doom_update() void;
extern fn doom_get_framebuffer(channels: c_int) [*]const u8;
extern fn doom_key_down(key: c_int) void;
extern fn doom_key_up(key: c_int) void;

// --- malloc / free (size-header backed by userspace BrkAllocator) ---

const MallocHeader = packed struct {
    size: u32,
};

var gpa = alloc.BrkAllocator.init();

fn doom_malloc(size: c_int) callconv(.c) ?*anyopaque {
    if (size <= 0) return null;
    const user_size: usize = @intCast(size);
    const total = user_size + @sizeOf(MallocHeader);

    const mem = gpa.allocator().alignedAlloc(
        u8,
        std.mem.Alignment.@"4",
        total,
    ) catch return null;
    const header: *MallocHeader = @ptrCast(@alignCast(mem));
    header.size = @intCast(total);
    return @ptrFromInt(@intFromPtr(header) + @sizeOf(MallocHeader));
}

fn doom_free(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const header_ptr = @as([*]u8, @ptrCast(p)) - @sizeOf(MallocHeader);
    const header: *MallocHeader = @ptrCast(@alignCast(header_ptr));
    const total = header.size;
    gpa.allocator().free(header_ptr[0..total]);
}

// --- File I/O ---

fn modeToFlags(mode: [*:0]const u8) sys.FileOpenFlags {
    var flags: sys.FileOpenFlags = .{};
    switch (mode[0]) {
        'r' => flags.open_mode = .ReadOnly,
        'w' => {
            flags.open_mode = .WriteOnly;
            flags.create = true;
            flags.truncate = true;
        },
        'a' => {
            flags.open_mode = .WriteOnly;
            flags.create = true;
            flags.append = true;
        },
        else => return flags,
    }
    var i: usize = 1;
    while (mode[i] != 0) : (i += 1) {
        if (mode[i] == '+') flags.open_mode = .ReadWrite;
    }
    return flags;
}

fn doom_open(filename: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    const path = std.mem.sliceTo(filename, 0);
    const flags = modeToFlags(mode);
    const fd = sys.open(path, flags) catch return null;
    return @ptrFromInt(fd);
}

fn doom_close(handle: ?*anyopaque) callconv(.c) void {
    sys.close(@intFromPtr(handle)) catch {};
}

fn doom_read(handle: ?*anyopaque, buf: ?*anyopaque, count: c_int) callconv(.c) c_int {
    const fd: u32 = @intFromPtr(handle);
    const dest = @as([*]u8, @ptrCast(buf orelse return -1))[0..@intCast(count)];
    const n = sys.read(fd, dest) catch return -1;
    return @intCast(n);
}

fn doom_write(handle: ?*anyopaque, buf: ?*const anyopaque, count: c_int) callconv(.c) c_int {
    const fd: u32 = @intFromPtr(handle);
    const src = @as([*]const u8, @ptrCast(buf orelse return -1))[0..@intCast(count)];
    const n = sys.write(fd, src) catch return -1;
    return @intCast(n);
}

fn doom_seek(handle: ?*anyopaque, offset: c_int, origin: c_int) callconv(.c) c_int {
    const fd: u32 = @intFromPtr(handle);
    const whence: sys.SeekWhence = switch (origin) {
        0 => .Set,
        1 => .Cur,
        2 => .End,
        else => return -1,
    };
    _ = sys.lseek(fd, offset, whence) catch return -1;
    return 0;
}

fn doom_tell(handle: ?*anyopaque) callconv(.c) c_int {
    const fd: u32 = @intFromPtr(handle);
    const pos = sys.lseek(fd, 0, .Cur) catch return -1;
    return @intCast(pos);
}

fn doom_eof(handle: ?*anyopaque) callconv(.c) c_int {
    const fd: u32 = @intFromPtr(handle);
    const cur = sys.lseek(fd, 0, .Cur) catch return 1;
    const size = sys.lseek(fd, 0, .End) catch return 1;
    _ = sys.lseek(fd, @as(i32, @intCast(cur)), .Set) catch {};
    return if (cur >= size) 1 else 0;
}

// --- Print ---

fn doom_print(str: [*:0]const u8) callconv(.c) void {
    _ = sys.write(sys.STDOUT, std.mem.sliceTo(str, 0)) catch {};
}

// --- Exit ---

fn doom_exit(code: c_int) callconv(.c) noreturn {
    sys.exit(@intCast(code));
}

// --- getenv ---

var env_root = [_]u8{ '/', 0 };

fn doom_getenv(_: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    return @ptrCast(&env_root);
}

const doom_w = 320;
const doom_h = 200;

fn blitFrame(fd: u32, info: *const sys.FrameBufInfo, doom_fb: [*]const u8, scale: u32) void {
    const bpp = info.bytes_per_pixel;
    if (bpp != 2) @panic("Only 16 bit blitting implemented!");

    const out_row_len = doom_w * scale * bpp;
    var row_buf: [4096]u8 align(2) = undefined;
    if (doom_w * scale * bpp > row_buf.len) @panic("Scaling factor too high for row buffer!");

    var src = doom_fb;

    var y: u32 = 0;
    while (y < doom_h) : (y += 1) {
        var src_x: u32 = 0;
        var dst: [*]u16 = @ptrCast(&row_buf);
        while (src_x < doom_w) : (src_x += 1) {
            const pixel: u16 = @truncate(info.packRgb(src[0], src[1], src[2]));
            src += 3;

            var i: u32 = 0;
            while (i < scale) : (i += 1) {
                dst[0] = pixel;
                dst += 1;
            }
        }
        var rep: u32 = 0;
        while (rep < scale) : (rep += 1) {
            _ = sys.lseek(fd, @intCast((y * scale + rep) * info.pitch_bytes), .Set) catch return;
            _ = sys.write(fd, row_buf[0..out_row_len]) catch return;
        }
    }
}

fn doom_gettime(sec: [*]c_int, usec: [*]c_int) callconv(.c) void {
    const clock = sys.getClock(.Monotonic) catch unreachable;
    sec[0] = @intCast(clock.secs);
    usec[0] = @intCast(clock.nsecs / 1000);
}

/// Map a zoodle86 VK scancode to a DOOM key code (physical-key based, ignoring shift).
fn vkToDoomKey(keycode: u16) c_int {
    return switch (keycode) {
        // Number row (PS/2 scancodes 0x02-0x0B)
        0x02 => '1',
        0x03 => '2',
        0x04 => '3',
        0x05 => '4',
        0x06 => '5',
        0x07 => '6',
        0x08 => '7',
        0x09 => '8',
        0x0A => '9',
        0x0B => '0',

        // Top-row symbols
        0x0C => '-',
        0x0D => '=',

        // Letters (Q–P on the top letter row)
        0x10 => 'q',
        0x11 => 'w',
        0x12 => 'e',
        0x13 => 'r',
        0x14 => 't',
        0x15 => 'y',
        0x16 => 'u',
        0x17 => 'i',
        0x18 => 'o',
        0x19 => 'p',

        // Brackets
        0x1A => '[',
        0x1B => ']',

        // Letters (A–L)
        0x1E => 'a',
        0x1F => 's',
        0x20 => 'd',
        0x21 => 'f',
        0x22 => 'g',
        0x23 => 'h',
        0x24 => 'j',
        0x25 => 'k',
        0x26 => 'l',

        // Mid-row punctuation
        0x27 => ';',
        0x28 => '\'',

        // Letters (Z–M)
        0x2C => 'z',
        0x2D => 'x',
        0x2E => 'c',
        0x2F => 'v',
        0x30 => 'b',
        0x31 => 'n',
        0x32 => 'm',

        // Bottom-row punctuation
        0x33 => ',',
        0x34 => '.',
        0x35 => '/',

        // DOOM special keys
        sys.VK_ESC => 27, // DOOM_KEY_ESCAPE
        sys.VK_TAB => 9, // DOOM_KEY_TAB
        sys.VK_ENTER => 13, // DOOM_KEY_ENTER
        sys.VK_SPACE => ' ',
        sys.VK_BACKSPACE => 127, // DOOM_KEY_BACKSPACE
        sys.VK_LCTRL, sys.VK_RCTRL => 0x9D, // DOOM_KEY_CTRL
        sys.VK_LSHIFT, sys.VK_RSHIFT => 0xB6, // DOOM_KEY_SHIFT
        sys.VK_LALT, sys.VK_RALT => 0xB8, // DOOM_KEY_ALT
        sys.VK_UP => 0xAD,
        sys.VK_DOWN => 0xAF,
        sys.VK_LEFT => 0xAC,
        sys.VK_RIGHT => 0xAE,

        else => -1, // DOOM_KEY_UNKNOWN
    };
}

pub fn main(argv: []const []const u8) !void {
    doom_set_malloc(doom_malloc, doom_free);
    doom_set_file_io(doom_open, doom_close, doom_read, doom_write, doom_seek, doom_tell, doom_eof);
    doom_set_print(doom_print);
    doom_set_exit(doom_exit);
    doom_set_getenv(doom_getenv);
    doom_set_gettime(doom_gettime);

    // --- Parse options ---
    var scale: u32 = 0;
    _ = try opts.parseOpts(argv, &.{
        .{ .long = "scale", .result = .{ .UInt32 = &scale } },
    });

    // --- Set up default key bindings (modern WASD layout) ---
    doom_set_default_int("key_up", vkToDoomKey(sys.VK_W));
    doom_set_default_int("key_down", vkToDoomKey(sys.VK_S));
    doom_set_default_int("key_strafeleft", vkToDoomKey(sys.VK_A));
    doom_set_default_int("key_straferight", vkToDoomKey(sys.VK_D));
    doom_set_default_int("key_use", vkToDoomKey(sys.VK_E));

    // --- Open framebuffer ---
    var fb_info: sys.FrameBufInfo = .{};
    const fb_fd = try sys.open("/dev/fb0", .{ .open_mode = .ReadWrite });
    try sys.getFrameBufInfo(fb_fd, &fb_info);

    if (scale == 0) {
        // Autoscale to size of framebuffer
        scale = @max(1, @min(fb_info.width / doom_w, fb_info.height / doom_h));
    }

    // --- Switch stdin to raw mode for keyboard events ---
    const original_tty_mode = try sys.ioctl(sys.STDIN, sys.IOCTL_TTY_SET_MODE, sys.TTY_MODE_RAW);
    defer _ = sys.ioctl(sys.STDIN, sys.IOCTL_TTY_SET_MODE, original_tty_mode) catch {};

    doom_init(0, null, 0);
    while (true) {
        // Drain pending key events (non-blocking via poll)
        while (true) {
            var poll_fds = [_]sys.PollFd{
                .{ .fd = sys.STDIN, .events = sys.POLLIN, .revents = 0 },
            };
            const ready = sys.poll(&poll_fds, 0) catch |e| switch (e) {
                error.EAGAIN => continue,
                else => break,
            };
            if (ready == 0 or (poll_fds[0].revents & sys.POLLIN) == 0) break;

            var key_buf: [@sizeOf(sys.KeyEvent)]u8 = undefined;
            const n = sys.read(sys.STDIN, &key_buf) catch break;
            if (n != key_buf.len) break;
            const ev: sys.KeyEvent = @bitCast(key_buf);
            const doom_key = vkToDoomKey(ev.keycode);
            if (doom_key < 0) continue;
            if ((ev.modifiers & sys.KEY_RELEASED) != 0) {
                doom_key_up(doom_key);
            } else {
                doom_key_down(doom_key);
            }
        }

        doom_update();
        blitFrame(fb_fd, &fb_info, doom_get_framebuffer(3), scale);
    }
}

/// Provides the C `strlen` symbol (may be referenced by compiler builtins).
pub export fn strlen(str: [*:0]const u8) usize {
    var len: usize = 0;
    while (str[len] != 0) len += 1;
    return len;
}

comptime {
    _ = sys._start;
}
