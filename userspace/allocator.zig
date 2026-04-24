// Allocator based on the Zig std.heap.BrkAllocator, but adapted to use the zoodle86 brk syscall.
// Also includes some fixes and performance improvements (smaller block size, overallocation reduced,
// free-list node is stored in the first rather than last word of each allocation).
const std = @import("std");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const math = std.math;

// All brk allocations are done in power of two multiples of this slab size.
const slab_size: comptime_int = 16 * 1024;

// Smallest allocation class: one pointer word (free-list node)
const min_class = math.log2(@sizeOf(usize));

// Anything smaller than a slab is considered a "small" allocation.
const small_class_count = math.log2(slab_size) - min_class;

// Size of the entire addressable space
const addr_space_size = math.maxInt(usize) + 1;

// Number of slabs needed to cover the entire address space
const max_slab_count = addr_space_size / slab_size;

// Number of large allocation size classes (powers of two number of slabs)
const large_class_count = math.log2(max_slab_count);

// Small allocations are grouped by their byte size, rounded to the next power of two.
// Large allocations are grouped by the number of slabs they occupy, rounded to the next power of two.
// The first word of each allocation is used as a free-list node when the block is freed.

comptime {
    if (@sizeOf(usize) != 4) {
        @compileError("userspace BrkAllocator expects a 32-bit target");
    }
}

// Effective allocation size: at least one pointer word and at least as large as the alignment.
inline fn actualLen(len: usize, alignment: Alignment) usize {
    return @max(len, @max(alignment.toByteUnits(), @sizeOf(usize)));
}

/// Implements a single-threaded `std.mem.Allocator` backed by the userspace `brk` syscall.
pub const BrkAllocator = struct {
    // For each small size class, the next unused slot inside the current slab
    next_addrs: [small_class_count]usize = @splat(0),

    // For each small size class, the head of the free list
    frees: [small_class_count]usize = @splat(0),

    // Free lists for large allocations grouped by power-of-two slab runs
    large_frees: [large_class_count]usize = @splat(0),

    const Self = @This();

    /// Returns a zero-initialized allocator.
    pub fn init() Self {
        return .{};
    }

    /// Returns the `std.mem.Allocator` view for this allocator.
    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

var global_brk_allocator = BrkAllocator.init();

pub const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// Returns the process-global brk-backed allocator instance.
pub fn getAllocator() Allocator {
    return global_brk_allocator.allocator();
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    _ = return_address;
    const self: *BrkAllocator = @ptrCast(@alignCast(context));

    // Find allocation size (at least one pointer word to hold free-list node when unallocated)
    const actual_len = actualLen(len, alignment);
    const slot_size = ceilPowerOfTwo32(actual_len) orelse return null;
    const class = math.log2(slot_size) - min_class;

    if (class < small_class_count) {
        // Small allocation: reuse freed slot or allocate a new slab if needed
        const addr = blk: {
            // Check if free list for this size class is non-empty
            const top_free_ptr = self.frees[class];
            if (top_free_ptr != 0) {
                // Unlink the top block from the free list and return it
                const next_free: *usize = @ptrFromInt(top_free_ptr);
                self.frees[class] = next_free.*;
                break :blk top_free_ptr;
            }

            // No free slots, so allocate a new slab if needed and return the next slot
            const next_addr = self.next_addrs[class];
            if (next_addr % slab_size == 0) {
                const fresh_addr = allocSlabs(self, 1);
                if (fresh_addr == 0) return null;
                self.next_addrs[class] = fresh_addr + slot_size;
                break :blk fresh_addr;
            }

            // We still had a valid next_addr, so use it and advance the cursor
            self.next_addrs[class] = next_addr + slot_size;
            break :blk next_addr;
        };
        return @ptrFromInt(addr);
    } else {
        // Large allocation
        const slabs_needed = slabsNeeded(actual_len);
        const addr = allocSlabs(self, slabs_needed);
        if (addr == 0) return null;
        return @ptrFromInt(addr);
    }
}

fn resize(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    _ = context;
    _ = return_address;

    const old_actual_len = actualLen(memory.len, alignment);
    const new_actual_len = actualLen(new_len, alignment);

    // Check small allocation case
    const old_small_slot_size = ceilPowerOfTwo32Assert(old_actual_len);
    const old_small_class = math.log2(old_small_slot_size) - min_class;
    if (old_small_class < small_class_count) {
        const new_small_slot_size = ceilPowerOfTwo32(new_actual_len) orelse return false;
        // Can keep allocation if it stays in the same small size class
        return old_small_slot_size == new_small_slot_size;
    }

    // Otherwise, large allocation case: keep allocation if it stays in the same power-of-two slab class
    const old_slabs_needed = slabsNeeded(old_actual_len);
    const old_pow2_slabs = ceilPowerOfTwo32Assert(old_slabs_needed);
    const new_slabs_needed = slabsNeeded(new_actual_len);
    const new_pow2_slabs = ceilPowerOfTwo32(new_slabs_needed) orelse return false;
    return old_pow2_slabs == new_pow2_slabs;
}

fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
    _ = return_address;
    const self: *BrkAllocator = @ptrCast(@alignCast(context));

    const actual_len = actualLen(memory.len, alignment);
    const slot_size = ceilPowerOfTwo32Assert(actual_len);
    const class = math.log2(slot_size) - min_class;
    const addr = @intFromPtr(memory.ptr);

    if (class < small_class_count) {
        // add the freed block to the correct small allocation free list
        const next_free: *usize = @ptrFromInt(addr);
        next_free.* = self.frees[class];
        self.frees[class] = addr;
    } else {
        // determine large allocation size class
        const slabs_needed = slabsNeeded(actual_len);
        const pow2_slabs = ceilPowerOfTwo32Assert(slabs_needed);
        // add the freed block to the correct free list
        const next_free: *usize = @ptrFromInt(addr);
        const large_class = math.log2(pow2_slabs);
        next_free.* = self.large_frees[large_class];
        self.large_frees[large_class] = addr;
    }
}

// Number of slabs needed to fit an allocation of actual length byte_count
inline fn slabsNeeded(byte_count: usize) usize {
    return (byte_count + (slab_size - 1)) / slab_size;
}

// Allocate 2^k >= n slabs (or reuse a freed block of that size)
fn allocSlabs(self: *BrkAllocator, n: usize) usize {
    const pow2_slabs = ceilPowerOfTwo32Assert(n);
    const total_size = pow2_slabs * slab_size;
    const class = math.log2(pow2_slabs);

    // Check the free list for this size class first
    const top_free_ptr = self.large_frees[class];
    if (top_free_ptr != 0) {
        // Unlink the top block from the free list and return it
        const next_free: *usize = @ptrFromInt(top_free_ptr);
        self.large_frees[class] = next_free.*;
        return top_free_ptr;
    }

    // No free blocks, so extend the heap by the required number of slabs
    const current_brk = sys.getHeapBreak();
    // Align to the next slab boundary
    const start_brk = (current_brk + (slab_size - 1)) & ~@as(usize, slab_size - 1);
    if (start_brk != current_brk) {
        _ = sys.setHeapBreak(start_brk) catch return 0;
    }

    // Grow heap by requested size
    const end_brk = start_brk + total_size;
    const previous_brk = sys.setHeapBreak(end_brk) catch return 0;
    return @intFromPtr(previous_brk);
}

// Compute the next power of two greater than or equal to `value`, or return null in case of overflow.
fn ceilPowerOfTwo32(value: u32) ?u32 {
    if (value <= 1) return 1;
    // @clz counts leading zeros; 32 - @clz(value - 1) gives the bit position needed
    const shift = 32 - @clz(value - 1);
    if (shift >= 32) return null; // overflow
    return @as(u32, 1) << @intCast(shift);
}

fn ceilPowerOfTwo32Assert(value: u32) u32 {
    return ceilPowerOfTwo32(value) orelse unreachable;
}
