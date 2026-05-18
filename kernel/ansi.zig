const EscState = enum {
    normal,
    esc,
    csi,
};

/// Parsed CSI sequence containing the final byte and numeric parameters.
pub const Csi = struct {
    private: bool = false,
    params: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    param_count: u8 = 1,
    final: u8 = 0,

    /// Returns the number of parsed CSI parameters, treating an empty list as a single zero.
    pub fn count(self: *const Csi) usize {
        return self.param_count;
    }

    /// Returns the CSI parameter at `index`, or `fallback` when it was not present.
    pub fn param(self: *const Csi, index: usize, fallback: u32) u32 {
        if (index >= self.param_count) return fallback;
        return self.params[index];
    }
};

/// Completed ANSI escape sequence emitted by the incremental parser.
pub const Sequence = union(enum) {
    save_cursor,
    restore_cursor,
    csi: Csi,
};

/// Incremental ANSI/VT100 parser for ESC and CSI sequences.
pub const Parser = struct {
    esc_state: EscState = .normal,
    csi_private: bool = false,
    csi_params: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    csi_param_count: u8 = 0,
    csi_cur: u32 = 0,

    /// Resets the parser to its initial state, discarding any partial sequence.
    pub fn reset(self: *Parser) void {
        self.esc_state = .normal;
        self.csi_private = false;
        self.csi_params = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        self.csi_param_count = 0;
        self.csi_cur = 0;
    }

    /// Returns whether the parser is currently in the middle of an escape sequence.
    pub fn isActive(self: *const Parser) bool {
        return self.esc_state != .normal;
    }

    /// Consumes one byte and returns a completed escape sequence when one finishes.
    pub fn processByte(self: *Parser, ch: u8) ?Sequence {
        switch (self.esc_state) {
            .normal => {
                if (ch == 0x1B) {
                    self.esc_state = .esc;
                }
                return null;
            },
            .esc => switch (ch) {
                '[' => {
                    self.esc_state = .csi;
                    self.csi_private = false;
                    self.csi_params = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                    self.csi_param_count = 0;
                    self.csi_cur = 0;
                    return null;
                },
                '7' => {
                    self.reset();
                    return .save_cursor;
                },
                '8' => {
                    self.reset();
                    return .restore_cursor;
                },
                else => {
                    self.reset();
                    return null;
                },
            },
            .csi => {
                if (ch >= '0' and ch <= '9') {
                    self.csi_cur = self.csi_cur * 10 + (ch - '0');
                    return null;
                }

                if (ch == ';') {
                    if (self.csi_param_count < self.csi_params.len) {
                        self.csi_params[self.csi_param_count] = self.csi_cur;
                        self.csi_param_count += 1;
                    }
                    self.csi_cur = 0;
                    return null;
                }

                if (ch == '?') {
                    self.csi_private = true;
                    return null;
                }

                if (self.csi_param_count < self.csi_params.len) {
                    self.csi_params[self.csi_param_count] = self.csi_cur;
                }

                const seq = Sequence{
                    .csi = .{
                        .private = self.csi_private,
                        .params = self.csi_params,
                        .param_count = @intCast(@min(self.csi_param_count + 1, self.csi_params.len)),
                        .final = ch,
                    },
                };
                self.reset();
                return seq;
            },
        }
    }
};
