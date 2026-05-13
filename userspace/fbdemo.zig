const std = @import("std");
const sys = @import("sys.zig");

fn pixelOffset(info: *const sys.FrameBufInfo, x: u32, y: u32) ?usize {
    if (x >= info.width or y >= info.height) return null;

    const row_bytes = std.math.mul(usize, @as(usize, y), @as(usize, info.pitch_bytes)) catch return null;
    const pixel_bytes = std.math.mul(usize, @as(usize, x), @as(usize, info.bytes_per_pixel)) catch return null;
    const offset = std.math.add(usize, row_bytes, pixel_bytes) catch return null;
    if (offset + @as(usize, info.bytes_per_pixel) > @as(usize, info.mapped_len)) return null;
    return offset;
}

fn putPixel(info: *const sys.FrameBufInfo, x: u32, y: u32, color: u32) void {
    const offset = pixelOffset(info, x, y) orelse return;
    const fb: [*]u8 = @ptrFromInt(info.mapped_ptr);

    var i: u32 = 0;
    while (i < info.bytes_per_pixel) : (i += 1) {
        fb[offset + i] = @truncate(color >> @as(u5, @intCast(i * 8)));
    }
}

fn fillRect(info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const x_end = @min(info.width, x + w);
    const y_end = @min(info.height, y + h);

    var py = y;
    while (py < y_end) : (py += 1) {
        var px = x;
        while (px < x_end) : (px += 1) {
            putPixel(info, px, py, color);
        }
    }
}

fn drawFrame(info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (w == 0 or h == 0) return;
    fillRect(info, x, y, w, 1, color);
    fillRect(info, x, y + h - 1, w, 1, color);
    fillRect(info, x, y, 1, h, color);
    fillRect(info, x + w - 1, y, 1, h, color);
}

fn drawGradientBar(info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    const denom: u32 = if (w > 1) w - 1 else 1;

    var px: u32 = 0;
    while (px < w) : (px += 1) {
        const t = @divTrunc(px * 255, denom);
        const color = info.packRgb(@intCast(t), @intCast(255 - t), @intCast((t / 2) + 48));
        fillRect(info, x + px, y, 1, h, color);
    }
}

fn drawCheckerboard(info: *const sys.FrameBufInfo, x: u32, y: u32, size: u32, cell: u32, color_a: u32, color_b: u32) void {
    if (size == 0 or cell == 0) return;

    var py: u32 = 0;
    while (py < size) : (py += 1) {
        var px: u32 = 0;
        while (px < size) : (px += 1) {
            const tile = ((px / cell) + (py / cell)) & 1;
            putPixel(info, x + px, y + py, if (tile == 0) color_a else color_b);
        }
    }
}

fn drawDiagonalCross(info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32, color_a: u32, color_b: u32) void {
    const steps = @min(w, h);
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        putPixel(info, x + i, y + i, color_a);
        putPixel(info, x + (w - 1 - i), y + i, color_b);
    }
}

fn drawPattern(info: *const sys.FrameBufInfo) void {
    const margin_x = @min(info.width / 12, 48);
    const margin_y = @min(info.height / 12, 32);
    const box_w = if (info.width > margin_x * 2) info.width - margin_x * 2 else info.width;
    const box_h = if (info.height > margin_y * 2) info.height - margin_y * 2 else info.height;
    const box_x = if (info.width > box_w) (info.width - box_w) / 2 else 0;
    const box_y = if (info.height > box_h) (info.height - box_h) / 2 else 0;

    const bg = info.packRgb(10, 18, 38);
    const frame_outer = info.packRgb(245, 245, 245);
    const frame_inner = info.packRgb(48, 64, 88);
    const red = info.packRgb(255, 80, 80);
    const green = info.packRgb(80, 255, 120);
    const blue = info.packRgb(96, 160, 255);
    const white = info.packRgb(255, 255, 255);

    fillRect(info, box_x, box_y, box_w, box_h, bg);
    drawFrame(info, box_x, box_y, box_w, box_h, frame_outer);
    if (box_w > 4 and box_h > 4) {
        drawFrame(info, box_x + 2, box_y + 2, box_w - 4, box_h - 4, frame_inner);
    }

    const bar_x = box_x + @min(box_w / 12, 24);
    const bar_y = box_y + @min(box_h / 10, 18);
    const bar_w = if (box_w > (bar_x - box_x) * 2) box_w - (bar_x - box_x) * 2 else box_w;
    const bar_h = @min(@max(box_h / 8, 24), if (box_h > 36) box_h - 36 else box_h);
    drawGradientBar(info, bar_x, bar_y, bar_w, bar_h);

    const board_size = @min(box_w, box_h) / 3;
    const board_cell = @max(board_size / 8, 6);
    const board_x = box_x + (box_w - board_size) / 2;
    const board_y = box_y + (box_h - board_size) / 2;
    drawCheckerboard(info, board_x, board_y, board_size, board_cell, white, info.packRgb(32, 32, 48));
    drawFrame(info, board_x, board_y, board_size, board_size, frame_outer);

    if (box_w > 16 and box_h > 16) {
        drawDiagonalCross(info, box_x + 8, box_y + 8, box_w - 16, box_h - 16, red, blue);
    }

    const swatch = @max(@min(box_w, box_h) / 10, 12);
    fillRect(info, box_x + 12, box_y + box_h - swatch - 12, swatch, swatch, red);
    fillRect(info, box_x + 18 + swatch, box_y + box_h - swatch - 12, swatch, swatch, green);
    fillRect(info, box_x + 24 + swatch * 2, box_y + box_h - swatch - 12, swatch, swatch, blue);
}

/// Queries the framebuffer syscall, draws a test pattern, and restores the original contents after a keypress.
pub fn main(_: []const []const u8) !void {
    var info: sys.FrameBufInfo = .{};
    try sys.getFrameBuf(&info);

    const mapped_len: usize = @intCast(info.mapped_len);
    const fb: [*]u8 = @ptrFromInt(info.mapped_ptr);
    const mapped = fb[0..mapped_len];

    const saved = try sys.changeHeapSize(@intCast(mapped_len));
    @memcpy(saved, mapped);
    defer @memcpy(mapped, saved);

    var buf: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "fbdemo: {d}x{d}, pitch={d}, bpp={d}, ptr=0x{x}, len={d}\n",
        .{ info.width, info.height, info.pitch_bytes, info.bits_per_pixel, info.mapped_ptr, info.mapped_len },
    );
    try sys.writeAll(sys.STDOUT, line);

    drawPattern(&info);
    try sys.writeAll(sys.STDOUT, "fbdemo: press any key to restore the framebuffer\n");
    _ = try sys.waitKey();
}

comptime {
    _ = sys._start;
}
