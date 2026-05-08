const std = @import("std");
const ringbuf = @import("ringbuf.zig");

pub const Pipe = struct {
    buffer: ringbuf.RingBuf = undefined,
    num_writers: usize = 0,
    num_readers: usize = 0,
    // TODO: locking - currently kernel is not reentrant

    /// Allocates a pipe with an in-memory byte buffer of the requested capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Pipe {
        return Pipe{
            .buffer = try ringbuf.RingBuf.init(allocator, capacity),
        };
    }

    /// Releases the pipe's backing buffer.
    pub fn deinit(self: *Pipe, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Appends as many bytes as fit in the pipe buffer and returns the count written.
    pub fn write(self: *Pipe, data: []const u8) usize {
        return self.buffer.write(data);
    }

    /// Removes up to `out.len` bytes from the pipe buffer and returns the count read.
    pub fn read(self: *Pipe, out: []u8) usize {
        return self.buffer.read(out);
    }
};
