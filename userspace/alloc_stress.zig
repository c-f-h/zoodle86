const std = @import("std");
const heap = @import("allocator.zig");
const sys = @import("sys.zig");

const small_alloc_count = 600;

fn expect(condition: bool) !void {
    if (!condition) return error.TestFailed;
}

fn expectEq(comptime T: type, actual: T, expected: T) !void {
    if (actual != expected) return error.TestFailed;
}

fn fillPattern(buf: []u8, seed: u8) void {
    for (buf, 0..) |*byte, index| {
        byte.* = seed +% @as(u8, @intCast((index * 17) % 251));
    }
}

fn expectPattern(buf: []const u8, seed: u8) !void {
    for (buf, 0..) |byte, index| {
        const expected = seed +% @as(u8, @intCast((index * 17) % 251));
        if (byte != expected) return error.TestFailed;
    }
}

fn testCreateDestroy(allocator: std.mem.Allocator) !void {
    var ints: [small_alloc_count]*u32 = undefined;

    for (&ints, 0..) |*slot, index| {
        const ptr = try allocator.create(u32);
        ptr.* = 0xC0DE_0000 + @as(u32, @intCast(index));
        slot.* = ptr;
    }

    for (ints, 0..) |ptr, index| {
        try expectEq(u32, ptr.*, 0xC0DE_0000 + @as(u32, @intCast(index)));
        allocator.destroy(ptr);
    }

    for (&ints, 0..) |*slot, index| {
        const ptr = try allocator.create(u32);
        ptr.* = 0xABCD_0000 + @as(u32, @intCast(index));
        slot.* = ptr;
    }

    var i = ints.len;
    while (i > 0) {
        i -= 1;
        try expectEq(u32, ints[i].*, 0xABCD_0000 + @as(u32, @intCast(i)));
        allocator.destroy(ints[i]);
    }
}

fn testReuse(allocator: std.mem.Allocator) !void {
    const first = try allocator.alloc(u8, 40);
    fillPattern(first, 0x21);
    const first_ptr = first.ptr;
    allocator.free(first);

    const second = try allocator.alloc(u8, 33);
    defer allocator.free(second);
    try expect(@intFromPtr(second.ptr) == @intFromPtr(first_ptr));
}

fn testRealloc(allocator: std.mem.Allocator) !void {
    var buf = try allocator.alloc(u8, 20);
    defer allocator.free(buf);

    fillPattern(buf, 0x40);
    const same_class_ptr = buf.ptr;
    buf = try allocator.realloc(buf, 24); // same slot_size (32), no move
    try expect(@intFromPtr(buf.ptr) == @intFromPtr(same_class_ptr));
    try expectPattern(buf[0..20], 0x40);

    const moved_from = buf.ptr;
    buf = try allocator.realloc(buf, 80); // different class, must move
    try expect(@intFromPtr(buf.ptr) != @intFromPtr(moved_from));
    try expectPattern(buf[0..20], 0x40);

    fillPattern(buf, 0x55);
    try expect(allocator.resize(buf, 72));
    buf = buf[0..72];
    try expectPattern(buf, 0x55);
}

// Allocates a block whose actual_len equals exactly slab_size, i.e. the smallest request
// that falls into the large-allocation path.
fn testSlabThreshold(allocator: std.mem.Allocator) !void {
    const slab_size = 16 * 1024;
    // actual_len = @max(len, @sizeOf(usize)) must equal exactly slab_size so that
    // slabsNeeded returns 1 and the free-list node lands at the first word of the slab.
    const threshold_len = slab_size;

    const buf = try allocator.alloc(u8, threshold_len);
    defer allocator.free(buf);
    try expect(buf.len == threshold_len);

    // Fill with pattern and verify immediately (checks for overlap / under-allocation).
    fillPattern(buf, 0xBB);
    try expectPattern(buf, 0xBB);
}

fn testLargeBlocks(allocator: std.mem.Allocator) !void {
    const large = try allocator.alloc(u8, 96 * 1024);
    fillPattern(large, 0x63);
    const large_ptr = large.ptr;
    allocator.free(large);

    const reused = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(reused);
    try expect(@intFromPtr(reused.ptr) == @intFromPtr(large_ptr));
}

/// Exercises the userspace brk-backed allocator with allocation, free, and realloc churn.
pub fn main(argv: []const []const u8) !void {
    _ = argv;

    var brk_allocator = heap.BrkAllocator.init();
    const allocator = brk_allocator.allocator();

    var buf: [96]u8 = undefined;
    _ = sys.write(sys.STDOUT, try std.fmt.bufPrint(&buf, "pid {d}: stress-testing userspace allocator...\n", .{sys.getpid()}));

    try testCreateDestroy(allocator);
    try testReuse(allocator);
    try testRealloc(allocator);
    try testLargeBlocks(allocator);
    try testSlabThreshold(allocator);

    _ = sys.write(sys.STDOUT, "userspace allocator stress test OK\n");
}

comptime {
    _ = sys._start;
}
