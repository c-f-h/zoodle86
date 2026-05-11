const console = @import("console.zig");

const EscState = enum { normal, esc, csi };

pub const Ansi = struct {
    // ANSI escape sequence parser state
    esc_state: EscState = .normal,
    csi_private: bool = false,
    csi_params: [4]u32 = .{ 0, 0, 0, 0 },
    csi_param_count: u8 = 0,
    csi_cur: u32 = 0,
    console: *console.Console,

    /// Write bytes to the tty, interpreting ANSI escape sequences to update the console.
    pub fn puts(self: *Ansi, src: []const u8) usize {
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

    fn putch(self: *Ansi, ch: u8) void {
        if (self.esc_state != .normal or ch == 0x1B) {
            self.processEscapeByte(ch);
            return;
        }
        self.console.putch(ch);
    }

    /// Processes one byte of an ANSI/VT100 escape sequence, updating parser state.
    fn processEscapeByte(self: *Ansi, ch: u8) void {
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
    fn dispatchCsi(self: *Ansi, ch: u8) void {
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
};
