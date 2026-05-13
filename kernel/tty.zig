const abi = @import("abi");
const char_device = @import("char_device.zig");
const console = @import("console.zig");
const ansi = @import("ansi.zig");
const kernel = @import("kernel.zig");
const keyboard = @import("keyboard.zig");
const ringbuf = @import("ringbuf.zig");
const task = @import("task.zig");
const waitqueue = @import("waitqueue.zig");
const std = @import("std");
const CharDevice = char_device.CharDevice;

pub const CANON_LINE_MAX = 256;
const COOKED_BUF_SIZE = 4096;

/// Tty operating mode.
pub const Mode = enum {
    canonical,
    raw,
};

const CursorPos = struct {
    row: u32,
    col: u32,
};

/// A tty bound to one console, operating in canonical or raw mode.
pub const Tty = struct {
    char_dev: CharDevice = undefined,
    // Whether this tty is initialized and can be used
    available: bool = false,
    // Operating mode - buffered line editing or raw key events
    mode: Mode = .canonical,
    // The console this tty instance is bound to
    console: *console.Console,
    // Processed data waiting for a reader (canonical) or raw abi.KeyEvent bytes (raw)
    cooked: ringbuf.RingBuf = undefined,
    // Tasks waiting for data to become available
    read_waiters: waitqueue.WaitQueue = undefined,
    // Whether the next read should return EOF with length 0
    eof_pending: bool = false,
    // Buffer for the line currently being edited, before it's committed to `cooked`
    line_buf: [CANON_LINE_MAX]u8 = undefined,
    // Length of the current line in `line_buf`
    line_len: usize = 0,
    // Stores the screen position directly after typing each individual character in line_buf
    echo_positions: [CANON_LINE_MAX + 1]CursorPos = undefined,
    // ANSI sequence parser
    ansi: ansi.Ansi = undefined,

    const vtable = CharDevice.VTable{
        .read = charDeviceRead,
        .write = charDeviceWrite,
        .ioctl = charDeviceIoctl,
        .bufferSize = charDeviceBufferSize,
        .size = charDeviceSize,
        .seekable = charDeviceSeekable,
    };

    /// Initialize a tty for the given console.
    pub fn init(self: *Tty, allocator: std.mem.Allocator, con: *console.Console, device_minor: u8) !void {
        self.* = .{
            .char_dev = .{
                .vtable = &vtable,
                .device = .{ .major = abi.DeviceMajor.Tty, .minor = device_minor },
            },
            .console = con,
            .cooked = try ringbuf.RingBuf.init(allocator, COOKED_BUF_SIZE),
            .read_waiters = waitqueue.WaitQueue.init(allocator),
            .available = true,
        };
        self.echo_positions[0] = self.cursorPos();
        self.ansi = ansi.Ansi{
            .console = con,
        };
    }

    /// Release the buffer.
    pub fn deinit(self: *Tty, allocator: std.mem.Allocator) void {
        if (!self.available) return;
        self.cooked.deinit(allocator);
        self.available = false;
    }

    /// Read bytes from the tty, blocking until data is available.
    pub fn read(self: *Tty, dest: []u8) error{OutOfMemory}!usize {
        while (true) {
            switch (self.mode) {
                .canonical => {
                    if (self.eof_pending and self.cooked.empty()) {
                        self.eof_pending = false;
                        return 0;
                    }
                    if (!self.cooked.empty()) {
                        return self.cooked.read(dest);
                    }
                },
                .raw => {
                    if (!self.cooked.empty()) {
                        return self.cooked.read(dest);
                    }
                },
            }
            // No data available; show cursor and wait for user input
            self.console.setCursorVisible(true);
            try task.getCurrentTask().waitInQueue(&self.read_waiters);
            _ = kernel.kernel_yield();
        }
    }

    /// Write bytes to the tty, interpreting ANSI escape sequences to update the console.
    pub fn write(self: *Tty, src: []const u8) usize {
        return self.ansi.puts(src);
    }

    /// Return the cooked-buffer capacity used for stat metadata.
    pub fn bufferSize(self: *const Tty) usize {
        return self.cooked.buf.len;
    }

    /// Returns the generic character-device interface for this tty.
    pub fn charDevice(self: *Tty) *CharDevice {
        return &self.char_dev;
    }

    /// Consume one key event according to the current mode.
    pub fn handleKeyEvent(self: *Tty, ev: *const keyboard.KeyEvent) void {
        switch (self.mode) {
            .raw => {
                if (ev.pressed == 0) return;
                const key_event = abi.KeyEvent{
                    .keycode = ev.keycode,
                    .modifiers = ev.modifiers,
                    .ascii = ev.ascii,
                };
                if (self.cooked.bytesFree() < @sizeOf(abi.KeyEvent)) return;
                _ = self.cooked.write(std.mem.asBytes(&key_event));
                _ = self.read_waiters.wakeOne(0);
            },
            .canonical => {
                if (ev.pressed == 0) return;

                if ((ev.modifiers & keyboard.MOD_CTRL) != 0 and ev.keycode == keyboard.VK_D) {
                    if (self.line_len == 0) {
                        self.eof_pending = true;
                        _ = self.read_waiters.wakeOne(0);
                    } else {
                        self.commitLine(false);
                    }
                    return;
                }

                switch (ev.keycode) {
                    keyboard.VK_ENTER => {
                        self.echoNewline();
                        self.commitLine(true);
                        self.console.setCursorVisible(false);
                    },
                    keyboard.VK_BACKSPACE => self.handleBackspace(),
                    else => {
                        if (ev.ascii >= 0x20 and ev.ascii < 0x7F) {
                            self.handlePrintable(ev.ascii);
                        }
                    },
                }
            },
        }
    }

    /// Switch between canonical and raw mode, discarding buffered contents only when the mode changes.
    pub fn switchMode(self: *Tty, mode: Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        self.cooked.clear();
        self.line_len = 0;
        self.eof_pending = false;
    }

    /// Handles tty-specific ioctl commands and returns the previous tty mode for mode switches.
    pub fn ioctl(self: *Tty, command: u32, arg: u32) error{InvalidArgument}!u32 {
        if ((command >> 24) != @as(u32, @intFromEnum(abi.DeviceMajor.Tty))) return error.InvalidArgument;
        switch (command) {
            abi.IOCTL_TTY_SET_MODE => {
                const original_mode = self.mode;
                self.switchMode(switch (arg) {
                    abi.TTY_MODE_CANONICAL => Mode.canonical,
                    abi.TTY_MODE_RAW => Mode.raw,
                    else => return error.InvalidArgument,
                });
                return modeToAbi(original_mode);
            },
            else => return error.InvalidArgument,
        }
    }

    fn modeToAbi(mode: Mode) u32 {
        return switch (mode) {
            .canonical => abi.TTY_MODE_CANONICAL,
            .raw => abi.TTY_MODE_RAW,
        };
    }

    fn charDeviceRead(dev: *CharDevice, offset: u32, dest: []u8) char_device.CharDeviceError!usize {
        const self: *Tty = @fieldParentPtr("char_dev", dev);
        if (offset != 0) return error.InvalidSeek;
        return self.read(dest);
    }

    fn charDeviceWrite(dev: *CharDevice, offset: u32, src: []const u8) char_device.CharDeviceError!usize {
        const self: *Tty = @fieldParentPtr("char_dev", dev);
        if (offset != 0) return error.InvalidSeek;
        return self.write(src);
    }

    fn charDeviceIoctl(dev: *CharDevice, command: u32, arg: u32) char_device.CharDeviceError!u32 {
        const self: *Tty = @fieldParentPtr("char_dev", dev);
        return self.ioctl(command, arg);
    }

    fn charDeviceBufferSize(dev: *const CharDevice) usize {
        const self: *const Tty = @fieldParentPtr("char_dev", dev);
        return self.bufferSize();
    }

    fn charDeviceSize(_: *const CharDevice) u32 {
        return 0;
    }

    fn charDeviceSeekable(_: *const CharDevice) bool {
        return false;
    }

    fn handlePrintable(self: *Tty, ch: u8) void {
        if (self.line_len >= CANON_LINE_MAX) return;
        if (self.line_len == 0) {
            self.echo_positions[0] = self.cursorPos();
        }

        self.line_buf[self.line_len] = ch;
        self.line_len += 1;
        self.console.putch(ch);
        self.echo_positions[self.line_len] = self.cursorPos();
    }

    fn handleBackspace(self: *Tty) void {
        if (self.line_len == 0) return;

        self.line_len -= 1;
        // Find cursor position after the previous character
        const pos = self.echo_positions[self.line_len];
        self.console.putCharAt(pos.row, pos.col, ' ', self.console.attr);
        self.console.setCursor(pos.row, pos.col);
    }

    fn echoNewline(self: *Tty) void {
        self.console.newline();
    }

    fn commitLine(self: *Tty, include_newline: bool) void {
        if (self.line_len != 0) {
            _ = self.cooked.write(self.line_buf[0..self.line_len]);
            self.line_len = 0;
        }
        if (include_newline) {
            _ = self.cooked.write("\n");
        }
        self.echo_positions[0] = self.cursorPos();
        _ = self.read_waiters.wakeOne(0);
    }

    fn cursorPos(self: *const Tty) CursorPos {
        const row, const col = self.console.getCursorPos();
        return .{ .row = row, .col = col };
    }
};
