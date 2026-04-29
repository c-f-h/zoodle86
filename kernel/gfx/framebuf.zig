const font8x8 = @import("font8x8.zig");
const fs = @import("../fs.zig");
const paging = @import("../paging.zig");
const psf = @import("psf.zig");
const std = @import("std");
const console = @import("../console.zig");

const fb_demo_va: u32 = 0xD000_0000;
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

inline fn blitScanline16(ptr: [*]u8, bitmap: []const u8, bit_count: u32, color0: u16, color1: u16) void {
    var p: [*]u16 = @ptrCast(@alignCast(ptr));
    var bit: u32 = 0;
    while (bit < bit_count) : (bit += 1) {
        const byte = bitmap[@as(usize, @intCast(@divTrunc(bit, 8)))];
        const mask: u8 = @as(u8, 0x80) >> @intCast(bit & 0x07);
        p[bit] = if ((byte & mask) != 0) color1 else color0;
    }
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

fn glyphPixelIsSet(font: *const psf.PSFFont, glyph: []const u8, row: u32, col: u32) bool {
    const row_start = @as(usize, row * font.bytes_per_row);
    const byte_index = row_start + @as(usize, @intCast(@divTrunc(col, 8)));
    const mask: u8 = @as(u8, 0x80) >> @as(u3, @intCast(col % 8));
    return (glyph[byte_index] & mask) != 0;
}

fn drawGlyph(x: u32, y: u32, font: *const psf.PSFFont, ch: u8, color: u32) void {
    const glyph = font.getGlyph(ch);

    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        var col: u32 = 0;
        while (col < font.glyph_width) : (col += 1) {
            if (!glyphPixelIsSet(font, glyph, row, col)) continue;
            putPixel(x + col, y + row, color);
        }
    }
}

fn drawGlyphCell(
    x: u32,
    y: u32,
    font: *const psf.PSFFont,
    ch: u8,
    attr: u8,
    highlight: bool,
) void {
    const effective_attr = if (highlight) swapAttr(attr) else attr;
    const bg: u16 = @truncate(packPaletteColor(@truncate(effective_attr >> 4)));
    const fg: u16 = @truncate(packPaletteColor(effective_attr & 0x0F));
    const glyph = font.getGlyph(ch);

    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        const row_start = @as(usize, row * font.bytes_per_row);
        const row_bitmap = glyph[row_start .. row_start + @as(usize, font.bytes_per_row)];
        const pix_ptr = fb_base + (y + row) * info.pitch_bytes + x * bytes_per_pixel;
        blitScanline16(@ptrCast(pix_ptr), row_bitmap, font.glyph_width, bg, fg);
    }
}

fn drawText(x: u32, y: u32, font: *const psf.PSFFont, text: []const u8, color: u32) u32 {
    var cursor_x = x;
    for (text) |ch| {
        drawGlyph(cursor_x, y, font, ch, color);
        cursor_x += font.glyph_width;
    }
    return cursor_x;
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

fn drawConsoleCellRaw(cell: u16, row: u32, col: u32, highlight: bool) void {
    if (!console_ready) return;

    const font = &active_font;
    const ch: u8 = @truncate(cell & 0x00FF);
    const attr: u8 = @truncate(cell >> 8);
    const px = console_origin_x + col * font.glyph_width;
    const py = console_origin_y + row * font.glyph_height;

    drawGlyphCell(
        px,
        py,
        font,
        if (ch == 0) ' ' else ch,
        attr,
        highlight,
    );
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
    _ = drawText(
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
    active_font_label = path;
}

/// Map the boot framebuffer and prepare the 80x25 text console renderer when graphics mode is usable.
pub fn initConsolePanel() !void {
    if (console_ready) return;

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
    console_ready = true;

    drawConsoleFrame();
}

/// Redraw the full 80x25 console grid into the framebuffer backend.
pub fn renderConsole(cells: [*]console.Cell, cursor_row: u32, cursor_col: u32, cursor_visible: bool) void {
    if (!console_ready) return;

    var row: u32 = 0;
    while (row < console.TEXT_HEIGHT) : (row += 1) {
        var col: u32 = 0;
        while (col < console.TEXT_WIDTH) : (col += 1) {
            drawConsoleCellRaw(cells[consoleCellIndex(row, col)], row, col, false);
        }
    }

    console_cursor_row = if (cursor_row < console.TEXT_HEIGHT) cursor_row else console.TEXT_HEIGHT - 1;
    console_cursor_col = if (cursor_col < console.TEXT_WIDTH) cursor_col else console.TEXT_WIDTH - 1;
    console_cursor_visible = cursor_visible;

    if (console_cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
    }
}

/// Redraw a single console cell in the framebuffer backend.
pub fn renderConsoleCell(cells: [*]console.Cell, row: u32, col: u32) void {
    if (!console_ready) return;
    if (row >= console.TEXT_HEIGHT or col >= console.TEXT_WIDTH) return;

    const highlight = console_cursor_visible and row == console_cursor_row and col == console_cursor_col;
    drawConsoleCellRaw(cells[consoleCellIndex(row, col)], row, col, highlight);
}

/// Update the highlighted framebuffer cursor by redrawing the affected console cells.
pub fn setConsoleCursor(cells: [*]const console.Cell, row: u32, col: u32, visible: bool) void {
    if (!console_ready) return;

    if (console_cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, false);
    }

    console_cursor_row = if (row < console.TEXT_HEIGHT) row else console.TEXT_HEIGHT - 1;
    console_cursor_col = if (col < console.TEXT_WIDTH) col else console.TEXT_WIDTH - 1;
    console_cursor_visible = visible;

    if (console_cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
    }
}

/// Map the boot framebuffer and draw a text-mode style diagnostic demo when VBE metadata is valid.
pub fn tryDrawBootDemo() void {
    const font = &active_font;

    const width = @as(u32, info.width);
    const height = @as(u32, info.height);
    const glyph_height = font.glyph_height;
    const margin: u32 = 12;
    const panel_padding: u32 = 10;
    const panel_x = margin;
    const panel_y = margin;
    const panel_max_w = if (width > panel_x * 2) width - panel_x * 2 else width;
    const panel_max_h = if (height > panel_y * 2) height - panel_y * 2 else height;
    const panel_w = @min(panel_max_w, 66 * font.glyph_width + panel_padding * 2);
    const title_h = glyph_height + 4;
    const line_step = glyph_height + 2;
    const panel_h = @min(panel_max_h, title_h + panel_padding * 2 + line_step * 13);
    const title_text_y = panel_y + 3;
    const text_x = panel_x + panel_padding;

    const bg = packRgb(info, 8, 14, 23);
    const panel = packRgb(info, 18, 28, 42);
    const panel_border_color = packRgb(info, 56, 86, 125);
    const title_bg = packRgb(info, 40, 92, 170);
    const fg = packRgb(info, 218, 232, 249);
    const dim = packRgb(info, 138, 160, 188);
    const warm = packRgb(info, 237, 170, 74);
    const green = packRgb(info, 110, 212, 126);

    fillRect(fb_base, info, 0, 0, width, height, bg);
    fillRect(fb_base, info, panel_x, panel_y, panel_w, panel_h, panel_border_color);
    fillRect(fb_base, info, panel_x + 1, panel_y + 1, panel_w - 2, panel_h - 2, panel);
    fillRect(fb_base, info, panel_x + 1, panel_y + 1, panel_w - 2, title_h, title_bg);

    var mode_buf: [32]u8 = undefined;
    const mode_line = std.fmt.bufPrint(&mode_buf, "mode {d}x{d}x{d}", .{ info.width, info.height, info.bpp }) catch @panic("framebuffer text buffer overflow");

    _ = drawText(fb_base, info, text_x, title_text_y, font, "zoodle86 framebuffer text demo", fg);
    var y: u32 = panel_y + 1 + title_h + panel_padding;
    const xnew = drawText(fb_base, info, text_x, y, font, "font ", dim);
    _ = drawText(fb_base, info, xnew, y, font, active_font_label, dim);
    y += line_step;
    _ = drawText(fb_base, info, text_x, y, font, mode_line, dim);
    y += line_step * 2;
    _ = drawText(fb_base, info, text_x, y, font, "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", fg);
    y += line_step;
    _ = drawText(fb_base, info, text_x, y, font, "the quick brown fox jumps over the lazy dog", fg);
    y += line_step;
    _ = drawText(fb_base, info, text_x, y, font, "0123456789  !@#$%^&*()  []{}<>?/+-=_", fg);
    y += line_step * 2;
    _ = drawText(fb_base, info, text_x, y, font, "shell> run hello framebuffer", warm);
    y += line_step;
    _ = drawText(fb_base, info, text_x, y, font, "status: text renderer online", green);
    y += line_step;
    _ = drawText(fb_base, info, text_x, y, font, "fallback glyphs: ~ | {} [] ()", dim);
}
