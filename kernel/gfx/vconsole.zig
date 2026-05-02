const font8x8 = @import("font8x8.zig");
const framebuf = @import("framebuf.zig");
const psf = @import("psf.zig");
const window = @import("window.zig");

const fs = @import("../fs.zig");
const mem = @import("../mem.zig");

const std = @import("std");

var active_font: psf.PSFFont = font8x8.font;
var active_font_label: []const u8 = "embedded psf1 8x8 bitmap";

// Prettier, blue-ish palette
const vga_palette = [16][3]u8{
    .{ 18, 28, 42 },
    .{ 40, 92, 170 },
    .{ 0x00, 0xAA, 0x00 },
    .{ 0x00, 0xAA, 0xAA },
    .{ 0xAA, 0x00, 0x00 },
    .{ 0xAA, 0x00, 0xAA },
    .{ 0xAA, 0x55, 0x00 },
    .{ 218, 232, 249 },
    .{ 138, 160, 188 },
    .{ 0x55, 0x55, 0xFF },
    .{ 0x55, 0xFF, 0x55 },
    .{ 0x55, 0xFF, 0xFF },
    .{ 0xFF, 0x55, 0x55 },
    .{ 0xFF, 0x55, 0xFF },
    .{ 0xFF, 0xFF, 0x55 },
    .{ 245, 248, 252 },
};

// Pre-packed color values for the specific pixel format of the framebuffer.
var packed_vga_palette: [16]u32 = undefined;

fn packPaletteColor(idx: u8) u32 {
    const rgb = vga_palette[idx & 0x0F];
    return framebuf.packRgb(rgb[0], rgb[1], rgb[2]);
}

fn swapAttr(attr: u8) u8 {
    return (attr << 4) | (attr >> 4);
}

inline fn blitScanline16(ptr: [*]u8, row_bitmap: u8, color0: u16, color1: u16) void {
    const U16Vec = @Vector(8, u16);
    const U8Vec = @Vector(8, u8);
    const BoolVec = @Vector(8, bool);
    const bit_masks: U8Vec = .{ 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 };
    const bits_set: BoolVec = (@as(U8Vec, @splat(row_bitmap)) & bit_masks) != @as(U8Vec, @splat(0));
    const bg: U16Vec = @splat(color0);
    const fg: U16Vec = @splat(color1);
    const pixels = @select(u16, bits_set, fg, bg);

    if ((@intFromPtr(ptr) & (@alignOf(U16Vec) - 1)) == 0) {
        @as(*U16Vec, @ptrCast(@alignCast(ptr))).* = pixels;
        return;
    }

    var p: [*]u16 = @ptrCast(@alignCast(ptr));
    inline for (0..8) |i| {
        p[i] = pixels[i];
    }
}

fn drawGlyphCellAt(
    pix_ptr: [*]u8,
    pitch: usize,
    font: *const psf.PSFFont,
    ch: u8,
    attr: u8,
) void {
    const bg: u16 = @truncate(packed_vga_palette[@truncate(attr >> 4)]);
    const fg: u16 = @truncate(packed_vga_palette[@truncate(attr & 0x0F)]);
    const glyph = font.getGlyph(ch);

    var row: u32 = 0;
    var row_ptr = pix_ptr;
    while (row < font.glyph_height) : (row += 1) {
        const row_bitmap = glyph[row];
        blitScanline16(@ptrCast(row_ptr), row_bitmap, bg, fg);
        row_ptr += pitch;
    }
}

fn consoleCellWidthBytes() usize {
    return @as(usize, @intCast(active_font.glyph_width)) * framebuf.bytesPerPixel();
}

fn consoleCellHeightRows() usize {
    return @intCast(active_font.glyph_height);
}

/// Load a PSF font file from the root filesystem and make it the active framebuffer-console font.
pub fn loadFont(allocator: std.mem.Allocator, disk_fs: *const fs.FileSystem, path: []const u8) !void {
    const file_data = try disk_fs.readFile(allocator, path);
    defer allocator.free(file_data);

    active_font = try psf.loadFromBytes(allocator, file_data, '?');
    if (active_font.glyph_width > 8) {
        return error.UnsupportedFont; // optimized renderer for 8px wide glyphs only
    }
    active_font_label = path;
}

pub const TextSize = window.TextSize;

/// Return a text grid size that fits inside a framed framebuffer console window within the given area.
pub fn preferredTextSize(avail_w: u32, avail_h: u32, title: []const u8) !TextSize {
    return window.preferredTextSize(avail_w, avail_h, active_font.glyph_width, active_font.glyph_height, title.len);
}

/// Framebuffer-backed virtual console: owns a Window and tracks cursor/grid state.
pub const VConsole = struct {
    win: window.Window = .{},
    cols: u32 = 0,
    rows: u32 = 0,
    cursor_row: u32 = 0,
    cursor_col: u32 = 0,
    cursor_visible: bool = false,

    /// Initialise the VConsole: allocate the shadow buffer and set dimensions.
    /// Call drawBackground() then drawFrame() separately to paint the screen.
    pub fn init(
        self: *VConsole,
        allocator: std.mem.Allocator,
        avail_x: u32,
        avail_y: u32,
        avail_w: u32,
        avail_h: u32,
        cols: u32,
        rows: u32,
        title: []const u8,
    ) !void {
        for (0..16) |i| {
            packed_vga_palette[i] = packPaletteColor(@truncate(i));
        }
        self.cols = cols;
        self.rows = rows;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = false;
        try self.win.init(
            allocator,
            avail_x,
            avail_y,
            avail_w,
            avail_h,
            cols,
            rows,
            active_font.glyph_width,
            active_font.glyph_height,
            title,
        );
    }

    /// Redraw this window's chrome using the active font.
    pub fn drawFrame(self: *VConsole) void {
        self.win.drawFrame(&active_font);
    }

    /// Free resources owned by this VConsole.
    pub fn deinit(self: *VConsole, allocator: std.mem.Allocator) void {
        self.win.deinit(allocator);
    }

    fn cellIndex(self: *const VConsole, row: u32, col: u32) usize {
        return @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
    }

    fn drawConsoleCellRaw(self: *const VConsole, cell: u16, row: u32, col: u32, highlight: bool) void {
        if (!self.win.isReady()) return;

        const font = &active_font;
        const ch: u8 = @truncate(cell & 0x00FF);
        const attr: u8 = @truncate(cell >> 8);
        const pix_ptr = self.win.shadowRowPtr(@as(usize, row) * @as(usize, font.glyph_height)) +
            @as(usize, col) * @as(usize, font.glyph_width) * framebuf.bytesPerPixel();
        const effective_attr = if (highlight) swapAttr(attr) else attr;
        drawGlyphCellAt(pix_ptr, self.win.pitchBytes(), font, if (ch == 0) ' ' else ch, effective_attr);
    }

    fn drawConsoleRowAt(self: *const VConsole, cells: [*]const u16, row_ptr: [*]u8, row_pitch_bytes: usize) void {
        const font = &active_font;
        const cell_width_bytes = consoleCellWidthBytes();
        var cell_ptr = cells;
        var cell_pix_ptr = row_ptr;
        var col: u32 = 0;
        while (col < self.cols) : (col += 1) {
            const cell = cell_ptr[0];
            drawGlyphCellAt(
                cell_pix_ptr,
                row_pitch_bytes,
                font,
                if ((cell & 0x00FF) == 0) ' ' else @truncate(cell & 0x00FF),
                @truncate(cell >> 8),
            );
            cell_ptr += 1;
            cell_pix_ptr += cell_width_bytes;
        }
    }

    /// Redraw the full console grid into the framebuffer-backed virtual console.
    pub fn render(self: *VConsole, cells: [*]const u16, cursor_row: u32, cursor_col: u32, show_cursor: bool) void {
        if (!self.win.isReady()) return;

        const text_rows = self.rows;
        const text_cols = self.cols;
        const row_height_bytes = self.win.pitchBytes() * consoleCellHeightRows();
        var shadow_text_row_ptr = self.win.shadowRowPtr(0);
        var cell_row_ptr: [*]const u16 = cells;
        var row: u32 = 0;
        while (row < text_rows) : (row += 1) {
            self.drawConsoleRowAt(cell_row_ptr, shadow_text_row_ptr, self.win.pitchBytes());
            cell_row_ptr += text_cols;
            shadow_text_row_ptr += row_height_bytes;
        }

        self.cursor_row = if (cursor_row < text_rows) cursor_row else text_rows - 1;
        self.cursor_col = if (cursor_col < text_cols) cursor_col else text_cols - 1;
        self.cursor_visible = show_cursor;

        if (self.cursor_visible) {
            self.drawConsoleCellRaw(cells[self.cellIndex(self.cursor_row, self.cursor_col)], self.cursor_row, self.cursor_col, true);
        }
        self.win.blitShadowRowsToFramebuffer(0, self.win.pixelRows());
    }

    /// Scroll the virtual console up by one text row and redraw the newly exposed bottom row.
    pub fn scroll(self: *VConsole, cells: [*]const u16) void {
        if (!self.win.isReady()) return;

        const text_rows = self.rows;
        const cell_h = consoleCellHeightRows();
        const scrolled_bytes = (self.win.pixelRows() - cell_h) * self.win.pitchBytes();
        const scroll_src_offset = cell_h * self.win.pitchBytes();
        const shadow_start = self.win.shadowRowPtr(0);
        mem.copyBytesForward(shadow_start, shadow_start + scroll_src_offset, scrolled_bytes);

        const bottom_row_cells = cells + self.cellIndex(text_rows - 1, 0);
        const bottom_row_ptr = self.win.shadowRowPtr(self.win.pixelRows() - cell_h);
        self.drawConsoleRowAt(bottom_row_cells, bottom_row_ptr, self.win.pitchBytes());
        self.win.blitShadowRowsToFramebuffer(0, self.win.pixelRows());
    }

    /// Redraw a single console cell in the framebuffer-backed virtual console.
    pub fn renderCell(self: *VConsole, cells: [*]const u16, row: u32, col: u32) void {
        if (!self.win.isReady()) return;
        if (row >= self.rows or col >= self.cols) return;

        const highlight = self.cursor_visible and row == self.cursor_row and col == self.cursor_col;
        self.drawConsoleCellRaw(cells[self.cellIndex(row, col)], row, col, highlight);
        self.win.blitShadowCellToFramebuffer(row, col);
    }

    /// Update the highlighted cursor cell in the framebuffer-backed virtual console.
    pub fn setCursor(self: *VConsole, cells: [*]const u16, row: u32, col: u32, visible: bool) void {
        if (!self.win.isReady()) return;

        if (self.cursor_visible) {
            self.drawConsoleCellRaw(cells[self.cellIndex(self.cursor_row, self.cursor_col)], self.cursor_row, self.cursor_col, false);
            self.win.blitShadowCellToFramebuffer(self.cursor_row, self.cursor_col);
        }

        const text_rows = self.rows;
        const text_cols = self.cols;
        self.cursor_row = if (row < text_rows) row else text_rows - 1;
        self.cursor_col = if (col < text_cols) col else text_cols - 1;
        self.cursor_visible = visible;

        if (self.cursor_visible) {
            self.drawConsoleCellRaw(cells[self.cellIndex(self.cursor_row, self.cursor_col)], self.cursor_row, self.cursor_col, true);
            self.win.blitShadowCellToFramebuffer(self.cursor_row, self.cursor_col);
        }
    }
};
