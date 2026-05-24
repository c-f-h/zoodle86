const console_palette = @import("console_palette.zig");
const framebuf = @import("framebuf.zig");
const psf = @import("psf.zig");
const mem = @import("../mem.zig");
const std = @import("std");

pub const panel_border: u32 = 1;
pub const panel_padding_x: u32 = 2;
pub const panel_padding_y: u32 = 2;
pub const title_padding_y: u32 = 3;
pub const title_padding_x: u32 = 10;
pub const window_margin: u32 = 20;

/// Fill the entire framebuffer with the desktop background colour. Call once before drawing any windows.
pub fn drawBackground() void {
    const bg = framebuf.packRgb(.{ 8, 14, 23 });
    //const bg = framebuf.packRgb(console_palette.ansi[console_palette.background]);
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
    /// Each 8 pixel glyph scanline is 16-byte aligned for SIMD vectorization.
    shadow_data: []align(16) u16 = &.{},
    shadow_pitch: usize = 0, // bytes per pixel row
    shadow_rows: usize = 0, // total pixel rows in shadow buffer
    title: []const u8 = "", // must outlive the Window

    /// Set up the framed window and backing shadow buffer for a text_cols x text_rows character grid
    /// within the available area starting at (x, y) with dimensions (width, height).
    pub fn init(
        self: *Window,
        allocator: std.mem.Allocator,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        text_cols: u32,
        text_rows: u32,
        glyph_width: u32,
        glyph_height: u32,
        title: []const u8,
    ) !void {
        const client_w = text_cols * glyph_width;
        const client_h = text_rows * glyph_height;
        const title_text_w = title.len * glyph_width;
        const title_h_val = glyph_height + title_padding_y * 2;
        const min_inner_w = @max(
            client_w + panel_padding_x * 2,
            title_text_w + title_padding_x * 2,
        );
        const panel_w_val = min_inner_w + panel_border * 2;
        const panel_h_val = client_h + title_h_val + panel_padding_y * 2 + panel_border * 2;
        if (panel_w_val > width or panel_h_val > height) return error.WindowTooLarge;

        self.title = title;
        self.title_h = title_h_val;
        self.panel_w = panel_w_val;
        self.panel_h = panel_h_val;
        self.panel_x = x + window_margin;
        self.panel_y = y + window_margin;
        self.origin_x = self.panel_x + panel_border + panel_padding_x;
        self.origin_y = self.panel_y + panel_border + title_h_val + panel_padding_y;
        self.shadow_pitch = client_w * framebuf.bytesPerPixel();
        self.shadow_rows = client_h;
        self.shadow_data = try allocator.alignedAlloc(u16, std.mem.Alignment.@"16", client_w * client_h);
        @memset(self.shadow_data, 0);
    }

    /// Free the shadow buffer.
    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        if (self.shadow_data.len > 0) {
            allocator.free(self.shadow_data);
            self.shadow_data = &.{};
        }
    }

    /// Redraw the window chrome: border, panel fill, and title bar. Call drawBackground() first.
    pub fn drawFrame(self: *Window, font: *const psf.PSFFont) void {
        const panel = framebuf.packRgb(console_palette.ansi[console_palette.background]);
        const border = framebuf.packRgb(console_palette.ansi[console_palette.border]);
        const title_bg = framebuf.packRgb(console_palette.ansi[console_palette.title_bg]);
        const title_fg = framebuf.packRgb(console_palette.ansi[console_palette.title_fg]);

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

    pub fn fbRowPtr(self: *const Window, pixel_row: usize) [*]u8 {
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
};
