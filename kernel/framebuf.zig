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

/// Record the physical address of boot video metadata prepared by stage 2.
pub fn init(video_info_phys: u32) void {
    boot_video_info_phys = video_info_phys;
}

/// Map the boot framebuffer and draw a simple diagnostic pattern when VBE metadata is valid.
pub fn tryDrawBootDemo() void {
    const info = getBootVideoInfo() orelse return;

    const fb_size: u32 = @as(u32, info.pitch_bytes) * @as(u32, info.height);
    const phys_start = paging.roundDown(info.phys_base_ptr, paging.PAGE);
    const phys_end = paging.roundToNext(info.phys_base_ptr + fb_size, paging.PAGE);
    const num_pages: u32 = @divExact(phys_end - phys_start, paging.PAGE);

    paging.mapContiguousRangeAt(fb_demo_va, phys_start, num_pages, false, true, true);

    const fb_offset = info.phys_base_ptr - phys_start;
    const fb_base: [*]volatile u8 = @ptrFromInt(fb_demo_va + fb_offset);

    const bg = packRgb(info, 12, 20, 34);
    const red = packRgb(info, 208, 64, 64);
    const green = packRgb(info, 64, 200, 96);
    const blue = packRgb(info, 64, 112, 224);

    fillRect(fb_base, info, 0, 0, info.width, info.height, bg);
    fillRect(fb_base, info, 24, 24, @as(u32, info.width) / 2, @as(u32, info.height) / 3, red);
    fillRect(fb_base, info, @as(u32, info.width) / 4, @as(u32, info.height) / 3, @as(u32, info.width) / 2, @as(u32, info.height) / 3, green);
    fillRect(fb_base, info, @as(u32, info.width) / 3, @as(u32, info.height) / 2, @as(u32, info.width) / 2, @as(u32, info.height) / 3, blue);

    serial.puts("Framebuffer demo: drew boot rectangles\n");
}
