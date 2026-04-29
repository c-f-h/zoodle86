const paging = @import("../paging.zig");
const psf = @import("psf.zig");

const boot_video_info_magic: u32 = 0x3044_4956; // "VID0"
const fb_demo_va: u32 = 0xD000_0000;

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

fn getBootVideoInfo(boot_video_info_phys: usize) !void {
    // NB: assumes identity mapping!
    info = @ptrFromInt(boot_video_info_phys);
    if (info.magic != boot_video_info_magic) return error.InvalidVideoInfo;
    if (info.display_kind != 1) return error.InvalidVideoInfo;
    if (info.width == 0 or info.height == 0 or info.pitch_bytes == 0) return error.InvalidVideoInfo;
    if (info.bpp < 15) return error.InvalidVideoInfo;
    if (info.phys_base_ptr == 0) return error.InvalidVideoInfo;
}

/// Pack an RGB color into the current framebuffer's native pixel format.
pub fn packRgb(r: u8, g: u8, b: u8) u32 {
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

fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= info.width or y >= info.height) return;

    const pixel = pixelPtr(x, y);
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

/// Fill a rectangular region of the framebuffer with a packed pixel value.
pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const x_end = @min(@as(u32, info.width), x + w);
    const y_end = @min(@as(u32, info.height), y + h);

    var py = y;
    while (py < y_end) : (py += 1) {
        fillScanline16(pixelPtr(x, py), x_end - x, @truncate(color));
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

/// Draw an ASCII string with the supplied PSF font at pixel coordinates.
pub fn drawText(x: u32, y: u32, font: *const psf.PSFFont, text: []const u8, color: u32) void {
    var cursor_x = x;
    for (text) |ch| {
        drawGlyph(cursor_x, y, font, ch, color);
        cursor_x += font.glyph_width;
    }
}

/// Validate and map the boot framebuffer into the kernel address space.
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

/// Return the mapped framebuffer width in pixels.
pub fn width() u32 {
    return info.width;
}

/// Return the mapped framebuffer height in pixels.
pub fn height() u32 {
    return info.height;
}

/// Return the number of bytes between adjacent framebuffer scanlines.
pub fn pitchBytes() usize {
    return @as(usize, info.pitch_bytes);
}

/// Return the number of bytes used by each framebuffer pixel.
pub fn bytesPerPixel() usize {
    return @as(usize, bytes_per_pixel);
}

/// Return a pointer to the framebuffer pixel at the given coordinates.
pub fn pixelPtr(x: u32, y: u32) [*]u8 {
    return fb_base + @as(usize, y) * @as(usize, info.pitch_bytes) + @as(usize, x) * @as(usize, bytes_per_pixel);
}
