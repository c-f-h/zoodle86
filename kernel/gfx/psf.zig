const std = @import("std");

/// Magic bytes for a PSF1 font header.
pub const psf1_magic = [2]u8{ 0x36, 0x04 };

/// Magic bytes for a PSF2 font header.
pub const psf2_magic = [4]u8{ 0x72, 0xB5, 0x4A, 0x86 };

/// PSF1 mode bit indicating a 512-glyph font.
pub const psf1_mode_512: u8 = 0x01;

/// PSF1 mode bit indicating the presence of a Unicode table.
pub const psf1_mode_has_unicode_table: u8 = 0x02;

/// PSF1 header for an 8-pixel-wide bitmap font.
pub const PSF1Header = extern struct {
    magic: [2]u8,
    mode: u8,
    charsize: u8,
};

/// In-memory PSF font image used by the framebuffer text renderer.
pub const PSFFont = struct {
    header: PSF1Header,
    glyphs: []const u8,
    glyph_count: u32,
    glyph_width: u32,
    glyph_height: u32,
    bytes_per_row: u32,
    fallback_glyph: u8,

    /// Don't call this on the builtin 8x8 font.
    pub fn deinit(self: *PSFFont, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
    }

    /// Return the total number of bytes in one glyph bitmap.
    pub fn glyphByteSize(self: *const PSFFont) u32 {
        return bytesPerRow(self.glyph_width) * self.glyph_height;
    }

    /// Get the glyph bitmap for the given character, or the fallback glyph if out of range.
    pub fn getGlyph(self: *const PSFFont, ch: u8) []const u8 {
        const glyph_index = if (ch < self.glyph_count) ch else self.fallback_glyph;
        const bytes_per_glyph = self.glyphByteSize();
        const start = glyph_index * bytes_per_glyph;
        return self.glyphs[start .. start + bytes_per_glyph];
    }
};

/// Errors returned while parsing a PSF file image.
pub const LoadError = std.mem.Allocator.Error || error{
    InvalidHeader,
    InvalidMagic,
    UnsupportedFormat,
    TruncatedGlyphs,
};

/// Return the row stride in bytes for glyphs of the given width.
pub fn bytesPerRow(glyph_width: u32) u32 {
    return @divTrunc(glyph_width + 7, 8);
}

/// Construct an in-memory PSF1 font descriptor from already prepared glyph bytes.
pub fn initPsf1(glyphs: []const u8, glyph_count: u32, glyph_height: u8, fallback_glyph: u8) PSFFont {
    return .{
        .header = .{
            .magic = psf1_magic,
            .mode = if (glyph_count == 512) psf1_mode_512 else 0,
            .charsize = glyph_height,
        },
        .glyphs = glyphs,
        .glyph_count = glyph_count,
        .glyph_width = 8,
        .glyph_height = glyph_height,
        .bytes_per_row = bytesPerRow(8),
        .fallback_glyph = fallback_glyph,
    };
}

/// Parse a PSF font file image and copy its glyphs into allocator-owned kernel memory.
pub fn loadFromBytes(allocator: std.mem.Allocator, data: []const u8, fallback_glyph: u8) LoadError!PSFFont {
    if (data.len < @sizeOf(PSF1Header)) return error.InvalidHeader;

    if (std.mem.eql(u8, data[0..2], &psf1_magic)) {
        const header = PSF1Header{
            .magic = .{ data[0], data[1] },
            .mode = data[2],
            .charsize = data[3],
        };
        if (header.charsize == 0) return error.InvalidHeader;

        const glyph_count: u32 = if ((header.mode & psf1_mode_512) != 0) 512 else 256;
        const glyph_bytes = glyph_count * @as(usize, header.charsize);
        const glyph_data_start = @sizeOf(PSF1Header);
        if (data.len < glyph_data_start + glyph_bytes) return error.TruncatedGlyphs;

        const glyphs = try allocator.alloc(u8, glyph_bytes);
        @memcpy(glyphs, data[glyph_data_start .. glyph_data_start + glyph_bytes]);

        return .{
            .header = header,
            .glyphs = glyphs,
            .glyph_count = glyph_count,
            .glyph_width = 8,
            .glyph_height = header.charsize,
            .bytes_per_row = bytesPerRow(8),
            .fallback_glyph = fallback_glyph,
        };
    }

    if (data.len >= psf2_magic.len and std.mem.eql(u8, data[0..psf2_magic.len], &psf2_magic)) {
        return error.UnsupportedFormat;
    }

    return error.InvalidMagic;
}
