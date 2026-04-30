const font8x8 = @import("font8x8.zig");
const framebuf = @import("framebuf.zig");
const psf = @import("psf.zig");
const window = @import("window.zig");

const fs = @import("../fs.zig");
const console = @import("../console.zig");
const mem = @import("../mem.zig");

const std = @import("std");

var active_font: psf.PSFFont = font8x8.font;
var active_font_label: []const u8 = "embedded psf1 8x8 bitmap";

var console_cursor_row: u32 = 0;
var console_cursor_col: u32 = 0;
var cursor_visible: bool = false;

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
    return @as(usize, @intCast(row)) * @as(usize, @intCast(console.width)) + @as(usize, @intCast(col));
}

fn consoleCellWidthBytes() usize {
    return @as(usize, @intCast(active_font.glyph_width)) * framebuf.bytesPerPixel();
}

fn consoleCellHeightRows() usize {
    return @intCast(active_font.glyph_height);
}

fn drawConsoleCellRaw(cell: u16, row: u32, col: u32, highlight: bool) void {
    if (!window.isReady()) return;

    const font = &active_font;
    const ch: u8 = @truncate(cell & 0x00FF);
    const attr: u8 = @truncate(cell >> 8);
    const pix_ptr = window.shadowRowPtr(@as(usize, @intCast(row * font.glyph_height))) +
        @as(usize, @intCast(col * font.glyph_width)) * framebuf.bytesPerPixel();

    const effective_attr = if (highlight) swapAttr(attr) else attr;

    drawGlyphCellAt(
        pix_ptr,
        window.pitchBytes(),
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
    while (col < console.width) : (col += 1) {
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

pub const TextSize = window.TextSize;

/// Return a text grid size that fits inside the framed framebuffer console window.
pub fn preferredTextSize() !TextSize {
    return window.preferredTextSize(active_font.glyph_width, active_font.glyph_height);
}

/// Prepare the framebuffer-backed virtual-console window once a framebuffer is available.
pub fn init() !void {
    if (window.isReady()) return;

    for (0..16) |i| {
        packed_vga_palette[i] = packPaletteColor(@truncate(i));
    }

    try window.init(console.width, console.height, active_font.glyph_width, active_font.glyph_height);
    window.drawFrame(&active_font);
}

/// Redraw the full active console grid into the framebuffer-backed virtual console.
pub fn render(cells: [*]console.Cell, cursor_row: u32, cursor_col: u32, show_cursor: bool) void {
    if (!window.isReady()) return;

    const text_rows = console.height;
    const text_cols = console.width;
    const row_height_bytes = window.pitchBytes() * consoleCellHeightRows();
    var shadow_text_row_ptr = window.shadowRowPtr(0);
    var cell_row_ptr: [*]const console.Cell = cells;
    var row: u32 = 0;
    while (row < text_rows) : (row += 1) {
        drawConsoleRowAt(cell_row_ptr, shadow_text_row_ptr, window.pitchBytes());
        cell_row_ptr += text_cols;
        shadow_text_row_ptr += row_height_bytes;
    }

    console_cursor_row = if (cursor_row < text_rows) cursor_row else text_rows - 1;
    console_cursor_col = if (cursor_col < text_cols) cursor_col else text_cols - 1;
    cursor_visible = show_cursor;

    if (cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
    }
    window.blitShadowRowsToFramebuffer(0, window.pixelRows());
}

/// Scroll the virtual console up by one text row and redraw the newly exposed bottom row.
pub fn scroll(cells: [*]const console.Cell) void {
    if (!window.isReady()) return;

    const text_rows = console.height;
    const cell_h = consoleCellHeightRows();
    const scrolled_bytes = (window.pixelRows() - cell_h) * window.pitchBytes();
    const scroll_src_offset = cell_h * window.pitchBytes();
    const shadow_start = window.shadowRowPtr(0);
    mem.copyBytesForward(shadow_start, shadow_start + scroll_src_offset, scrolled_bytes);

    const bottom_row_cells = cells + consoleCellIndex(text_rows - 1, 0);
    const bottom_row_ptr = window.shadowRowPtr(window.pixelRows() - cell_h);
    drawConsoleRowAt(bottom_row_cells, bottom_row_ptr, window.pitchBytes());
    window.blitShadowRowsToFramebuffer(0, window.pixelRows());
}

/// Redraw a single console cell in the framebuffer-backed virtual console.
pub fn renderCell(cells: [*]console.Cell, row: u32, col: u32) void {
    if (!window.isReady()) return;
    if (row >= console.height or col >= console.width) return;

    const highlight = cursor_visible and row == console_cursor_row and col == console_cursor_col;
    drawConsoleCellRaw(cells[consoleCellIndex(row, col)], row, col, highlight);
    window.blitShadowCellToFramebuffer(row, col);
}

/// Update the highlighted cursor cell in the framebuffer-backed virtual console.
pub fn setCursor(cells: [*]const console.Cell, row: u32, col: u32, visible: bool) void {
    if (!window.isReady()) return;

    if (cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, false);
        window.blitShadowCellToFramebuffer(console_cursor_row, console_cursor_col);
    }

    const text_rows = console.height;
    const text_cols = console.width;
    console_cursor_row = if (row < text_rows) row else text_rows - 1;
    console_cursor_col = if (col < text_cols) col else text_cols - 1;
    cursor_visible = visible;

    if (cursor_visible) {
        drawConsoleCellRaw(cells[consoleCellIndex(console_cursor_row, console_cursor_col)], console_cursor_row, console_cursor_col, true);
        window.blitShadowCellToFramebuffer(console_cursor_row, console_cursor_col);
    }
}
