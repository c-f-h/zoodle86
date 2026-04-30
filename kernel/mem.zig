pub fn copyBytesForward(dest: [*]u8, src: [*]const u8, len: usize) void {
    const Vec = @Vector(16, u8);
    const vec_size = @sizeOf(Vec);
    var offset: usize = 0;

    if (len == vec_size) {
        const chunk: Vec = @as(*align(1) const Vec, @ptrCast(src)).*;
        @as(*align(1) Vec, @ptrCast(dest)).* = chunk;
        return;
    }

    while (offset + vec_size <= len) : (offset += vec_size) {
        const chunk: Vec = @as(*align(1) const Vec, @ptrCast(src + offset)).*;
        @as(*align(1) Vec, @ptrCast(dest + offset)).* = chunk;
    }
    while (offset + @sizeOf(usize) <= len) : (offset += @sizeOf(usize)) {
        const word: usize = @as(*align(1) const usize, @ptrCast(src + offset)).*;
        @as(*align(1) usize, @ptrCast(dest + offset)).* = word;
    }
    while (offset < len) : (offset += 1) {
        dest[offset] = src[offset];
    }
}

/// C ABI memcpy, vectorized via copyBytesForward.
pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    copyBytesForward(dest, src, len);
    return dest;
}

/// Fill `len` u16 elements at `dest` with `val`, vectorized.
pub fn memset16(dest: [*]u16, val: u16, len: usize) void {
    const Vec = @Vector(8, u16); // 16 bytes, matching the u8 vector width
    const vec_elems = 8;
    const vec_val: Vec = @splat(val);
    var offset: usize = 0;

    while (offset + vec_elems <= len) : (offset += vec_elems) {
        @as(*align(1) Vec, @ptrCast(dest + offset)).* = vec_val;
    }
    // Spread val into every 16-bit lane of a machine word.
    var word: usize = val;
    comptime var shift: usize = 16;
    inline while (shift < @bitSizeOf(usize)) : (shift *= 2) {
        word |= word << shift;
    }
    const word_elems = @sizeOf(usize) / @sizeOf(u16);
    while (offset + word_elems <= len) : (offset += word_elems) {
        @as(*align(1) usize, @ptrCast(dest + offset)).* = word;
    }
    while (offset < len) : (offset += 1) {
        dest[offset] = val;
    }
}

/// C ABI memset, vectorized with 16-byte SIMD chunks, then word-size, then byte fallback.
pub export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    const Vec = @Vector(16, u8);
    const vec_size = @sizeOf(Vec);
    const vec_val: Vec = @splat(val);
    var offset: usize = 0;

    while (offset + vec_size <= len) : (offset += vec_size) {
        @as(*align(1) Vec, @ptrCast(dest + offset)).* = vec_val;
    }
    // Spread val into every byte of a machine word.
    var word: usize = val;
    comptime var shift: usize = 8;
    inline while (shift < @bitSizeOf(usize)) : (shift *= 2) {
        word |= word << shift;
    }
    while (offset + @sizeOf(usize) <= len) : (offset += @sizeOf(usize)) {
        @as(*align(1) usize, @ptrCast(dest + offset)).* = word;
    }
    while (offset < len) : (offset += 1) {
        dest[offset] = val;
    }
    return dest;
}
