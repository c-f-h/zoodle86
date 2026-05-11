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

const EscState = enum { normal, esc, csi };

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

    // ANSI escape sequence parser state
    esc_state: EscState = .normal,
    csi_private: bool = false,
    csi_params: [4]u32 = .{ 0, 0, 0, 0 },
    csi_param_count: u8 = 0,
    csi_cur: u32 = 0,

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

    /// Write bytes to the tty, interpreting ANSI escape sequences to update the console.
    pub fn write(self: *Tty, src: []const u8) usize {
        var i: usize = 0;
        while (i < src.len) {
            // Write everything up to the next escape byte in one chunk (performance)
            if (self.esc_state == .normal and src[i] != 0x1B) {
                const start = i;
                while (i < src.len and src[i] != 0x1B) : (i += 1) {}
                self.console.puts(src[start..i]);
                continue;
            }

            self.putch(src[i]);
            i += 1;
        }
        return src.len;
    }

    fn putch(self: *Tty, ch: u8) void {
        if (self.esc_state != .normal or ch == 0x1B) {
            self.processEscapeByte(ch);
            return;
        }
        self.console.putch(ch);
    }

    /// Processes one byte of an ANSI/VT100 escape sequence, updating parser state.
    fn processEscapeByte(self: *Tty, ch: u8) void {
        switch (self.esc_state) {
            .normal => {
                // ch == 0x1B (ESC) guaranteed by caller
                self.esc_state = .esc;
            },
            .esc => {
                if (ch == '[') {
                    self.esc_state = .csi;
                    self.csi_private = false;
                    self.csi_params = .{ 0, 0, 0, 0 };
                    self.csi_param_count = 0;
                    self.csi_cur = 0;
                } else {
                    self.esc_state = .normal; // unknown sequence; reset
                }
            },
            .csi => {
                if (ch >= '0' and ch <= '9') {
                    self.csi_cur = self.csi_cur * 10 + (ch - '0');
                } else if (ch == ';') {
                    if (self.csi_param_count < self.csi_params.len) {
                        self.csi_params[self.csi_param_count] = self.csi_cur;
                        self.csi_param_count += 1;
                    }
                    self.csi_cur = 0;
                } else if (ch == '?') {
                    self.csi_private = true;
                } else {
                    // Final byte: dispatch and reset
                    self.dispatchCsi(ch);
                    self.esc_state = .normal;
                    self.csi_private = false;
                }
            },
        }
    }

    /// Handles the final byte of a CSI sequence (e.g. 'H', 'l', 'h').
    fn dispatchCsi(self: *Tty, ch: u8) void {
        // Save the last accumulated parameter
        if (self.csi_param_count < self.csi_params.len) {
            self.csi_params[self.csi_param_count] = self.csi_cur;
        }
        const p0 = self.csi_params[0];
        const p1 = self.csi_params[1];
        const nparams: u32 = self.csi_param_count + 1;

        switch (ch) {
            'H', 'f' => {
                // CUP / HVP: ESC[row;colH — 1-indexed, 0 treated as 1
                const r: u32 = if (p0 > 0) p0 - 1 else 0;
                const c: u32 = if (nparams >= 2 and p1 > 0) p1 - 1 else 0;
                self.console.setCursor(r, c);
            },
            'l' => {
                // DEC private mode reset: ESC[?25l → hide cursor
                if (self.csi_private and p0 == 25) {
                    self.console.setCursorVisible(false);
                }
            },
            'h' => {
                // DEC private mode set: ESC[?25h → show cursor
                if (self.csi_private and p0 == 25) {
                    self.console.setCursorVisible(true);
                }
            },
            else => {},
        }
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
