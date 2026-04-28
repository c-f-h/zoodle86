const font8x8 = @import("font8x8.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const fb_demo_va: u32 = 0xD000_0000;
const boot_video_info_magic: u32 = 0x3044_4956; // "VID0"

var boot_video_info_phys: u32 = 0;

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

fn getGlyph(ch: u8) *const [8]u8 {
    const glyph_ch: u8 = if (ch >= font8x8.first_printable and ch <= font8x8.last_printable) ch else '?';
    return &font8x8.glyphs[@as(usize, glyph_ch - font8x8.first_printable)];
}

fn drawGlyph(fb_base: [*]volatile u8, info: *align(1) const BootVideoInfo, x: u32, y: u32, scale: u32, ch: u8, color: u32) void {
    const glyph = getGlyph(ch);

    var row: u32 = 0;
    while (row < 8) : (row += 1) {
        const bits = glyph[row];

        var col: u32 = 0;
        while (col < 8) : (col += 1) {
            if (((bits >> @as(u3, @intCast(col))) & 1) == 0) continue;
            fillRect(fb_base, info, x + col * scale, y + row * scale, scale, scale, color);
        }
    }
}

fn drawText(fb_base: [*]volatile u8, info: *align(1) const BootVideoInfo, x: u32, y: u32, scale: u32, text: []const u8, color: u32) void {
    var cursor_x = x;
    for (text) |ch| {
        drawGlyph(fb_base, info, cursor_x, y, scale, ch, color);
        cursor_x += 8 * scale;
    }
}

fn chooseScale(info: *align(1) const BootVideoInfo) u32 {
    const width = @as(u32, info.width);
    const height = @as(u32, info.height);

    if (width >= 1280 and height >= 720) return 3;
    if (width >= 800 and height >= 600) return 2;
    return 1;
}

fn appendChar(buf: []u8, len: *usize, ch: u8) void {
    if (len.* >= buf.len) @panic("framebuffer text buffer overflow");
    buf[len.*] = ch;
    len.* += 1;
}

fn appendSlice(buf: []u8, len: *usize, text: []const u8) void {
    if (len.* + text.len > buf.len) @panic("framebuffer text buffer overflow");
    @memcpy(buf[len.* .. len.* + text.len], text);
    len.* += text.len;
}

fn appendDecU32(buf: []u8, len: *usize, value: u32) void {
    if (value == 0) {
        appendChar(buf, len, '0');
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
        appendChar(buf, len, digits[count]);
    }
}

fn buildModeLine(info: *align(1) const BootVideoInfo, out: *[32]u8) []const u8 {
    var len: usize = 0;
    appendSlice(out, &len, "mode ");
    appendDecU32(out, &len, info.width);
    appendChar(out, &len, 'x');
    appendDecU32(out, &len, info.height);
    appendChar(out, &len, 'x');
    appendDecU32(out, &len, info.bpp);
    return out[0..len];
}

/// Record the physical address of boot video metadata prepared by stage 2.
pub fn init(video_info_phys: u32) void {
    boot_video_info_phys = video_info_phys;
}

/// Map the boot framebuffer and draw a text-mode style diagnostic demo when VBE metadata is valid.
pub fn tryDrawBootDemo() void {
    const info = getBootVideoInfo() orelse return;

    const fb_size: u32 = @as(u32, info.pitch_bytes) * @as(u32, info.height);
    const phys_start = paging.roundDown(info.phys_base_ptr, paging.PAGE);
    const phys_end = paging.roundToNext(info.phys_base_ptr + fb_size, paging.PAGE);
    const num_pages: u32 = @divExact(phys_end - phys_start, paging.PAGE);

    paging.mapContiguousRangeAt(fb_demo_va, phys_start, num_pages, false, true, true);

    const fb_offset = info.phys_base_ptr - phys_start;
    const fb_base: [*]volatile u8 = @ptrFromInt(fb_demo_va + fb_offset);

    const width = @as(u32, info.width);
    const height = @as(u32, info.height);
    const scale = chooseScale(info);
    const margin = 12 * scale;
    const panel_padding = 10 * scale;
    const panel_x = margin;
    const panel_y = margin;
    const panel_max_w = if (width > panel_x * 2) width - panel_x * 2 else width;
    const panel_max_h = if (height > panel_y * 2) height - panel_y * 2 else height;
    const panel_w = @min(panel_max_w, 66 * 8 * scale + panel_padding * 2);
    const panel_h = @min(panel_max_h, 20 * 8 * scale + panel_padding * 2);
    const title_h = 12 * scale;
    const title_text_y = panel_y + scale + 2 * scale;
    const line_step = 10 * scale;
    const text_x = panel_x + panel_padding;
    const swatch_y = panel_y + panel_h - panel_padding - 6 * scale;

    const bg = packRgb(info, 8, 14, 23);
    const panel = packRgb(info, 18, 28, 42);
    const panel_border = packRgb(info, 56, 86, 125);
    const title_bg = packRgb(info, 40, 92, 170);
    const fg = packRgb(info, 218, 232, 249);
    const dim = packRgb(info, 138, 160, 188);
    const warm = packRgb(info, 237, 170, 74);
    const green = packRgb(info, 110, 212, 126);
    const red = packRgb(info, 219, 92, 92);

    fillRect(fb_base, info, 0, 0, width, height, bg);
    fillRect(fb_base, info, panel_x, panel_y, panel_w, panel_h, panel_border);
    fillRect(fb_base, info, panel_x + scale, panel_y + scale, panel_w - scale * 2, panel_h - scale * 2, panel);
    fillRect(fb_base, info, panel_x + scale, panel_y + scale, panel_w - scale * 2, title_h, title_bg);

    var mode_buf: [32]u8 = undefined;
    const mode_line = buildModeLine(info, &mode_buf);

    drawText(fb_base, info, text_x, title_text_y, scale, "zoodle86 framebuffer text demo", fg);
    var y: u32 = panel_y + scale + title_h + panel_padding;
    drawText(fb_base, info, text_x, y, scale, "font  public-domain 8x8 VGA bitmap", dim);
    y += line_step;
    drawText(fb_base, info, text_x, y, scale, mode_line, dim);
    y += line_step * 2;
    drawText(fb_base, info, text_x, y, scale, "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", fg);
    y += line_step;
    drawText(fb_base, info, text_x, y, scale, "the quick brown fox jumps over the lazy dog", fg);
    y += line_step;
    drawText(fb_base, info, text_x, y, scale, "0123456789  !@#$%^&*()  []{}<>?/+-=_", fg);
    y += line_step * 2;
    drawText(fb_base, info, text_x, y, scale, "shell> run hello framebuffer", warm);
    y += line_step;
    drawText(fb_base, info, text_x, y, scale, "status: text renderer online", green);
    y += line_step;
    drawText(fb_base, info, text_x, y, scale, "fallback glyphs: ~ | {} [] ()", dim);

    fillRect(fb_base, info, text_x, swatch_y, 12 * scale, 4 * scale, title_bg);
    fillRect(fb_base, info, text_x + 16 * scale, swatch_y, 12 * scale, 4 * scale, green);
    fillRect(fb_base, info, text_x + 32 * scale, swatch_y, 12 * scale, 4 * scale, red);

    serial.puts("Framebuffer demo: rendered text with public-domain 8x8 font\n");
}
