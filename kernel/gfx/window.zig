const framebuf = @import("framebuf.zig");
const psf = @import("psf.zig");
const paging = @import("../paging.zig");
const mem = @import("../mem.zig");

const console_shadow_va: u32 = 0xD100_0000;
const title_text = "zoodle86 framebuffer console";

const panel_border: u32 = 1;
const panel_padding_x: u32 = 2;
const panel_padding_y: u32 = 2;
const title_padding_y: u32 = 3;
const title_padding_x: u32 = 10;
const window_margin: u32 = 20;

var origin_x: u32 = 0;
var origin_y: u32 = 0;
var panel_x: u32 = 0;
var panel_y: u32 = 0;
var panel_w: u32 = 0;
var panel_h: u32 = 0;
var title_h: u32 = 0;
var shadow_buffer: [*]u8 = undefined;
var shadow_pitch: usize = 0;
var shadow_rows: usize = 0;
var glyph_w: u32 = 0;
var glyph_h: u32 = 0;
var ready: bool = false;

/// A character-grid size in columns and rows.
pub const TextSize = struct {
    cols: u32,
    rows: u32,
};

/// Returns true if the window has been successfully initialized.
pub fn isReady() bool {
    return ready;
}

/// Return a text-grid size that fits inside the framed window for the given glyph dimensions.
pub fn preferredTextSize(glyph_width: u32, glyph_height: u32) !TextSize {
    const title_text_w = title_text.len * glyph_width;
    const min_panel_w = title_text_w + title_padding_x * 2 + panel_border * 2;
    const title_height = glyph_height + title_padding_y * 2;
    const min_panel_h = title_height + panel_padding_y * 2 + panel_border * 2 + glyph_height;
    if (framebuf.width() < min_panel_w or framebuf.height() < min_panel_h) return error.WindowTooLarge;

    const text_area_w = framebuf.width() - 2 * (window_margin + panel_border + panel_padding_x);
    const text_area_h = framebuf.height() - (window_margin * 2 + panel_border * 2 + title_height + panel_padding_y * 2);
    const cols = text_area_w / glyph_width;
    const rows = text_area_h / glyph_height;
    if (cols == 0 or rows == 0) return error.WindowTooLarge;
    return .{ .cols = @min(100, cols), .rows = @min(50, rows) };
}

/// Set up the framed window and backing shadow buffer for a text_cols×text_rows character grid.
pub fn init(text_cols: u32, text_rows: u32, glyph_width: u32, glyph_height: u32) !void {
    const text_width = text_cols * glyph_width;
    const text_height = text_rows * glyph_height;
    const title_text_w = title_text.len * glyph_width;
    title_h = glyph_height + title_padding_y * 2;
    const min_inner_w = @max(text_width + panel_padding_x * 2, title_text_w + title_padding_x * 2);
    panel_w = min_inner_w + panel_border * 2;
    panel_h = text_height + title_h + panel_padding_y * 2 + panel_border * 2;
    if (framebuf.width() < panel_w or framebuf.height() < panel_h) return error.WindowTooLarge;

    panel_x = window_margin;
    panel_y = window_margin;
    origin_x = panel_x + panel_border + panel_padding_x;
    origin_y = panel_y + panel_border + title_h + panel_padding_y;
    glyph_w = glyph_width;
    glyph_h = glyph_height;
    shadow_pitch = @as(usize, @intCast(text_width)) * framebuf.bytesPerPixel();
    shadow_rows = @as(usize, @intCast(text_height));
    const shadow_size = shadow_pitch * shadow_rows;
    const shadow_pages: u32 = @intCast(@divTrunc(shadow_size + paging.PAGE - 1, paging.PAGE));
    const shadow_mem = paging.allocateMemoryAt(console_shadow_va, shadow_pages, false, true);
    shadow_buffer = shadow_mem.ptr;
    @memset(shadow_buffer[0..shadow_size], 0);
    ready = true;
}

/// Redraw the window chrome: desktop background, border, panel fill, and title bar.
pub fn drawFrame(font: *const psf.PSFFont) void {
    if (!ready) return;

    const bg = framebuf.packRgb(8, 14, 23);
    const panel = framebuf.packRgb(18, 28, 42);
    const border = framebuf.packRgb(56, 86, 125);
    const title_bg = framebuf.packRgb(40, 92, 170);
    const title_fg = framebuf.packRgb(218, 232, 249);

    framebuf.fillRect(0, 0, framebuf.width(), framebuf.height(), bg);
    framebuf.fillRect(panel_x, panel_y, panel_w, panel_h, border);
    framebuf.fillRect(
        panel_x + panel_border,
        panel_y + panel_border,
        panel_w - panel_border * 2,
        panel_h - panel_border * 2,
        panel,
    );
    framebuf.fillRect(
        panel_x + panel_border,
        panel_y + panel_border,
        panel_w - panel_border * 2,
        title_h,
        title_bg,
    );
    framebuf.drawText(
        panel_x + panel_border + title_padding_x,
        panel_y + panel_border + title_padding_y,
        font,
        title_text,
        title_fg,
    );
}

/// Return the number of bytes between adjacent rows in the shadow buffer.
pub fn pitchBytes() usize {
    return shadow_pitch;
}

/// Return the total number of pixel rows in the shadow buffer.
pub fn pixelRows() usize {
    return shadow_rows;
}

/// Return a pointer into the shadow buffer at the start of the given pixel row.
pub fn shadowRowPtr(pixel_row: usize) [*]u8 {
    return shadow_buffer + pixel_row * shadow_pitch;
}

fn fbRowPtr(pixel_row: usize) [*]u8 {
    return framebuf.pixelPtr(origin_x, origin_y) + pixel_row * framebuf.pitchBytes();
}

/// Copy a contiguous range of shadow-buffer rows into the corresponding framebuffer rows.
pub fn blitShadowRowsToFramebuffer(start_pixel_row: usize, row_count: usize) void {
    var src = shadowRowPtr(start_pixel_row);
    var dst = fbRowPtr(start_pixel_row);
    var row: usize = 0;
    while (row < row_count) : (row += 1) {
        mem.copyBytesForward(dst, src, shadow_pitch);
        src += shadow_pitch;
        dst += framebuf.pitchBytes();
    }
}

/// Copy a single character cell from the shadow buffer into the framebuffer.
pub fn blitShadowCellToFramebuffer(row: u32, col: u32) void {
    const start_pixel_row = @as(usize, @intCast(row * glyph_h));
    const cell_w_bytes = @as(usize, @intCast(glyph_w)) * framebuf.bytesPerPixel();
    const pixel_col_offset = @as(usize, @intCast(col * glyph_w)) * framebuf.bytesPerPixel();
    var src = shadowRowPtr(start_pixel_row) + pixel_col_offset;
    var dst = fbRowPtr(start_pixel_row) + pixel_col_offset;
    var pixel_row: usize = 0;
    while (pixel_row < @as(usize, @intCast(glyph_h))) : (pixel_row += 1) {
        mem.copyBytesForward(dst, src, cell_w_bytes);
        src += shadow_pitch;
        dst += framebuf.pitchBytes();
    }
}
