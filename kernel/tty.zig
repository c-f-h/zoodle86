const console = @import("console.zig");
const kernel = @import("kernel.zig");
const keyboard = @import("keyboard.zig");
const ringbuf = @import("ringbuf.zig");
const task = @import("task.zig");
const waitqueue = @import("waitqueue.zig");
const std = @import("std");

pub const CANON_LINE_MAX = 256;
const COOKED_BUF_SIZE = 4096;

const CursorPos = struct {
    row: u32,
    col: u32,
};

/// A simple canonical-mode tty bound to one console.
pub const Tty = struct {
    // Whether this tty is initialized and can be used
    available: bool = false,
    // The console this tty instance is bound to
    console: *console.Console,
    // Processed data waiting for a reader
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

    /// Initialize a tty for the given console.
    pub fn init(self: *Tty, allocator: std.mem.Allocator, con: *console.Console) !void {
        self.* = .{
            .console = con,
            .cooked = try ringbuf.RingBuf.init(allocator, COOKED_BUF_SIZE),
            .read_waiters = waitqueue.WaitQueue.init(allocator),
            .available = true,
        };
        self.echo_positions[0] = self.cursorPos();
    }

    /// Release the cooked-input buffer.
    pub fn deinit(self: *Tty, allocator: std.mem.Allocator) void {
        if (!self.available) return;
        self.cooked.deinit(allocator);
        self.available = false;
    }

    /// Read cooked bytes from the tty, blocking until a committed line or EOF is available.
    pub fn read(self: *Tty, dest: []u8) error{OutOfMemory}!usize {
        while (true) {
            if (self.eof_pending and self.cooked.empty()) {
                self.eof_pending = false;
                return 0;
            }
            if (!self.cooked.empty()) {
                return self.cooked.read(dest);
            }
            try task.getCurrentTask().waitInQueue(&self.read_waiters);
            _ = kernel.kernel_yield();
        }
    }

    /// Write bytes directly to the backing console.
    pub fn write(self: *Tty, src: []const u8) usize {
        self.console.puts(src);
        return src.len;
    }

    /// Return the cooked-buffer capacity used for stat metadata.
    pub fn bufferSize(self: *const Tty) usize {
        return self.cooked.buf.len;
    }

    /// Consume one key event into canonical-mode input state.
    pub fn handleKeyEvent(self: *Tty, ev: *const keyboard.KeyEvent) void {
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
            },
            keyboard.VK_BACKSPACE => self.handleBackspace(),
            else => {
                if (ev.ascii >= 0x20 and ev.ascii < 0x7F) {
                    self.handlePrintable(ev.ascii);
                }
            },
        }
    }

    fn handlePrintable(self: *Tty, ch: u8) void {
        if (self.line_len >= CANON_LINE_MAX) return;
        if (self.line_len == 0) {
            self.echo_positions[0] = self.cursorPos();
        }

        self.line_buf[self.line_len] = ch;
        self.line_len += 1;
        self.console.puts(&[1]u8{ch});
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
