const framebuf = @import("framebuf.zig");
const psf = @import("psf.zig");
const mem = @import("../mem.zig");
const std = @import("std");

const panel_border: u32 = 1;
const panel_padding_x: u32 = 2;
const panel_padding_y: u32 = 2;
const title_padding_y: u32 = 3;
const title_padding_x: u32 = 10;
const window_margin: u32 = 20;

/// A character-grid size in columns and rows.
pub const TextSize = struct {
    cols: u32,
    rows: u32,
};

/// Return a text-grid size that fits inside a framed window for the given available pixel area.
pub fn preferredTextSize(avail_w: u32, avail_h: u32, glyph_width: u32, glyph_height: u32, title_len: usize) !TextSize {
    const title_text_w: u32 = @intCast(title_len * glyph_width);
    const min_panel_w = title_text_w + title_padding_x * 2 + panel_border * 2;
    const title_height = glyph_height + title_padding_y * 2;
    const min_panel_h = title_height + panel_padding_y * 2 + panel_border * 2 + glyph_height;
    if (avail_w < min_panel_w + window_margin * 2 or avail_h < min_panel_h + window_margin * 2)
        return error.WindowTooLarge;

    const text_area_w = avail_w - 2 * (window_margin + panel_border + panel_padding_x);
    const text_area_h = avail_h - (window_margin * 2 + panel_border * 2 + title_height + panel_padding_y * 2);
    const cols = text_area_w / glyph_width;
    const rows = text_area_h / glyph_height;
    if (cols == 0 or rows == 0) return error.WindowTooLarge;
    return .{ .cols = @min(100, cols), .rows = @min(50, rows) };
}

/// Fill the entire framebuffer with the desktop background colour. Call once before drawing any windows.
pub fn drawBackground() void {
    const bg = framebuf.packRgb(8, 14, 23);
    framebuf.fillRect(0, 0, framebuf.width(), framebuf.height(), bg);
}

/// Framed console window with an off-screen shadow buffer for double-buffered text rendering.
pub const Window = struct {
    panel_x: u32 = 0,
    panel_y: u32 = 0,
    panel_w: u32 = 0,
    panel_h: u32 = 0,
    origin_x: u32 = 0,
    origin_y: u32 = 0,
    title_h: u32 = 0,
    /// Shadow pixel data; length = pixel_width * pixel_height (one u16 per pixel for 16bpp).
    shadow_data: []u16 = &.{},
    shadow_pitch: usize = 0, // bytes per pixel row
    shadow_rows: usize = 0, // total pixel rows in shadow buffer
    glyph_w: u32 = 0,
    glyph_h: u32 = 0,
    title: []const u8 = "", // must outlive the Window
    ready: bool = false,

    /// Returns true if the window has been successfully initialized.
    pub fn isReady(self: *const Window) bool {
        return self.ready;
    }

    /// Set up the framed window and backing shadow buffer for a text_cols×text_rows character grid
    /// within the available area starting at (avail_x, avail_y) with dimensions avail_w×avail_h.
    pub fn init(
        self: *Window,
        allocator: std.mem.Allocator,
        avail_x: u32,
        avail_y: u32,
        avail_w: u32,
        avail_h: u32,
        text_cols: u32,
        text_rows: u32,
        glyph_width: u32,
        glyph_height: u32,
        title: []const u8,
    ) !void {
        const pixel_w: usize = @as(usize, text_cols) * @as(usize, glyph_width);
        const pixel_h: usize = @as(usize, text_rows) * @as(usize, glyph_height);
        const title_text_w: u32 = @intCast(title.len * glyph_width);
        const title_h_val = glyph_height + title_padding_y * 2;
        const min_inner_w = @max(
            @as(u32, @intCast(pixel_w)) + panel_padding_x * 2,
            title_text_w + title_padding_x * 2,
        );
        const panel_w_val = min_inner_w + panel_border * 2;
        const panel_h_val = @as(u32, @intCast(pixel_h)) + title_h_val + panel_padding_y * 2 + panel_border * 2;
        if (panel_w_val > avail_w or panel_h_val > avail_h) return error.WindowTooLarge;

        self.title = title;
        self.title_h = title_h_val;
        self.panel_w = panel_w_val;
        self.panel_h = panel_h_val;
        self.panel_x = avail_x + window_margin;
        self.panel_y = avail_y + window_margin;
        self.origin_x = self.panel_x + panel_border + panel_padding_x;
        self.origin_y = self.panel_y + panel_border + title_h_val + panel_padding_y;
        self.glyph_w = glyph_width;
        self.glyph_h = glyph_height;
        self.shadow_pitch = pixel_w * framebuf.bytesPerPixel();
        self.shadow_rows = pixel_h;
        self.shadow_data = try allocator.alloc(u16, pixel_w * pixel_h);
        @memset(self.shadow_data, 0);
        self.ready = true;
    }

    /// Free the shadow buffer.
    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        if (self.shadow_data.len > 0) {
            allocator.free(self.shadow_data);
            self.shadow_data = &.{};
            self.ready = false;
        }
    }

    /// Redraw the window chrome: border, panel fill, and title bar. Call drawBackground() first.
    pub fn drawFrame(self: *Window, font: *const psf.PSFFont) void {
        if (!self.ready) return;

        const panel = framebuf.packRgb(18, 28, 42);
        const border = framebuf.packRgb(56, 86, 125);
        const title_bg = framebuf.packRgb(40, 92, 170);
        const title_fg = framebuf.packRgb(218, 232, 249);

        framebuf.fillRect(self.panel_x, self.panel_y, self.panel_w, self.panel_h, border);
        framebuf.fillRect(
            self.panel_x + panel_border,
            self.panel_y + panel_border,
            self.panel_w - panel_border * 2,
            self.panel_h - panel_border * 2,
            panel,
        );
        framebuf.fillRect(
            self.panel_x + panel_border,
            self.panel_y + panel_border,
            self.panel_w - panel_border * 2,
            self.title_h,
            title_bg,
        );
        framebuf.drawText(
            self.panel_x + panel_border + title_padding_x,
            self.panel_y + panel_border + title_padding_y,
            font,
            self.title,
            title_fg,
        );
    }

    /// Return the number of bytes between adjacent rows in the shadow buffer.
    pub fn pitchBytes(self: *const Window) usize {
        return self.shadow_pitch;
    }

    /// Return the total number of pixel rows in the shadow buffer.
    pub fn pixelRows(self: *const Window) usize {
        return self.shadow_rows;
    }

    /// Return a pointer into the shadow buffer at the start of the given pixel row.
    pub fn shadowRowPtr(self: *const Window, pixel_row: usize) [*]u8 {
        return @as([*]u8, @ptrCast(self.shadow_data.ptr)) + pixel_row * self.shadow_pitch;
    }

    fn fbRowPtr(self: *const Window, pixel_row: usize) [*]u8 {
        return framebuf.pixelPtr(self.origin_x, self.origin_y) + pixel_row * framebuf.pitchBytes();
    }

    /// Copy a contiguous range of shadow-buffer rows into the corresponding framebuffer rows.
    pub fn blitShadowRowsToFramebuffer(self: *const Window, start_pixel_row: usize, row_count: usize) void {
        var src = self.shadowRowPtr(start_pixel_row);
        var dst = self.fbRowPtr(start_pixel_row);
        var row: usize = 0;
        while (row < row_count) : (row += 1) {
            mem.copyBytesForward(dst, src, self.shadow_pitch);
            src += self.shadow_pitch;
            dst += framebuf.pitchBytes();
        }
    }

    /// Copy a single character cell from the shadow buffer into the framebuffer.
    pub fn blitShadowCellToFramebuffer(self: *const Window, row: u32, col: u32) void {
        const start_pixel_row: usize = @as(usize, row) * @as(usize, self.glyph_h);
        const cell_w_bytes: usize = @as(usize, self.glyph_w) * framebuf.bytesPerPixel();
        const pixel_col_offset: usize = @as(usize, col) * @as(usize, self.glyph_w) * framebuf.bytesPerPixel();
        var src = self.shadowRowPtr(start_pixel_row) + pixel_col_offset;
        var dst = self.fbRowPtr(start_pixel_row) + pixel_col_offset;
        var pixel_row: usize = 0;
        while (pixel_row < @as(usize, self.glyph_h)) : (pixel_row += 1) {
            mem.copyBytesForward(dst, src, cell_w_bytes);
            src += self.shadow_pitch;
            dst += framebuf.pitchBytes();
        }
    }
};
