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

// TODO: vectorize
pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

// TODO: vectorize
pub export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = val;
    }
    return dest;
}
