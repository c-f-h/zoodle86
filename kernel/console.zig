const paging = @import("paging.zig");
const serial = @import("serial.zig");
const vconsole = @import("gfx/vconsole.zig");
const vga = @import("vgatext.zig");
const mem = @import("mem.zig");

const std = @import("std");

pub const VGA_TEXT_WIDTH: u32 = vga.TEXT_WIDTH;
pub const VGA_TEXT_HEIGHT: u32 = vga.TEXT_HEIGHT;

pub const Cell = u16;

const Backend = enum {
    vga,
    buffered, // only for temporary console storage before framebuffer is initialized
    framebuf,
};

// Bootstrap buffer used by the primary console before the framebuffer is available.
var bootstrap_buffer: [VGA_TEXT_WIDTH * VGA_TEXT_HEIGHT]u16 = undefined;

inline fn makeCell(ch: u8, attr: u8) u16 {
    return (@as(u16, attr) << 8) | ch;
}

/// An independent text console that can render to VGA memory, a RAM buffer, or a VConsole window.
pub const Console = struct {
    width: u32 = VGA_TEXT_WIDTH,
    height: u32 = VGA_TEXT_HEIGHT,
    row: u32 = 0,
    col: u32 = 0,
    attr: u8 = 0x07,
    serial_mirror_enabled: bool = false,
    cursor_visible: bool = true,
    backend: Backend = .vga,
    cell_count: usize = @as(usize, VGA_TEXT_WIDTH) * @as(usize, VGA_TEXT_HEIGHT),
    cells: [*]u16 = undefined, // points to VGA memory or a cell buffer depending on backend
    cell_buffer: []Cell = &.{}, // allocated when switching to framebuf backend
    vconsole_instance: ?*vconsole.VConsole = null,

    inline fn cellIndex(self: *const Console, row: u32, col: u32) usize {
        return row * self.width + col;
    }

    /// If required by the backend, redraw the full console grid.
    pub fn refresh(self: *Console) void {
        if (self.backend == .framebuf) {
            if (self.vconsole_instance) |vc| {
                vc.render(self.cells, self.row, self.col, self.cursor_visible);
            }
        }
        // VGA backend is updated automatically by hardware when we write to video memory.
    }

    fn syncCursor(self: *Console) void {
        switch (self.backend) {
            .vga => {
                if (self.cursor_visible) {
                    vga.enableCursor();
                    vga.setCursorPos(self.row, self.col);
                } else {
                    vga.disableCursor();
                }
            },
            .buffered => {},
            .framebuf => {
                if (self.vconsole_instance) |vc| {
                    vc.setCursor(self.cells, self.row, self.col, self.cursor_visible);
                }
            },
        }
    }

    fn scrollIfNeeded(self: *Console) void {
        if (self.row < self.height) return;

        if (self.backend == .framebuf and self.cursor_visible) {
            if (self.vconsole_instance) |vc| {
                vc.setCursor(self.cells, self.row, self.col, false);
            }
        }

        // Shift all rows up by one in the console cell buffer.
        mem.copyBytesForward(
            @ptrCast(self.cells),
            @ptrCast(self.cells + self.width),
            (self.height - 1) * self.width * @sizeOf(Cell),
        );

        // Clear the new bottom row.
        var col: u32 = 0;
        while (col < self.width) : (col += 1) {
            self.cells[self.cellIndex(self.height - 1, col)] = makeCell(' ', self.attr);
        }

        self.row = self.height - 1;
        if (self.backend == .framebuf) {
            if (self.vconsole_instance) |vc| {
                vc.scroll(self.cells);
            }
        } else {
            self.refresh();
        }
    }

    fn advanceLine(self: *Console) void {
        self.col = 0;
        self.row += 1;
        self.scrollIfNeeded();
    }

    /// Initialise the console for VGA text mode output.
    pub fn init(self: *Console, attr: u8) void {
        self.backend = .vga;
        self.cells = @ptrCast(@volatileCast(vga.memory));
        self.width = VGA_TEXT_WIDTH;
        self.height = VGA_TEXT_HEIGHT;
        self.cell_count = self.width * self.height;
        self.attr = attr;
        self.row = 0;
        self.col = 0;
        self.cursor_visible = true;
        self.clearCells(attr);
    }

    pub fn clearCells(self: *Console, attr: u8) void {
        @memset(self.cells[0..self.cell_count], makeCell(' ', attr));
        self.refresh();
    }

    pub fn clear(self: *Console) void {
        self.row = 0;
        self.col = 0;
        self.clearCells(self.attr);
    }

    pub fn setCursor(self: *Console, row: u32, col: u32) void {
        self.row = if (row >= self.height) self.height - 1 else row;
        self.col = if (col >= self.width) self.width - 1 else col;
        self.syncCursor();
    }

    pub fn getCursorPos(self: *const Console) struct { u32, u32 } {
        return .{ self.row, self.col };
    }

    pub fn setAttr(self: *Console, attr: u8) void {
        self.attr = attr;
    }

    /// Show or hide the active console cursor.
    pub fn setCursorVisible(self: *Console, visible: bool) void {
        self.cursor_visible = visible;
        self.syncCursor();
    }

    /// Enable or disable mirroring console output to the serial port.
    pub fn setSerialMirrorEnabled(self: *Console, enabled: bool) void {
        self.serial_mirror_enabled = enabled;
    }

    /// Return whether console output is currently mirrored to serial.
    pub fn isSerialMirrorEnabled(self: *const Console) bool {
        return self.serial_mirror_enabled;
    }

    /// Read a raw u16 cell (attr<<8 | char) from the console grid at (row, col).
    pub fn readCell(self: *const Console, row: u32, col: u32) u16 {
        if (row >= self.height or col >= self.width) return 0;
        return self.cells[self.cellIndex(row, col)];
    }

    /// Write a single character cell directly into the console grid.
    pub fn putCharAt(self: *Console, row: u32, col: u32, ch: u8, attr: u8) void {
        if (row >= self.height or col >= self.width) return;
        self.cells[self.cellIndex(row, col)] = makeCell(ch, attr);
        if (self.backend == .framebuf) {
            if (self.vconsole_instance) |vc| {
                vc.renderCell(self.cells, row, col);
            }
        }
    }

    /// Stress text rendering by overwriting 1000 character cells per pass without advancing into scrollback.
    pub fn stressWrite(self: *Console, iterations: u32) void {
        asm volatile ("sti");

        const chars_per_pass: usize = 1000;
        const pattern = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

        const start_row = self.row;
        const start_col = self.col;
        const start_idx = self.cellIndex(start_row, start_col);
        const width: usize = @intCast(self.width);
        const was_cursor_visible = self.cursor_visible;

        if (self.cell_count == 0 or width == 0 or iterations == 0) return;

        if (was_cursor_visible) {
            self.setCursorVisible(false);
        }
        defer {
            self.row = start_row;
            self.col = start_col;
            self.setCursorVisible(was_cursor_visible);
        }

        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            var char_idx: usize = 0;
            while (char_idx < chars_per_pass) : (char_idx += 1) {
                const idx = (start_idx + char_idx) % self.cell_count;
                const row: u32 = @intCast(idx / width);
                const col: u32 = @intCast(idx % width);
                const pattern_idx = (@as(usize, i) + char_idx) % pattern.len;
                self.putCharAt(row, col, pattern[pattern_idx], self.attr);
            }
            self.setCursor(start_row, start_col);
        }
    }

    /// Switch the primary console rendering to the framebuffer text backend.
    /// Copies prior VGA cell content into the new buffer.
    pub fn enableFramebufBackend(self: *Console, allocator: std.mem.Allocator, text_width: u32, text_height: u32) !void {
        if (self.backend == .framebuf) return;
        if (text_width == 0 or text_height == 0) @panic("framebuffer console must be at least 1x1");

        const old_width = self.width;
        const old_height = self.height;
        const old_cells = self.cells;
        const new_cell_count = text_width * text_height;
        self.cell_buffer = try allocator.alloc(Cell, new_cell_count);

        @memset(self.cell_buffer, makeCell(' ', self.attr));

        const copy_rows = @min(old_height, text_height);
        const copy_cols = @min(old_width, text_width);
        var row: u32 = 0;
        while (row < copy_rows) : (row += 1) {
            var col: u32 = 0;
            while (col < copy_cols) : (col += 1) {
                const src_idx = row * old_width + col;
                const dst_idx = row * text_width + col;
                self.cell_buffer[dst_idx] = old_cells[src_idx];
            }
        }

        self.backend = .framebuf;
        vga.disableCursor();
        self.width = text_width;
        self.height = text_height;
        self.cell_count = new_cell_count;
        self.cells = self.cell_buffer.ptr;
        if (self.row >= self.height) self.row = self.height - 1;
        if (self.col >= self.width) self.col = self.width - 1;
    }

    /// Initialise as a fresh framebuffer-backed console
    pub fn initFramebuf(self: *Console, allocator: std.mem.Allocator, text_width: u32, text_height: u32) !void {
        if (text_width == 0 or text_height == 0) @panic("framebuffer console must be at least 1x1");
        const new_cell_count = text_width * text_height;
        self.cell_buffer = try allocator.alloc(Cell, new_cell_count);
        @memset(self.cell_buffer, makeCell(' ', self.attr));
        self.backend = .framebuf;
        self.width = text_width;
        self.height = text_height;
        self.cell_count = new_cell_count;
        self.cells = self.cell_buffer.ptr;
        self.row = 0;
        self.col = 0;
        self.cursor_visible = false;
    }

    pub fn deinit(self: *Console, allocator: std.mem.Allocator) void {
        if (self.backend == .framebuf and self.cell_buffer.len > 0) {
            allocator.free(self.cell_buffer);
            self.cell_buffer = &.{};
        }
    }

    /// Keep console output in RAM until the framebuffer console is ready.
    pub fn enableBufferedBackend(self: *Console) void {
        if (self.backend != .vga) return;
        @memset(bootstrap_buffer[0..], makeCell(' ', self.attr));
        self.backend = .buffered;
        self.cells = &bootstrap_buffer;
    }

    fn newlineInternal(self: *Console, sync_cursor: bool) void {
        if (self.serial_mirror_enabled and serial.isInitialized()) {
            serial.putch('\n');
        }
        self.advanceLine();
        if (sync_cursor) self.syncCursor();
    }

    pub fn newline(self: *Console) void {
        self.newlineInternal(true);
    }

    fn putchInternal(self: *Console, ch: u8, sync_cursor: bool) void {
        switch (ch) {
            '\n' => {
                self.newlineInternal(sync_cursor);
                return;
            },
            '\r' => {
                if (self.serial_mirror_enabled and serial.isInitialized()) {
                    serial.putch(ch);
                }
                self.col = 0;
                if (sync_cursor) self.syncCursor();
                return;
            },
            else => {},
        }

        if (self.serial_mirror_enabled and serial.isInitialized()) {
            serial.putch(ch);
        }
        self.putCharAt(self.row, self.col, ch, self.attr);
        self.col += 1;
        if (self.col >= self.width) {
            self.advanceLine();
        }
        if (sync_cursor) self.syncCursor();
    }

    pub fn putch(self: *Console, ch: u8) void {
        self.putchInternal(ch, true);
    }

    pub fn puts(self: *Console, s: []const u8) void {
        if (self.backend == .framebuf and self.cursor_visible and s.len > 1) {
            self.cursor_visible = false;
            self.syncCursor();
            defer {
                self.cursor_visible = true;
                self.syncCursor();
            }
            for (s) |ch| {
                self.putchInternal(ch, false);
            }
            return;
        }
        for (s) |ch| {
            self.putchInternal(ch, true);
        }
    }

    pub fn formatHexU(comptime bytes: u8, value: @Int(.unsigned, 8 * bytes), out: *[2 * bytes]u8) void {
        const hex = "0123456789ABCDEF";
        var shift: i8 = 8 * bytes - 4;
        var ofs: u8 = 0;
        while (shift >= 0) : (shift -= 4) {
            out.*[ofs] = hex[(value >> @intCast(shift)) & 0x0F];
            ofs += 1;
        }
    }

    pub fn putHexU8(self: *Console, value: u8) void {
        const hex = "0123456789ABCDEF";
        self.putch(hex[(value >> 4) & 0x0F]);
        self.putch(hex[value & 0x0F]);
    }

    pub fn putHexU16(self: *Console, value: u16) void {
        var str: [4]u8 = undefined;
        Console.formatHexU(2, value, &str);
        self.puts(&str);
    }

    pub fn putHexU32(self: *Console, value: u32) void {
        var str: [8]u8 = undefined;
        Console.formatHexU(4, value, &str);
        self.puts(&str);
    }

    pub fn putHexU64(self: *Console, value: u64) void {
        // Split u64 into two u32 halves to avoid 64-bit shift runtime functions
        const hi: u32 = @intCast(value >> 32);
        const lo: u32 = @intCast(value & 0xFFFFFFFF);
        self.putHexU32(hi);
        self.putHexU32(lo);
    }

    pub fn putDecU32(self: *Console, value: u32) void {
        if (value == 0) {
            self.putch('0');
            return;
        }

        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var remaining = value;

        while (remaining > 0) {
            digits[count] = @intCast('0' + (remaining % 10));
            remaining /= 10;
            count += 1;
        }

        while (count > 0) {
            count -= 1;
            self.putch(digits[count]);
        }
    }

    /// Print a u32 as a fixed-width 32-bit binary string.
    pub fn putBinaryU32(self: *Console, value: u32) void {
        var bit: u32 = 0;
        while (bit < 32) : (bit += 1) {
            const shift: u5 = @intCast(31 - bit);
            self.putch(if (((value >> shift) & 1) == 0) '0' else '1');
        }
    }

    pub inline fn put(self: *Console, multiple: anytype) void {
        inline for (multiple) |val| {
            if (@TypeOf(val) == u64) {
                self.putHexU64(val);
            } else if (@TypeOf(val) == u32 or @TypeOf(val) == usize) {
                self.putHexU32(val);
            } else if (@TypeOf(val) == u16) {
                self.putHexU16(val);
            } else if (@TypeOf(val) == u8) {
                self.putHexU8(val);
            } else {
                self.puts(val);
            }
        }
    }

    /// Dump memory in hex viewer format showing address, hex bytes, and ASCII representation.
    /// Displays `num_lines` of 16 bytes each starting from the given address.
    pub fn dumpMem(self: *Console, addr: u32, num_lines: u32) void {
        var line: u32 = 0;
        while (line < num_lines) : (line += 1) {
            const line_addr = addr + (line * 16);
            const ptr: [*]const u8 = @ptrFromInt(line_addr);

            self.putHexU32(line_addr);
            self.puts(": ");

            var byte_idx: u32 = 0;
            while (byte_idx < 16) : (byte_idx += 1) {
                self.putHexU8(ptr[byte_idx]);
                self.putch(' ');
            }

            self.puts("| ");

            byte_idx = 0;
            while (byte_idx < 16) : (byte_idx += 1) {
                const ch = ptr[byte_idx];
                if (ch >= 32 and ch < 127) {
                    self.putch(ch);
                } else {
                    self.putch('.');
                }
            }

            self.newline();
        }
    }
};

/// Primary console instance. All module-level wrapper functions delegate here.
pub var primary: Console = .{};

// ── Module-level wrappers (delegate to primary) ─────────────────────────────

pub fn init(attr: u8) void {
    primary.init(attr);
}

/// Format an unsigned integer as lowercase hex into `out`.  Static utility with no per-console state.
pub const formatHexU = Console.formatHexU;
pub fn refresh() void {
    primary.refresh();
}

pub fn clearCells(attr: u8) void {
    primary.clearCells(attr);
}

pub fn clear() void {
    primary.clear();
}

pub fn setCursor(row: u32, col: u32) void {
    primary.setCursor(row, col);
}

pub fn getCursorPos() struct { u32, u32 } {
    return primary.getCursorPos();
}

pub fn setAttr(attr: u8) void {
    primary.setAttr(attr);
}

pub fn setCursorVisible(visible: bool) void {
    primary.setCursorVisible(visible);
}

pub fn setSerialMirrorEnabled(enabled: bool) void {
    primary.setSerialMirrorEnabled(enabled);
}

pub fn isSerialMirrorEnabled() bool {
    return primary.isSerialMirrorEnabled();
}

pub fn readCell(row: u32, col: u32) u16 {
    return primary.readCell(row, col);
}

pub fn putCharAt(row: u32, col: u32, ch: u8, attr: u8) void {
    primary.putCharAt(row, col, ch, attr);
}

/// Stress text rendering by overwriting 1000 character cells per pass without advancing into scrollback.
pub fn stressWrite(iterations: u32) void {
    primary.stressWrite(iterations);
}

pub fn enableFramebufBackend(allocator: std.mem.Allocator, text_width: u32, text_height: u32) !void {
    return primary.enableFramebufBackend(allocator, text_width, text_height);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    primary.deinit(allocator);
}

pub fn enableBufferedBackend() void {
    primary.enableBufferedBackend();
}

pub fn newline() void {
    primary.newline();
}

pub fn putch(ch: u8) void {
    primary.putch(ch);
}

pub fn puts(s: []const u8) void {
    primary.puts(s);
}

pub fn putHexU8(value: u8) void {
    primary.putHexU8(value);
}

pub fn putHexU16(value: u16) void {
    primary.putHexU16(value);
}

pub fn putHexU32(value: u32) void {
    primary.putHexU32(value);
}

pub fn putHexU64(value: u64) void {
    primary.putHexU64(value);
}

pub fn putDecU32(value: u32) void {
    primary.putDecU32(value);
}

pub fn putBinaryU32(value: u32) void {
    primary.putBinaryU32(value);
}

pub inline fn put(multiple: anytype) void {
    primary.put(multiple);
}

pub fn dumpMem(addr: u32, num_lines: u32) void {
    primary.dumpMem(addr, num_lines);
}
