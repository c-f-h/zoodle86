const std = @import("std");
const ringbuf = @import("ringbuf.zig");
const waitqueue = @import("waitqueue.zig");

pub const Pipe = struct {
    buffer: ringbuf.RingBuf = undefined,
    num_writers: usize = 0,
    num_readers: usize = 0,
    // TODO: locking - currently kernel is not reentrant

    read_waiters: waitqueue.WaitQueue = undefined,
    write_waiters: waitqueue.WaitQueue = undefined,

    /// Allocates a pipe with an in-memory byte buffer of the requested capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Pipe {
        return Pipe{
            .buffer = try ringbuf.RingBuf.init(allocator, capacity),
            .read_waiters = waitqueue.WaitQueue.init(allocator),
            .write_waiters = waitqueue.WaitQueue.init(allocator),
        };
    }

    /// Releases the pipe's backing buffer.
    pub fn deinit(self: *Pipe, allocator: std.mem.Allocator) void {
        if (!self.read_waiters.empty()) {
            @panic("deinit called on pipe with waiting readers");
        }
        if (!self.write_waiters.empty()) {
            @panic("deinit called on pipe with waiting writers");
        }
        self.buffer.deinit(allocator);
    }

    /// Appends as many bytes as fit in the pipe buffer and returns the count written.
    pub fn write(self: *Pipe, data: []const u8) usize {
        const count = self.buffer.write(data);
        _ = self.read_waiters.wakeOne(0);
        return count;
    }

    /// Removes up to `out.len` bytes from the pipe buffer and returns the count read.
    pub fn read(self: *Pipe, out: []u8) usize {
        const count = self.buffer.read(out);
        _ = self.write_waiters.wakeOne(0);
        return count;
    }

    /// Returns true if the pipe buffer has no data to read.
    pub fn empty(self: *Pipe) bool {
        return self.buffer.empty();
    }

    /// Returns true if the pipe buffer has no space to write.
    pub fn full(self: *Pipe) bool {
        return self.buffer.full();
    }

    pub fn bytesFree(self: *Pipe) usize {
        return self.buffer.bytesFree();
    }
};
