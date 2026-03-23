const app = @import("app.zig");
const keyboard = @import("keyboard.zig");
const console = @import("console.zig");
const vga = @import("vgatext.zig");

const VGA_ATTR: u8 = 0x07;
const READLINE_BUF_MAX_LEN: usize = 80;

const ReadlineBuf = struct {
    buf: [READLINE_BUF_MAX_LEN]u8 = [_]u8{0} ** READLINE_BUF_MAX_LEN,
    len: u32 = 0,
    cursor: u32 = 0,
    done: bool = false,

    pub fn result(this: *ReadlineBuf) []const u8 {
        return this.buf[0..this.len];
    }

    /// Determine if a character is part of a word (alphanumeric or underscore).
    fn isWordChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_';
    }

    /// Move cursor left by one word. Moves to the start of the current or previous word.
    fn moveWordLeft(this: *ReadlineBuf) void {
        if (this.cursor == 0) return;

        this.cursor -= 1;

        // Skip any non-word characters to the left
        while (this.cursor > 0 and !isWordChar(this.buf[this.cursor])) {
            this.cursor -= 1;
        }

        // Skip word characters to the left until we find a non-word character
        while (this.cursor > 0 and isWordChar(this.buf[this.cursor - 1])) {
            this.cursor -= 1;
        }
    }

    /// Move cursor right by one word. Moves to the start of the next word.
    fn moveWordRight(this: *ReadlineBuf) void {
        if (this.cursor >= this.len) return;

        const last_allowed = @min(this.len, READLINE_BUF_MAX_LEN - 1);

        // Skip any word characters to the right
        while (this.cursor < last_allowed and isWordChar(this.buf[this.cursor])) {
            this.cursor += 1;
        }

        // Skip non-word characters to the right until we find a word character
        while (this.cursor < last_allowed and !isWordChar(this.buf[this.cursor])) {
            this.cursor += 1;
        }
    }

    fn deleteChar(this: *ReadlineBuf) void {
        // shift all later chars forward by one
        if (this.cursor < this.len) {
            var i = this.cursor;
            while (i + 1 < this.len) : (i += 1) {
                this.buf[i] = this.buf[i + 1];
            }
            this.len -= 1;
        }
    }

    fn insertChar(this: *ReadlineBuf, ch: u8) bool {
        // shift all later chars back by one
        if (this.len < READLINE_BUF_MAX_LEN) {
            var i = this.len;
            while (i > this.cursor) : (i -= 1) {
                this.buf[i] = this.buf[i - 1];
            }
            this.len += 1;
            this.buf[this.cursor] = ch;
            return true;
        }
        // ring_bell();
        return false;
    }
};

pub var readline: ReadlineBuf = undefined;
var readline_row: u32 = 0; // in which row to draw the readline buffer

fn readlineKeyhandler(ev: *const keyboard.KeyEvent) u32 {
    if (ev.pressed == 0) return 0;

    var redraw_all = false;
    const non_shift_mods: u8 = ev.modifiers & ~@as(u8, keyboard.MOD_SHIFT);

    if (non_shift_mods != 0) {
        // If any modifier except shift is pressed, we do not insert a char.
        // However, only some combinations with Ctrl actually have an effect.
        if (ev.modifiers == keyboard.MOD_CTRL) {
            switch (ev.keycode) {
                keyboard.VK_A => readline.cursor = 0, // Ctrl+A
                keyboard.VK_D => readline.deleteChar(), // Ctrl+D
                keyboard.VK_B => { // Ctrl+B
                    if (readline.cursor > 0) {
                        readline.cursor -= 1;
                    }
                },
                keyboard.VK_E => readline.cursor = readline.len, // Ctrl+E
                keyboard.VK_F => { // Ctrl+F
                    if (readline.cursor < readline.len) {
                        readline.cursor += 1;
                    }
                },
                keyboard.VK_K => { // Ctrl+K
                    readline.len = readline.cursor;
                    redraw_all = true;
                },
                keyboard.VK_U => { // Ctrl+U
                    if (readline.cursor > 0) {
                        const remaining = readline.len - readline.cursor;
                        var i: u32 = 0;
                        while (i < remaining) : (i += 1) {
                            readline.buf[i] = readline.buf[readline.cursor + i];
                        }
                        readline.len = remaining;
                        readline.cursor = 0;
                        redraw_all = true;
                    }
                },
                keyboard.VK_LEFT => readline.moveWordLeft(), // Ctrl+Left (move word left)
                keyboard.VK_RIGHT => readline.moveWordRight(), // Ctrl+Right (move word right)
                else => {},
            }
        }
    } else if (ev.ascii != 0) {
        // make space for the new char and insert it
        if (readline.insertChar(ev.ascii)) {
            // advance cursor if there is more space
            if (readline.cursor < READLINE_BUF_MAX_LEN - 1) {
                readline.cursor += 1;
            }
            // if we inserted past the end, enlarge the buffer
            if (readline.cursor > readline.len) {
                // NB: it's valid to have cursor = len (pointing past the end)
                readline.len = readline.cursor;
            }
        }
    } else {
        switch (ev.keycode) {
            keyboard.VK_ENTER => {
                readline.done = true;
                vga.disableCursor();
            },
            keyboard.VK_HOME => readline.cursor = 0,
            keyboard.VK_END => readline.cursor = readline.len,
            keyboard.VK_LEFT => {
                if (readline.cursor > 0) {
                    readline.cursor -= 1;
                }
            },
            keyboard.VK_RIGHT => {
                // NB: the cursor is allowed to go one past the current buffer
                // length, but only if there is more space to append another char
                if (readline.cursor < readline.len and readline.cursor < READLINE_BUF_MAX_LEN - 1) {
                    readline.cursor += 1;
                }
            },
            keyboard.VK_DELETE => readline.deleteChar(),
            keyboard.VK_BACKSPACE => {
                if (readline.cursor > 0) {
                    readline.cursor -= 1;
                    readline.deleteChar();
                }
            },
            else => {},
        }
    }

    var i: u32 = 0;
    while (i < readline.len) : (i += 1) {
        vga.putCharAt(readline_row, i, readline.buf[i], VGA_ATTR);
    }
    // it's usually sufficient to blank out one char past the end of the buffer
    if (readline.len < READLINE_BUF_MAX_LEN) {
        vga.putCharAt(readline_row, i, ' ', VGA_ATTR);
    }
    // only if we killed a longer portion of the buffer
    if (redraw_all) {
        while (i < READLINE_BUF_MAX_LEN) : (i += 1) {
            vga.putCharAt(readline_row, i, ' ', VGA_ATTR);
        }
    }

    console.setCursor(readline_row, readline.cursor);
    return 0;
}

pub export fn initReadlineApp(app_ctx: *app.AppContext) u32 {
    app_ctx.* = .{
        .name = "readline",
        .key_event_handler = readlineKeyhandler,
    };

    const cpos = console.getCursorPos();
    readline_row = cpos[0];
    readline = .{};

    console.setCursor(readline_row, 0);
    vga.enableCursor();

    // clear display row
    var i: u32 = 0;
    while (i < READLINE_BUF_MAX_LEN) : (i += 1) {
        vga.putCharAt(readline_row, i, ' ', VGA_ATTR);
    }

    return 0;
}
