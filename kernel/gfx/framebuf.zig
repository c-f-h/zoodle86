const font8x8 = @import("font8x8.zig");
const fs = @import("../fs.zig");
const paging = @import("../paging.zig");
const psf = @import("psf.zig");
const std = @import("std");

const fb_demo_va: u32 = 0xD000_0000;
const boot_video_info_magic: u32 = 0x3044_4956; // "VID0"

var boot_video_info_phys: u32 = 0;
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

fn getBootVideoInfo() ?*align(1) const BootVideoInfo {
    if (boot_video_info_phys == 0) return null;

    const info: *align(1) const BootVideoInfo = @ptrFromInt(boot_video_info_phys);
    if (info.magic != boot_video_info_magic) return null;
    if (info.display_kind != 1) return null;
    if (info.width == 0 or info.height == 0 or info.pitch_bytes == 0) return null;
    if (info.bpp < 15) return null;
    if (info.phys_base_ptr == 0) return null;
    return info;
}

fn packRgb(info: *align(1) const BootVideoInfo, r: u8, g: u8, b: u8) u32 {
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

fn putPixel(fb_base: [*]volatile u8, info: *align(1) const BootVideoInfo, x: u32, y: u32, color: u32) void {
    if (x >= info.width or y >= info.height) return;

    const bytes_per_pixel: u32 = @divTrunc(@as(u32, info.bpp) + 7, 8);
    const idx = @as(usize, y) * info.pitch_bytes + @as(usize, x) * bytes_per_pixel;
    const pixel: [*]volatile u8 = fb_base + idx;

    var i: u32 = 0;
    while (i < bytes_per_pixel) : (i += 1) {
        pixel[i] = @truncate(color >> @as(u5, @intCast(i * 8)));
    }
}

fn fillRect(fb_base: [*]volatile u8, info: *align(1) const BootVideoInfo, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const x_end = @min(@as(u32, info.width), x + w);
    const y_end = @min(@as(u32, info.height), y + h);

    var py = y;
    while (py < y_end) : (py += 1) {
        var px = x;
        while (px < x_end) : (px += 1) {
            putPixel(fb_base, info, px, py, color);
        }
    }
}

fn glyphPixelIsSet(font: *const psf.PSFFont, glyph: []const u8, row: u32, col: u32) bool {
    const row_start = @as(usize, row * font.bytes_per_row);
    const byte_index = row_start + @as(usize, @intCast(@divTrunc(col, 8)));
    const mask: u8 = @as(u8, 0x80) >> @as(u3, @intCast(col % 8));
    return (glyph[byte_index] & mask) != 0;
}

fn drawGlyph(fb_base: [*]volatile u8, info: *align(1) const BootVideoInfo, x: u32, y: u32, font: *const psf.PSFFont, ch: u8, color: u32) void {
    const glyph = font.getGlyph(ch);

    var row: u32 = 0;
    while (row < font.glyph_height) : (row += 1) {
        var col: u32 = 0;
        while (col < font.glyph_width) : (col += 1) {
            if (!glyphPixelIsSet(font, glyph, row, col)) continue;
            putPixel(fb_base, info, x + col, y + row, color);
        }
    }
}

fn drawText(fb_base: [*]volatile u8, info: *align(1) const BootVideoInfo, x: u32, y: u32, font: *const psf.PSFFont, text: []const u8, color: u32) u32 {
    var cursor_x = x;
    for (text) |ch| {
        drawGlyph(fb_base, info, cursor_x, y, font, ch, color);
        cursor_x += font.glyph_width;
    }
    return cursor_x;
}

/// Record the physical address of boot video metadata prepared by stage 2.
pub fn init(video_info_phys: u32) void {
    boot_video_info_phys = video_info_phys;
}

/// Load a PSF font file from the root filesystem and make it the active framebuffer font.
pub fn loadFont(allocator: std.mem.Allocator, disk_fs: *const fs.FileSystem, path: []const u8) !void {
    const file_data = try disk_fs.readFile(allocator, path);
    defer allocator.free(file_data);

    active_font = try psf.loadFromBytes(allocator, file_data, '?');
    active_font_label = path;
}

/// Map the boot framebuffer and draw a text-mode style diagnostic demo when VBE metadata is valid.
pub fn tryDrawBootDemo() void {
    const info = getBootVideoInfo() orelse return;
    const font = &active_font;

    const fb_size: u32 = @as(u32, info.pitch_bytes) * @as(u32, info.height);
    const phys_start = paging.roundDown(info.phys_base_ptr, paging.PAGE);
    const phys_end = paging.roundToNext(info.phys_base_ptr + fb_size, paging.PAGE);
    const num_pages: u32 = @divExact(phys_end - phys_start, paging.PAGE);

    paging.mapContiguousRangeAt(fb_demo_va, phys_start, num_pages, false, true, true);

    const fb_offset = info.phys_base_ptr - phys_start;
    const fb_base: [*]volatile u8 = @ptrFromInt(fb_demo_va + fb_offset);

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
    const panel_border = packRgb(info, 56, 86, 125);
    const title_bg = packRgb(info, 40, 92, 170);
    const fg = packRgb(info, 218, 232, 249);
    const dim = packRgb(info, 138, 160, 188);
    const warm = packRgb(info, 237, 170, 74);
    const green = packRgb(info, 110, 212, 126);

    fillRect(fb_base, info, 0, 0, width, height, bg);
    fillRect(fb_base, info, panel_x, panel_y, panel_w, panel_h, panel_border);
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
