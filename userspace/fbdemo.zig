const std = @import("std");
const heap = @import("allocator.zig");
const sys = @import("sys.zig");

fn pixelOffset(frame: []const u8, info: *const sys.FrameBufInfo, x: u32, y: u32) ?usize {
    if (x >= info.width or y >= info.height) return null;

    const row_bytes = std.math.mul(usize, @as(usize, y), @as(usize, info.pitch_bytes)) catch return null;
    const pixel_bytes = std.math.mul(usize, @as(usize, x), @as(usize, info.bytes_per_pixel)) catch return null;
    const offset = std.math.add(usize, row_bytes, pixel_bytes) catch return null;
    if (offset + @as(usize, info.bytes_per_pixel) > frame.len) return null;
    return offset;
}

fn putPixel(frame: []u8, info: *const sys.FrameBufInfo, x: u32, y: u32, color: u32) void {
    const offset = pixelOffset(frame, info, x, y) orelse return;

    var i: u32 = 0;
    while (i < info.bytes_per_pixel) : (i += 1) {
        frame[offset + i] = @truncate(color >> @as(u5, @intCast(i * 8)));
    }
}

fn fillRect(frame: []u8, info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const x_end = @min(info.width, x + w);
    const y_end = @min(info.height, y + h);

    var py = y;
    while (py < y_end) : (py += 1) {
        var px = x;
        while (px < x_end) : (px += 1) {
            putPixel(frame, info, px, py, color);
        }
    }
}

fn drawFrame(frame: []u8, info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (w == 0 or h == 0) return;
    fillRect(frame, info, x, y, w, 1, color);
    fillRect(frame, info, x, y + h - 1, w, 1, color);
    fillRect(frame, info, x, y, 1, h, color);
    fillRect(frame, info, x + w - 1, y, 1, h, color);
}

fn drawGradientBar(frame: []u8, info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    const denom: u32 = if (w > 1) w - 1 else 1;

    var px: u32 = 0;
    while (px < w) : (px += 1) {
        const t = @divTrunc(px * 255, denom);
        const color = info.packRgb(@intCast(t), @intCast(255 - t), @intCast((t / 2) + 48));
        fillRect(frame, info, x + px, y, 1, h, color);
    }
}

fn drawCheckerboard(frame: []u8, info: *const sys.FrameBufInfo, x: u32, y: u32, size: u32, cell: u32, color_a: u32, color_b: u32) void {
    if (size == 0 or cell == 0) return;

    var py: u32 = 0;
    while (py < size) : (py += 1) {
        var px: u32 = 0;
        while (px < size) : (px += 1) {
            const tile = ((px / cell) + (py / cell)) & 1;
            putPixel(frame, info, x + px, y + py, if (tile == 0) color_a else color_b);
        }
    }
}

fn drawDiagonalCross(frame: []u8, info: *const sys.FrameBufInfo, x: u32, y: u32, w: u32, h: u32, color_a: u32, color_b: u32) void {
    const steps = @min(w, h);
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        putPixel(frame, info, x + i, y + i, color_a);
        putPixel(frame, info, x + (w - 1 - i), y + i, color_b);
    }
}

fn drawPattern(frame: []u8, info: *const sys.FrameBufInfo) void {
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

    fillRect(frame, info, box_x, box_y, box_w, box_h, bg);
    drawFrame(frame, info, box_x, box_y, box_w, box_h, frame_outer);
    if (box_w > 4 and box_h > 4) {
        drawFrame(frame, info, box_x + 2, box_y + 2, box_w - 4, box_h - 4, frame_inner);
    }

    const bar_x = box_x + @min(box_w / 12, 24);
    const bar_y = box_y + @min(box_h / 10, 18);
    const bar_w = if (box_w > (bar_x - box_x) * 2) box_w - (bar_x - box_x) * 2 else box_w;
    const bar_h = @min(@max(box_h / 8, 24), if (box_h > 36) box_h - 36 else box_h);
    drawGradientBar(frame, info, bar_x, bar_y, bar_w, bar_h);

    const board_size = @min(box_w, box_h) / 3;
    const board_cell = @max(board_size / 8, 6);
    const board_x = box_x + (box_w - board_size) / 2;
    const board_y = box_y + (box_h - board_size) / 2;
    drawCheckerboard(frame, info, board_x, board_y, board_size, board_cell, white, info.packRgb(32, 32, 48));
    drawFrame(frame, info, board_x, board_y, board_size, board_size, frame_outer);

    if (box_w > 16 and box_h > 16) {
        drawDiagonalCross(frame, info, box_x + 8, box_y + 8, box_w - 16, box_h - 16, red, blue);
    }

    const swatch = @max(@min(box_w, box_h) / 10, 12);
    fillRect(frame, info, box_x + 12, box_y + box_h - swatch - 12, swatch, swatch, red);
    fillRect(frame, info, box_x + 18 + swatch, box_y + box_h - swatch - 12, swatch, swatch, green);
    fillRect(frame, info, box_x + 24 + swatch * 2, box_y + box_h - swatch - 12, swatch, swatch, blue);
}

fn readExact(fd: u32, dest: []u8) !void {
    var offset: usize = 0;
    while (offset < dest.len) {
        const chunk = try sys.read(fd, dest[offset..]);
        if (chunk == 0) return error.UnexpectedEof;
        offset += @intCast(chunk);
    }
}

/// Reads `/dev/fb0`, draws a test pattern, and restores the original contents after a keypress.
pub fn main(_: []const []const u8) !void {
    const alloc = heap.getAllocator();
    const fb_fd = try sys.open("/dev/fb0", .{ .open_mode = .ReadWrite });
    defer sys.close(fb_fd) catch {};

    var info: sys.FrameBufInfo = .{};
    try sys.getFrameBufInfo(fb_fd, &info);

    var st: sys.Stat = undefined;
    try sys.fstat(fb_fd, &st);
    const fb_len: usize = @intCast(st.size);
    const saved = try alloc.alloc(u8, fb_len);
    defer alloc.free(saved);
    const frame = try alloc.alloc(u8, fb_len);
    defer alloc.free(frame);

    _ = try sys.lseek(fb_fd, 0, .Set);
    try readExact(fb_fd, saved);
    @memcpy(frame, saved);
    defer {
        _ = sys.lseek(fb_fd, 0, .Set) catch {};
        sys.writeAll(fb_fd, saved) catch {};
    }

    var buf: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "fbdemo: {d}x{d}, pitch={d}, bpp={d}, fd={d}, len={d}\n",
        .{ info.width, info.height, info.pitch_bytes, info.bits_per_pixel, fb_fd, st.size },
    );
    try sys.writeAll(sys.STDOUT, line);

    drawPattern(frame, &info);
    _ = try sys.lseek(fb_fd, 0, .Set);
    try sys.writeAll(fb_fd, frame);
    try sys.writeAll(sys.STDOUT, "fbdemo: press any key\n");
    _ = try sys.waitKey();
}

comptime {
    _ = sys._start;
}
