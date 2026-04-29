const font8x8 = @import("font8x8.zig");
const framebuf = @import("framebuf.zig");
const psf = @import("psf.zig");

const fs = @import("../fs.zig");
const paging = @import("../paging.zig");
const console = @import("../console.zig");
const mem = @import("../mem.zig");

const std = @import("std");

const console_shadow_va: u32 = 0xD100_0000;

var active_font: psf.PSFFont = font8x8.font;
var active_font_label: []const u8 = "embedded psf1 8x8 bitmap";

// For faster scrolling, we keep a shadow buffer into which we render console text.
// It's then blitted to the framebuffer on demand. This avoids slow readback from VESA memory.
var shadow_buffer: [*]u8 = undefined;
var shadow_pitch: usize = 0; // distance in bytes between the start of consecutive pixel rows in the shadow buffer
var shadow_rows: usize = 0; // number of rows in the shadow buffer

var origin_x: u32 = 0;
var origin_y: u32 = 0;
var panel_x: u32 = 0;
var panel_y: u32 = 0;
var panel_w: u32 = 0;
var panel_h: u32 = 0;
var title_h: u32 = 0;
var console_cursor_row: u32 = 0;
var console_cursor_col: u32 = 0;
var cursor_visible: bool = false;
var console_ready: bool = false;

const panel_border: u32 = 1;
const panel_padding_x: u32 = 2;
const panel_padding_y: u32 = 2;
const title_padding_y: u32 = 3;
const title_padding_x: u32 = 10;
const console_title = "zoodle86 framebuffer console";

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
    var p: [*]u16 = @ptrCast(@alignCast(ptr));

    p[0] = if ((row_bitmap & 0x80) != 0) color1 else color0;
    p[1] = if ((row_bitmap & 0x40) != 0) color1 else color0;
    p[2] = if ((row_bitmap & 0x20) != 0) color1 else color0;
    p[3] = if ((row_bitmap & 0x10) != 0) color1 else color0;
    p[4] = if ((row_bitmap & 0x08) != 0) color1 else color0;
    p[5] = if ((row_bitmap & 0x04) != 0) color1 else color0;
    p[6] = if ((row_bitmap & 0x02) != 0) color1 else color0;
    p[7] = if ((row_bitmap & 0x01) != 0) color1 else color0;
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

fn consoleCellIndex(row: u32, col: u32) usize {
    return @as(usize, @intCast(row)) * @as(usize, console.TEXT_WIDTH) + @as(usize, @intCast(col));
}

fn consoleCellWidthBytes() usize {
    return @as(usize, @intCast(active_font.glyph_width)) * framebuf.bytesPerPixel();
}

fn consoleCellHeightRows() usize {
    return @intCast(active_font.glyph_height);
}

// Pointer into the console shadow buffer at the start of a given pixel row.
fn shadowRowPtr(pixel_row: usize) [*]u8 {
    return shadow_buffer + pixel_row * shadow_pitch;
}

// Pointer into the framebuffer at the start of a given pixel row within the console text area.
fn fbRowPtr(pixel_row: usize) [*]u8 {
    return framebuf.pixelPtr(origin_x, origin_y) + pixel_row * framebuf.pitchBytes();
}

fn blitShadowRowsToFramebuffer(start_pixel_row: usize, row_count: usize) void {
    var src = shadowRowPtr(start_pixel_row);
    var dst = fbRowPtr(start_pixel_row);
    var row: usize = 0;
    while (row < row_count) : (row += 1) {
        mem.copyBytesForward(dst, src, shadow_pitch);
        src += shadow_pitch;
        dst += framebuf.pitchBytes();
    }
}

fn blitShadowCellToFramebuffer(row: u32, col: u32) void {
    const start_pixel_row = @as(usize, @intCast(row * active_font.glyph_height));
    const pixel_col_offset = @as(usize, @intCast(col * active_font.glyph_width)) * framebuf.bytesPerPixel();
    var src = shadowRowPtr(start_pixel_row) + pixel_col_offset;
    var dst = fbRowPtr(start_pixel_row) + pixel_col_offset;
    var pixel_row: usize = 0;
    while (pixel_row < consoleCellHeightRows()) : (pixel_row += 1) {
        mem.copyBytesForward(dst, src, consoleCellWidthBytes());
        src += shadow_pitch;
        dst += framebuf.pitchBytes();
    }
}

fn drawConsoleCellRaw(cell: u16, row: u32, col: u32, highlight: bool) void {
    if (!console_ready) return;

    const font = &active_font;
    const ch: u8 = @truncate(cell & 0x00FF);
    const attr: u8 = @truncate(cell >> 8);
    const pix_ptr = shadowRowPtr(@as(usize, @intCast(row * font.glyph_height))) +
        @as(usize, @intCast(col * font.glyph_width)) * framebuf.bytesPerPixel();

    const effective_attr = if (highlight) swapAttr(attr) else attr;

    drawGlyphCellAt(
        pix_ptr,
        shadow_pitch,
        font,
        if (ch == 0) ' ' else ch,
        effective_attr,
    );
}

fn drawConsoleRowAt(cells: [*]const console.Cell, row_ptr: [*]u8, row_pitch_bytes: usize) void {
    const font = &active_font;
    const cell_width_bytes = consoleCellWidthBytes();
    var cell_ptr = cells;
    var cell_pix_ptr = row_ptr;
    var col: u32 = 0;
    while (col < console.TEXT_WIDTH) : (col += 1) {
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

fn drawFrame() void {
    if (!console_ready) return;

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
        &active_font,
        console_title,
        title_fg,
    );
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

/// Prepare the 80x25 virtual-console window once a framebuffer is available.
pub fn init() !void {
    if (console_ready) return;

    for (0..16) |i| {
        packed_vga_palette[i] = packPaletteColor(@truncate(i));
    }

    const font = &active_font;
    const text_width = console.TEXT_WIDTH * font.glyph_width;
    const text_height = console.TEXT_HEIGHT * font.glyph_height;
    const title_text_w = console_title.len * font.glyph_width;
    title_h = font.glyph_height + title_padding_y * 2;
    const min_inner_w = @max(text_width + panel_padding_x * 2, title_text_w + title_padding_x * 2);
    panel_w = min_inner_w + panel_border * 2;
    panel_h = text_height + title_h + panel_padding_y * 2 + panel_border * 2;
    if (framebuf.width() < panel_w or framebuf.height() < panel_h) return error.WindowTooLarge;

    panel_x = (framebuf.width() - panel_w) / 2;
    panel_y = (framebuf.height() - panel_h) / 2;
    origin_x = panel_x + panel_border + panel_padding_x;
    origin_y = panel_y + panel_border + title_h + panel_padding_y;
    console_cursor_row = 0;
    console_cursor_col = 0;
    cursor_visible = false;
    shadow_pitch = @as(usize, @intCast(text_width)) * framebuf.bytesPerPixel();
    shadow_rows = @as(usize, @intCast(text_height));
    const shadow_size = shadow_pitch * shadow_rows;
    const shadow_pages: u32 = @intCast(@divTrunc(shadow_size + paging.PAGE - 1, paging.PAGE));
    const shadow_mem = paging.allocateMemoryAt(console_shadow_va, shadow_pages, false, true);
    shadow_buffer = shadow_mem.ptr;
    @memset(shadow_buffer[0..shadow_size], 0);
    console_ready = true;

    drawFrame();
}

/// Redraw the full 80x25 console grid into the framebuffer-backed virtual console.
pub fn render(cells: [*]console.Cell, cursor_row: u32, cursor_col: u32, show_cursor: bool) void {
    if (!console_ready) return;

    const row_height_bytes = shadow_pitch * consoleCellHeightRows();
    var shadow_text_row_ptr = shadow_buffer;
    var cell_row_ptr: [*]const console.Cell = cells;
    var row: u32 = 0;
    while (row < console.TEXT_HEIGHT) : (row += 1) {
        drawConsoleRowAt(cell_row_ptr, shadow_text_row_ptr, shadow_pitch);
        cell_row_ptr += console.TEXT_WIDTH;
        shadow_text_row_ptr += row_height_bytes;
    }

    console_cursor_row = if (cursor_row < console.TEXT_HEIGHT) cursor_row else console.TEXT_HEIGHT - 1;
    console_cursor_col = if (cursor_col < console.TEXT_WIDTH) cursor_col else console.TEXT_WIDTH - 1;
    cursor_visible = show_cursor;

    if (cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
    }
    blitShadowRowsToFramebuffer(0, shadow_rows);
}

/// Scroll the virtual console up by one text row and redraw the newly exposed bottom row.
pub fn scroll(cells: [*]const console.Cell) void {
    if (!console_ready) return;

    const scrolled_bytes = (shadow_rows - consoleCellHeightRows()) * shadow_pitch;
    const scroll_src_offset = consoleCellHeightRows() * shadow_pitch;
    mem.copyBytesForward(shadow_buffer, shadow_buffer + scroll_src_offset, scrolled_bytes);

    const bottom_row_cells = cells + consoleCellIndex(console.TEXT_HEIGHT - 1, 0);
    const bottom_row_ptr = shadowRowPtr(shadow_rows - consoleCellHeightRows());
    drawConsoleRowAt(bottom_row_cells, bottom_row_ptr, shadow_pitch);
    blitShadowRowsToFramebuffer(0, shadow_rows);
}

/// Redraw a single console cell in the framebuffer-backed virtual console.
pub fn renderCell(cells: [*]console.Cell, row: u32, col: u32) void {
    if (!console_ready) return;
    if (row >= console.TEXT_HEIGHT or col >= console.TEXT_WIDTH) return;

    const highlight = cursor_visible and row == console_cursor_row and col == console_cursor_col;
    drawConsoleCellRaw(cells[consoleCellIndex(row, col)], row, col, highlight);
    blitShadowCellToFramebuffer(row, col);
}

/// Update the highlighted cursor cell in the framebuffer-backed virtual console.
pub fn setCursor(cells: [*]const console.Cell, row: u32, col: u32, visible: bool) void {
    if (!console_ready) return;

    if (cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, false);
        blitShadowCellToFramebuffer(console_cursor_row, console_cursor_col);
    }

    console_cursor_row = if (row < console.TEXT_HEIGHT) row else console.TEXT_HEIGHT - 1;
    console_cursor_col = if (col < console.TEXT_WIDTH) col else console.TEXT_WIDTH - 1;
    cursor_visible = visible;

    if (cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
        blitShadowCellToFramebuffer(console_cursor_row, console_cursor_col);
    }
}
