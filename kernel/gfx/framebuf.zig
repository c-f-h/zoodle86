const font8x8 = @import("font8x8.zig");
const psf = @import("psf.zig");

const fs = @import("../fs.zig");
const paging = @import("../paging.zig");
const console = @import("../console.zig");
const mem = @import("../mem.zig");

const std = @import("std");

const fb_demo_va: u32 = 0xD000_0000;
const console_shadow_va: u32 = 0xD100_0000;
const boot_video_info_magic: u32 = 0x3044_4956; // "VID0"

var active_font: psf.PSFFont = font8x8.font;
var active_font_label: []const u8 = "embedded psf1 8x8 bitmap";

const BootVideoInfo = packed struct {
    magic: u32,
    display_kind: u8,
    bpp: u8,
    _reserved0: u16,
    mode: u16,
    _reserved1: u16,
    width: u16,
    height: u16,
    pitch_bytes: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_position: u8,
    green_mask_size: u8,
    green_position: u8,
    blue_mask_size: u8,
    blue_position: u8,
    _reserved2: u8,
    phys_base_ptr: u32,
};

var info: *align(1) const BootVideoInfo = undefined;
var fb_base: [*]u8 = undefined;

var bytes_per_pixel: u32 = 0;

// For faster scrolling, we keep a shadow buffer into which we render console text.
// It's then blitted to the framebuffer on demand. This avoids slow readback from VESA memory.
var console_shadow: [*]u8 = undefined;
var console_shadow_pitch_bytes: usize = 0;
var console_shadow_rows: usize = 0;

var console_origin_x: u32 = 0;
var console_origin_y: u32 = 0;
var console_panel_x: u32 = 0;
var console_panel_y: u32 = 0;
var console_panel_w: u32 = 0;
var console_panel_h: u32 = 0;
var console_title_h: u32 = 0;
var console_cursor_row: u32 = 0;
var console_cursor_col: u32 = 0;
var console_cursor_visible: bool = false;
var console_ready: bool = false;

const screen_margin: u32 = 12;
const panel_border: u32 = 1;
const panel_padding_x: u32 = 2;
const panel_padding_y: u32 = 2;
const title_padding_y: u32 = 3;
const title_padding_x: u32 = 10;
const console_title = "zoodle86 framebuffer console";

// Default VGA 16-color palette
//const vga_palette = [16][3]u8{
//    .{ 0x00, 0x00, 0x00 },
//    .{ 0x00, 0x00, 0xAA },
//    .{ 0x00, 0xAA, 0x00 },
//    .{ 0x00, 0xAA, 0xAA },
//    .{ 0xAA, 0x00, 0x00 },
//    .{ 0xAA, 0x00, 0xAA },
//    .{ 0xAA, 0x55, 0x00 },
//    .{ 0xAA, 0xAA, 0xAA },
//    .{ 0x55, 0x55, 0x55 },
//    .{ 0x55, 0x55, 0xFF },
//    .{ 0x55, 0xFF, 0x55 },
//    .{ 0x55, 0xFF, 0xFF },
//    .{ 0xFF, 0x55, 0x55 },
//    .{ 0xFF, 0x55, 0xFF },
//    .{ 0xFF, 0xFF, 0x55 },
//    .{ 0xFF, 0xFF, 0xFF },
//};

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

// Pre-packed color values for the specific pixel format of the framebuffer
var packed_vga_palette: [16]u32 = undefined;

fn getBootVideoInfo(boot_video_info_phys: usize) !void {
    // NB: assumes identity mapping!
    info = @ptrFromInt(boot_video_info_phys);
    if (info.magic != boot_video_info_magic) return error.InvalidVideoInfo;
    if (info.display_kind != 1) return error.InvalidVideoInfo;
    if (info.width == 0 or info.height == 0 or info.pitch_bytes == 0) return error.InvalidVideoInfo;
    if (info.bpp < 15) return error.InvalidVideoInfo;
    if (info.phys_base_ptr == 0) return error.InvalidVideoInfo;
}

fn packRgb(r: u8, g: u8, b: u8) u32 {
    var value: u32 = 0;

    if (info.red_mask_size != 0) {
        const max = (@as(u32, 1) << @as(u5, @intCast(info.red_mask_size))) - 1;
        const chan = (@as(u32, r) * max) / 255;
        value |= (chan & max) << @as(u5, @intCast(info.red_position));
    }
    if (info.green_mask_size != 0) {
        const max = (@as(u32, 1) << @as(u5, @intCast(info.green_mask_size))) - 1;
        const chan = (@as(u32, g) * max) / 255;
        value |= (chan & max) << @as(u5, @intCast(info.green_position));
    }
    if (info.blue_mask_size != 0) {
        const max = (@as(u32, 1) << @as(u5, @intCast(info.blue_mask_size))) - 1;
        const chan = (@as(u32, b) * max) / 255;
        value |= (chan & max) << @as(u5, @intCast(info.blue_position));
    }

    return value;
}

fn packPaletteColor(idx: u8) u32 {
    const rgb = vga_palette[idx & 0x0F];
    return packRgb(rgb[0], rgb[1], rgb[2]);
}

fn swapAttr(attr: u8) u8 {
    return (attr << 4) | (attr >> 4);
}

fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= info.width or y >= info.height) return;

    const idx = @as(usize, y) * info.pitch_bytes + @as(usize, x) * bytes_per_pixel;
    const pixel: [*]u8 = fb_base + idx;

    var i: u32 = 0;
    while (i < bytes_per_pixel) : (i += 1) {
        pixel[i] = @truncate(color >> @as(u5, @intCast(i * 8)));
    }
}

inline fn fillScanline16(ptr: [*]u8, length: u32, color: u16) void {
    var p: [*]u16 = @ptrCast(@alignCast(ptr));
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        p[i] = color;
    }
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

fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const x_end = @min(@as(u32, info.width), x + w);
    const y_end = @min(@as(u32, info.height), y + h);

    var py = y;
    while (py < y_end) : (py += 1) {
        const pix_ptr = fb_base + py * info.pitch_bytes + x * bytes_per_pixel;
        fillScanline16(@ptrCast(pix_ptr), x_end - x, @truncate(color));
        //var px = x;
        //while (px < x_end) : (px += 1) {
        //    putPixel(px, py, color);
        //}
    }
}

fn glyphPixelIsSet(row_bitmap: u8, col: u32) bool {
    const mask: u8 = @as(u8, 0x80) >> @as(u3, @intCast(col));
    return (row_bitmap & mask) != 0;
}

fn drawGlyph(x: u32, y: u32, font: *const psf.PSFFont, ch: u8, color: u32) void {
    const glyph = font.getGlyph(ch);

    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        const row_bitmap = glyph[row];
        var col: u32 = 0;
        while (col < 8) : (col += 1) {
            if (glyphPixelIsSet(row_bitmap, col))
                putPixel(x + col, y + row, color);
        }
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

fn drawText(x: u32, y: u32, font: *const psf.PSFFont, text: []const u8, color: u32) void {
    var cursor_x = x;
    for (text) |ch| {
        drawGlyph(cursor_x, y, font, ch, color);
        cursor_x += font.glyph_width;
    }
}

pub fn init(boot_video_info_phys: usize) !void {
    try getBootVideoInfo(boot_video_info_phys);

    if (info.bpp != 16) {
        @panic("BPP-specific functions only implemented for 16 bits!");
    }

    bytes_per_pixel = @divTrunc(@as(u32, info.bpp) + 7, 8);

    const fb_size: u32 = @as(u32, info.pitch_bytes) * @as(u32, info.height);
    const phys_start = paging.roundDown(info.phys_base_ptr, paging.PAGE);
    const phys_end = paging.roundToNext(info.phys_base_ptr + fb_size, paging.PAGE);
    const num_pages: u32 = @divExact(phys_end - phys_start, paging.PAGE);

    paging.mapContiguousRangeAt(fb_demo_va, phys_start, num_pages, false, true, true);

    const fb_offset = info.phys_base_ptr - phys_start;
    fb_base = @ptrFromInt(fb_demo_va + fb_offset);
}

fn consoleCellIndex(row: u32, col: u32) usize {
    return @as(usize, @intCast(row)) * @as(usize, console.TEXT_WIDTH) + @as(usize, @intCast(col));
}

fn consoleCellWidthBytes() usize {
    return @as(usize, @intCast(active_font.glyph_width * bytes_per_pixel));
}

fn consoleCellHeightRows() usize {
    return @as(usize, @intCast(active_font.glyph_height));
}

fn fbTextBasePtr() [*]u8 {
    return fb_base + console_origin_y * info.pitch_bytes + console_origin_x * bytes_per_pixel;
}

fn shadowRowPtr(pixel_row: usize) [*]u8 {
    return console_shadow + pixel_row * console_shadow_pitch_bytes;
}

fn fbRowPtr(pixel_row: usize) [*]u8 {
    return fbTextBasePtr() + pixel_row * @as(usize, info.pitch_bytes);
}

fn blitShadowRowsToFramebuffer(start_pixel_row: usize, row_count: usize) void {
    var src = shadowRowPtr(start_pixel_row);
    var dst = fbRowPtr(start_pixel_row);
    var row: usize = 0;
    while (row < row_count) : (row += 1) {
        mem.copyBytesForward(dst, src, console_shadow_pitch_bytes);
        src += console_shadow_pitch_bytes;
        dst += info.pitch_bytes;
    }
}

fn blitShadowCellToFramebuffer(row: u32, col: u32) void {
    const start_pixel_row = @as(usize, @intCast(row * active_font.glyph_height));
    const pixel_col_offset = @as(usize, @intCast(col * active_font.glyph_width * bytes_per_pixel));
    var src = shadowRowPtr(start_pixel_row) + pixel_col_offset;
    var dst = fbRowPtr(start_pixel_row) + pixel_col_offset;
    var pixel_row: usize = 0;
    while (pixel_row < consoleCellHeightRows()) : (pixel_row += 1) {
        mem.copyBytesForward(dst, src, consoleCellWidthBytes());
        src += console_shadow_pitch_bytes;
        dst += info.pitch_bytes;
    }
}

fn drawConsoleCellRaw(cell: u16, row: u32, col: u32, highlight: bool) void {
    if (!console_ready) return;

    const font = &active_font;
    const ch: u8 = @truncate(cell & 0x00FF);
    const attr: u8 = @truncate(cell >> 8);
    const pix_ptr = shadowRowPtr(@as(usize, @intCast(row * font.glyph_height))) +
        @as(usize, @intCast(col * font.glyph_width * bytes_per_pixel));

    const effective_attr = if (highlight) swapAttr(attr) else attr;

    drawGlyphCellAt(
        pix_ptr,
        console_shadow_pitch_bytes,
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

fn drawConsoleFrame() void {
    if (!console_ready) return;

    const bg = packRgb(8, 14, 23);
    const panel = packRgb(18, 28, 42);
    const border = packRgb(56, 86, 125);
    const title_bg = packRgb(40, 92, 170);
    const title_fg = packRgb(218, 232, 249);

    fillRect(0, 0, info.width, info.height, bg);
    fillRect(console_panel_x, console_panel_y, console_panel_w, console_panel_h, border);
    fillRect(
        console_panel_x + panel_border,
        console_panel_y + panel_border,
        console_panel_w - panel_border * 2,
        console_panel_h - panel_border * 2,
        panel,
    );
    fillRect(
        console_panel_x + panel_border,
        console_panel_y + panel_border,
        console_panel_w - panel_border * 2,
        console_title_h,
        title_bg,
    );
    drawText(
        console_panel_x + panel_border + title_padding_x,
        console_panel_y + panel_border + title_padding_y,
        &active_font,
        console_title,
        title_fg,
    );
}

/// Load a PSF font file from the root filesystem and make it the active framebuffer font.
pub fn loadFont(allocator: std.mem.Allocator, disk_fs: *const fs.FileSystem, path: []const u8) !void {
    const file_data = try disk_fs.readFile(allocator, path);
    defer allocator.free(file_data);

    active_font = try psf.loadFromBytes(allocator, file_data, '?');
    if (active_font.glyph_width > 8) {
        return error.UnsupportedFont; // optimized renderer for 8px wide glyphs only
    }
    active_font_label = path;
}

/// Map the boot framebuffer and prepare the 80x25 text console renderer when graphics mode is usable.
pub fn initConsolePanel() !void {
    if (console_ready) return;

    for (0..16) |i| {
        packed_vga_palette[i] = packPaletteColor(@truncate(i));
    }

    const font = &active_font;
    const text_width = console.TEXT_WIDTH * font.glyph_width;
    const text_height = console.TEXT_HEIGHT * font.glyph_height;
    const title_text_w = console_title.len * font.glyph_width;
    const title_h = font.glyph_height + title_padding_y * 2;
    const min_inner_w = @max(text_width + panel_padding_x * 2, title_text_w + title_padding_x * 2);
    const panel_w = min_inner_w + panel_border * 2;
    const panel_h = text_height + title_h + panel_padding_y * 2 + panel_border * 2;
    if (info.width < panel_w or info.height < panel_h) return error.WindowTooLarge;

    console_panel_x = (info.width - panel_w) / 2;
    console_panel_y = (info.height - panel_h) / 2;
    console_panel_w = panel_w;
    console_panel_h = panel_h;
    console_title_h = title_h;
    console_origin_x = console_panel_x + panel_border + panel_padding_x;
    console_origin_y = console_panel_y + panel_border + console_title_h + panel_padding_y;
    console_cursor_row = 0;
    console_cursor_col = 0;
    console_cursor_visible = false;
    console_shadow_pitch_bytes = @as(usize, @intCast(text_width * bytes_per_pixel));
    console_shadow_rows = @as(usize, @intCast(text_height));
    const shadow_size = console_shadow_pitch_bytes * console_shadow_rows;
    const shadow_pages: u32 = @intCast(@divTrunc(shadow_size + paging.PAGE - 1, paging.PAGE));
    const shadow_mem = paging.allocateMemoryAt(console_shadow_va, shadow_pages, false, true);
    console_shadow = shadow_mem.ptr;
    @memset(console_shadow[0..shadow_size], 0);
    console_ready = true;

    drawConsoleFrame();
}

/// Redraw the full 80x25 console grid into the framebuffer backend.
pub fn renderConsole(cells: [*]console.Cell, cursor_row: u32, cursor_col: u32, cursor_visible: bool) void {
    if (!console_ready) return;

    const row_height_bytes = console_shadow_pitch_bytes * consoleCellHeightRows();
    var shadow_text_row_ptr = console_shadow;
    var cell_row_ptr: [*]const console.Cell = cells;
    var row: u32 = 0;
    while (row < console.TEXT_HEIGHT) : (row += 1) {
        drawConsoleRowAt(cell_row_ptr, shadow_text_row_ptr, console_shadow_pitch_bytes);
        cell_row_ptr += console.TEXT_WIDTH;
        shadow_text_row_ptr += row_height_bytes;
    }

    console_cursor_row = if (cursor_row < console.TEXT_HEIGHT) cursor_row else console.TEXT_HEIGHT - 1;
    console_cursor_col = if (cursor_col < console.TEXT_WIDTH) cursor_col else console.TEXT_WIDTH - 1;
    console_cursor_visible = cursor_visible;

    if (console_cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
    }
    blitShadowRowsToFramebuffer(0, console_shadow_rows);
}

/// Scroll the framebuffer text grid up by one console row and redraw the newly exposed bottom row.
pub fn scrollConsole(cells: [*]const console.Cell) void {
    if (!console_ready) return;

    const scrolled_bytes = (console_shadow_rows - consoleCellHeightRows()) * console_shadow_pitch_bytes;
    const scroll_src_offset = consoleCellHeightRows() * console_shadow_pitch_bytes;
    mem.copyBytesForward(console_shadow, console_shadow + scroll_src_offset, scrolled_bytes);

    const bottom_row_cells = cells + consoleCellIndex(console.TEXT_HEIGHT - 1, 0);
    const bottom_row_ptr = shadowRowPtr(console_shadow_rows - consoleCellHeightRows());
    drawConsoleRowAt(bottom_row_cells, bottom_row_ptr, console_shadow_pitch_bytes);
    blitShadowRowsToFramebuffer(0, console_shadow_rows);
}

/// Redraw a single console cell in the framebuffer backend.
pub fn renderConsoleCell(cells: [*]console.Cell, row: u32, col: u32) void {
    if (!console_ready) return;
    if (row >= console.TEXT_HEIGHT or col >= console.TEXT_WIDTH) return;

    const highlight = console_cursor_visible and row == console_cursor_row and col == console_cursor_col;
    drawConsoleCellRaw(cells[consoleCellIndex(row, col)], row, col, highlight);
    blitShadowCellToFramebuffer(row, col);
}

/// Update the highlighted framebuffer cursor by redrawing the affected console cells.
pub fn setConsoleCursor(cells: [*]const console.Cell, row: u32, col: u32, visible: bool) void {
    if (!console_ready) return;

    if (console_cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, false);
        blitShadowCellToFramebuffer(console_cursor_row, console_cursor_col);
    }

    console_cursor_row = if (row < console.TEXT_HEIGHT) row else console.TEXT_HEIGHT - 1;
    console_cursor_col = if (col < console.TEXT_WIDTH) col else console.TEXT_WIDTH - 1;
    console_cursor_visible = visible;

    if (console_cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
        blitShadowCellToFramebuffer(console_cursor_row, console_cursor_col);
    }
}

// const dim = packRgb(info, 138, 160, 188);
// const warm = packRgb(info, 237, 170, 74);
// const green = packRgb(info, 110, 212, 126);
