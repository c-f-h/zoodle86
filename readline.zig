const c = @cImport({
    @cInclude("app.h");
    @cInclude("console.h");
    @cInclude("keyboard.h");
    @cInclude("vgatext.h");
});

const VGA_ATTR: u8 = 0x07;
const READLINE_BUF_MAX_LEN: usize = 80;

const ReadlineBuf = struct {
    buf: [READLINE_BUF_MAX_LEN]u8 = [_]u8{0} ** READLINE_BUF_MAX_LEN,
    len: usize = 0,
    cursor: usize = 0,

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

var readline: ReadlineBuf = .{};
var readline_row: u32 = 0; // in which row to draw the readline buffer

pub export fn app_launcher_keyhandler(event: [*c]const c.struct_key_event) callconv(.c) u32 {
    if (event == null) return 0;
    const ev = event[0];
    if (ev.pressed == 0) return 0;

    var redraw_all = false;
    const non_shift_mods: u8 = ev.modifiers & ~@as(u8, @intCast(c.MOD_SHIFT));

    if (non_shift_mods != 0) {
        // If any modifier except shift is pressed, we do not insert a char.
        // However, only some combinations with Ctrl actually have an effect.
        if (ev.modifiers == @as(u8, @intCast(c.MOD_CTRL))) {
            switch (ev.keycode) {
                0x1E => readline.cursor = 0, // Ctrl+A
                0x20 => readline.deleteChar(), // Ctrl+D
                0x30 => { // Ctrl+B
                    if (readline.cursor > 0) {
                        readline.cursor -= 1;
                    }
                },
                0x12 => readline.cursor = readline.len, // Ctrl+E
                0x21 => { // Ctrl+F
                    if (readline.cursor < readline.len) {
                        readline.cursor += 1;
                    }
                },
                0x25 => { // Ctrl+K
                    readline.len = readline.cursor;
                    redraw_all = true;
                },
                0x16 => { // Ctrl+U
                    if (readline.cursor > 0) {
                        const remaining = readline.len - readline.cursor;
                        var i: usize = 0;
                        while (i < remaining) : (i += 1) {
                            readline.buf[i] = readline.buf[readline.cursor + i];
                        }
                        readline.len = remaining;
                        readline.cursor = 0;
                        redraw_all = true;
                    }
                },
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
    } else if (ev.extended != 0) {
        switch (ev.keycode) {
            @as(u8, @intCast(c.ESC_HOME)) => readline.cursor = 0,
            @as(u8, @intCast(c.ESC_END)) => readline.cursor = readline.len,
            @as(u8, @intCast(c.ESC_LEFT)) => {
                if (readline.cursor > 0) {
                    readline.cursor -= 1;
                }
            },
            @as(u8, @intCast(c.ESC_RIGHT)) => {
                // NB: the cursor is allowed to go one past the current buffer
                // length, but only if there is more space to append another char
                if (readline.cursor < readline.len and readline.cursor < READLINE_BUF_MAX_LEN - 1) {
                    readline.cursor += 1;
                }
            },
            @as(u8, @intCast(c.ESC_DELETE)) => readline.deleteChar(),
            else => {},
        }
    } else {
        switch (ev.keycode) {
            @as(u8, @intCast(c.SC_BACKSPACE)) => {
                if (readline.cursor > 0) {
                    readline.cursor -= 1;
                    readline.deleteChar();
                }
            },
            else => {},
        }
    }

    var i: usize = 0;
    while (i < readline.len) : (i += 1) {
        c.vga_put_char_at(readline_row, @as(u32, @intCast(i)), readline.buf[i], VGA_ATTR);
    }
    // it's usually sufficient to blank out one char past the end of the buffer
    if (readline.len < READLINE_BUF_MAX_LEN) {
        c.vga_put_char_at(readline_row, @as(u32, @intCast(i)), ' ', VGA_ATTR);
    }
    // only if we killed a longer portion of the buffer
    if (redraw_all) {
        while (i < READLINE_BUF_MAX_LEN) : (i += 1) {
            c.vga_put_char_at(readline_row, @as(u32, @intCast(i)), ' ', VGA_ATTR);
        }
    }

    c.console_set_cursor(readline_row, @as(u32, @intCast(readline.cursor)));
    return 0;
}

pub export fn app_launcher_init(app: [*c]c.struct_app_context, row: c_int) callconv(.c) u32 {
    if (app == null) return 1;
    const app_ptr = &app[0];

    app_ptr.* = .{
        .name = "launcher",
        .key_event_handler = app_launcher_keyhandler,
    };

    readline_row = @as(u32, @intCast(row));
    readline.cursor = 0;
    readline.len = 0;
    @memset(&readline.buf, 0);

    c.console_set_cursor(readline_row, 0);

    // clear display row
    var i: usize = 0;
    while (i < READLINE_BUF_MAX_LEN) : (i += 1) {
        c.vga_put_char_at(readline_row, @as(u32, @intCast(i)), ' ', VGA_ATTR);
    }

    return 0;
}

pub fn panic(message: []const u8, trace: ?*anyopaque, return_address: ?usize) noreturn {
    _ = message;
    _ = trace;
    _ = return_address;
    while (true) {}
}
