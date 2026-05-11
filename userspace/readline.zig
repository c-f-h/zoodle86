/// Userspace readline: interactive line editor using ANSI escape sequences for output
/// and binary KeyEvent structs from /dev/keyboard for input.
///
/// Usage:
///   var rl = readline.Readline{};
///   rl.init(prompt);
///   const line = rl.readLine();  // blocks; returns committed slice or null on Ctrl-D empty
const sys = @import("sys.zig");

/// Maximum line length accepted by the editor.
pub const MAX_LINE = 256;

pub const Readline = struct {
    buf: [MAX_LINE]u8 = undefined,
    len: u32 = 0,
    cursor: u32 = 0,
    rendered_len: u32 = 0,
    prompt: []const u8 = "",
    row: u32 = 0, // console row where editing takes place
    col: u32 = 0, // console column right after the prompt

    /// Prepare the readline state, print the prompt, and record the cursor anchor.
    pub fn init(self: *Readline, prompt: []const u8) void {
        self.len = 0;
        self.cursor = 0;
        self.rendered_len = 0;
        self.prompt = prompt;
        _ = sys.write(sys.STDOUT, prompt) catch {};
        const pos = sys.getCursor();
        self.row = pos.row;
        self.col = pos.col;
        self.redraw();
    }

    /// Block until the user commits a line (Enter) and return the committed slice.
    /// Returns null when the user presses Ctrl-D on an empty line (EOF signal).
    pub fn readLine(self: *Readline) (sys.SyscallError || error{EOF})![]const u8 {
        // Switch tty to raw mode to get raw key events and disable echo
        _ = try sys.ioctl(sys.STDIN, sys.IOCTL_TTY_SET_MODE, sys.TTY_MODE_RAW);

        // Hide cursor and switch tty back to canonical mode when done with editing
        defer showCursor(false);
        defer _ = sys.ioctl(sys.STDIN, sys.IOCTL_TTY_SET_MODE, sys.TTY_MODE_CANONICAL) catch {};

        while (true) {
            const ev = try readKey();
            if (try self.handleKey(ev)) |done| {
                return done;
            }
        }
    }

    fn readKey() error{EOF}!sys.KeyEvent {
        var bytes: [@sizeOf(sys.KeyEvent)]u8 = undefined;
        const count = sys.read(sys.STDIN, &bytes) catch return error.EOF;
        if (count == 0) return error.EOF;
        if (count != bytes.len) return error.EOF;
        return @bitCast(bytes);
    }

    // Processes a single key event, returns non-null when a line is committed.
    fn handleKey(self: *Readline, ev: sys.KeyEvent) error{EOF}!?[]const u8 {
        const kc = ev.keycode;
        const ctrl = (ev.modifiers & sys.MOD_CTRL) != 0;

        if (ctrl) {
            switch (kc) {
                sys.VK_A => self.moveBol(), // Ctrl-A: beginning of line
                sys.VK_E => self.moveEol(), // Ctrl-E: end of line
                sys.VK_B => self.moveLeft(), // Ctrl-B: backward char
                sys.VK_F => self.moveRight(), // Ctrl-F: forward char
                sys.VK_LEFT => self.moveWordLeft(), // Ctrl-Left: previous word
                sys.VK_RIGHT => self.moveWordRight(), // Ctrl-Right: next word
                sys.VK_K => self.killToEol(), // Ctrl-K: kill to end
                sys.VK_U => self.killLine(), // Ctrl-U: kill whole line
                sys.VK_D => { // Ctrl-D: delete forward or EOF
                    if (self.len == 0) return error.EOF;
                    self.deleteForward();
                },
                else => {},
            }
            return null;
        }

        switch (kc) {
            sys.VK_ENTER => {
                // Commit the line: move cursor past the line and print newline.
                self.moveToEnd();
                _ = sys.write(sys.STDOUT, "\n") catch {};
                return self.buf[0..self.len];
            },
            sys.VK_BACKSPACE => self.deleteBackward(),
            sys.VK_DELETE => self.deleteForward(),
            sys.VK_LEFT => self.moveLeft(),
            sys.VK_RIGHT => self.moveRight(),
            sys.VK_HOME => self.moveBol(),
            sys.VK_END => self.moveEol(),
            sys.VK_UP, sys.VK_DOWN => {}, // history not implemented
            else => {
                if (ev.ascii >= 0x20 and ev.ascii < 0x7F) {
                    self.insert(ev.ascii);
                }
            },
        }
        return null;
    }

    fn insert(self: *Readline, ch: u8) void {
        if (self.len >= MAX_LINE) return;
        const redraw_start = self.cursor;
        // Shift tail rightward to make room
        var i = self.len;
        while (i > self.cursor) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
        self.redrawFrom(redraw_start);
    }

    fn deleteBackward(self: *Readline) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        const redraw_start = self.cursor;
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
        self.redrawFrom(redraw_start);
    }

    fn deleteForward(self: *Readline) void {
        if (self.cursor >= self.len) return;
        const redraw_start = self.cursor;
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
        self.redrawFrom(redraw_start);
    }

    fn killToEol(self: *Readline) void {
        const redraw_start = self.cursor;
        self.len = self.cursor;
        self.redrawFrom(redraw_start);
    }

    fn killLine(self: *Readline) void {
        const redraw_start = if (self.cursor < self.len) self.cursor else self.len;
        self.cursor = 0;
        self.len = 0;
        self.redrawFrom(redraw_start);
    }

    fn moveLeft(self: *Readline) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        self.syncCursorOnly();
    }

    fn moveRight(self: *Readline) void {
        if (self.cursor >= self.len) return;
        self.cursor += 1;
        self.syncCursorOnly();
    }

    fn isWordChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_';
    }

    fn moveWordLeft(self: *Readline) void {
        if (self.cursor == 0) return;

        self.cursor -= 1;
        while (self.cursor > 0 and !isWordChar(self.buf[self.cursor])) {
            self.cursor -= 1;
        }
        while (self.cursor > 0 and isWordChar(self.buf[self.cursor - 1])) {
            self.cursor -= 1;
        }
        self.syncCursorOnly();
    }

    fn moveWordRight(self: *Readline) void {
        if (self.cursor >= self.len) return;

        while (self.cursor < self.len and isWordChar(self.buf[self.cursor])) {
            self.cursor += 1;
        }
        while (self.cursor < self.len and !isWordChar(self.buf[self.cursor])) {
            self.cursor += 1;
        }
        self.syncCursorOnly();
    }

    fn moveBol(self: *Readline) void {
        self.cursor = 0;
        self.syncCursorOnly();
    }

    fn moveEol(self: *Readline) void {
        self.cursor = self.len;
        self.syncCursorOnly();
    }

    /// Move the terminal cursor to just past the last character (used before printing newline).
    fn moveToEnd(self: *Readline) void {
        self.cursor = self.len;
        self.syncCursorOnly();
    }

    // Rebuilds the full editing row on screen without any flicker.
    fn redraw(self: *Readline) void {
        self.redrawFrom(0);
    }

    // Rewrites only the changed suffix of the editing row and then restores the cursor.
    fn redrawFrom(self: *Readline, start: u32) void {
        const redraw_start = @min(start, self.len);
        const old_rendered_len = self.rendered_len;
        // Build the full ANSI redraw sequence into a stack buffer to issue a single write.
        var out: [16 + (MAX_LINE * 2) + 32]u8 = undefined;
        var pos: u32 = 0;

        // Hide cursor, move to the start of the changed region.
        pos = appendShowCursor(&out, pos, false);
        pos = appendCursorMove(&out, pos, self.row, self.col + redraw_start);

        // Rewrite only the changed suffix.
        const tail_len = self.len - redraw_start;
        @memcpy(out[pos..][0..tail_len], self.buf[redraw_start..self.len]);
        pos += tail_len;

        // Clear any stale tail from the previously rendered line.
        const trailing = old_rendered_len -| self.len;
        var i: u32 = 0;
        while (i < trailing) : (i += 1) {
            out[pos] = ' ';
            pos += 1;
        }

        // Place cursor at insertion point
        pos = appendCursorMove(&out, pos, self.row, self.col + self.cursor);

        // Show cursor
        pos = appendShowCursor(&out, pos, true);

        _ = sys.write(sys.STDOUT, out[0..pos]) catch {};
        self.rendered_len = self.len;
    }

    // Issues only a cursor-position update (no content redraw).
    fn syncCursorOnly(self: *Readline) void {
        var out: [16]u8 = undefined;
        const n = appendCursorMove(&out, 0, self.row, self.col + self.cursor);
        _ = sys.write(sys.STDOUT, out[0..n]) catch {};
    }
};

/// Appends an ANSI cursor-position sequence for (row, col) (0-indexed) to buf[pos..].
/// Returns the new position after the written bytes.
fn appendCursorMove(buf: []u8, pos: u32, row: u32, col: u32) u32 {
    var p = pos;
    buf[p] = 0x1B;
    p += 1;
    buf[p] = '[';
    p += 1;
    p = appendDecU32(buf, p, row + 1);
    buf[p] = ';';
    p += 1;
    p = appendDecU32(buf, p, col + 1);
    buf[p] = 'H';
    p += 1;
    return p;
}

const esc_show_cursor = "\x1B[?25h";
const esc_hide_cursor = "\x1B[?25l";

fn appendShowCursor(buf: []u8, pos: u32, show: bool) u32 {
    const seq = if (show) esc_show_cursor else esc_hide_cursor;
    @memcpy(buf[pos..][0..seq.len], seq);
    return pos + seq.len;
}

pub fn showCursor(show: bool) void {
    _ = sys.write(sys.STDOUT, if (show) esc_show_cursor else esc_hide_cursor) catch {};
}

fn appendDecU32(buf: []u8, pos: u32, value: u32) u32 {
    var tmp: [10]u8 = undefined;
    var v = value;
    var digits: u32 = 0;
    while (true) {
        tmp[digits] = @truncate('0' + (v % 10));
        digits += 1;
        v /= 10;
        if (v == 0) break;
    }
    // tmp holds digits in reverse order - copy in reverse order to output
    var p = pos;
    var i = digits;
    while (i > 0) {
        i -= 1;
        buf[p] = tmp[i];
        p += 1;
    }
    return p;
}
