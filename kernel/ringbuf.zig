const std = @import("std");

pub const RingBuf = struct {
    buf: []u8,
    size: usize, // Number of bytes currently in the buffer
    writeat: usize,
    readat: usize,

    /// Allocate a ring buffer with the given capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuf {
        const buf = try allocator.alloc(u8, capacity);
        return @This(){
            .buf = buf,
            .writeat = 0,
            .readat = 0,
            .size = 0,
        };
    }

    /// Frees the ring buffer storage.
    pub fn deinit(self: *RingBuf, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    /// Returns how many bytes can still be written without overwriting unread data.
    pub fn bytesFree(self: *RingBuf) usize {
        return self.buf.len - self.size;
    }

    /// Returns whether the ring buffer is full.
    pub fn full(self: *RingBuf) bool {
        return self.size == self.buf.len;
    }

    /// Returns whether the ring buffer is empty.
    pub fn empty(self: *RingBuf) bool {
        return self.size == 0;
    }

    /// Writes as many bytes as fit and returns the number stored.
    pub fn write(self: *RingBuf, data: []const u8) usize {
        const num_write = @min(data.len, self.bytesFree());
        const chunk1_size = @min(num_write, self.buf.len - self.writeat);

        @memcpy(self.buf[self.writeat..][0..chunk1_size], data[0..chunk1_size]);
        self.writeat = (self.writeat + chunk1_size) % self.buf.len;

        if (chunk1_size < num_write) {
            const chunk2_size = num_write - chunk1_size;
            @memcpy(self.buf[self.writeat..][0..chunk2_size], data[chunk1_size..][0..chunk2_size]);
            self.writeat = (self.writeat + chunk2_size) % self.buf.len;
        }
        self.size += num_write;
        return num_write;
    }

    /// Reads up to `out.len` bytes and returns the number removed.
    pub fn read(self: *RingBuf, out: []u8) usize {
        const num_read = @min(out.len, self.size);
        const chunk1_size = @min(num_read, self.buf.len - self.readat);

        @memcpy(out[0..chunk1_size], self.buf[self.readat..][0..chunk1_size]);
        self.readat = (self.readat + chunk1_size) % self.buf.len;

        if (chunk1_size < num_read) {
            const chunk2_size = num_read - chunk1_size;
            @memcpy(out[chunk1_size..][0..chunk2_size], self.buf[self.readat..][0..chunk2_size]);
            self.readat = (self.readat + chunk2_size) % self.buf.len;
        }
        self.size -= num_read;
        return num_read;
    }
};
