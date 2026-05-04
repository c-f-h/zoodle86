const paging = @import("paging.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const math = std.math;

/// Fixed virtual base address of the kernel heap arena.
pub const ARENA_BASE: usize = 0xE000_0000;

/// Fixed virtual size of the kernel heap arena in bytes.
pub const ARENA_SIZE: usize = 16 * 1024 * 1024;

const debuglog = false;
const serial = if (debuglog) @import("serial.zig") else null;

const ARENA_END = ARENA_BASE + ARENA_SIZE;
const slab_size: comptime_int = paging.PAGE;
const min_class = math.log2(@sizeOf(usize));
const small_class_count = math.log2(slab_size) - min_class;

comptime {
    if (@sizeOf(usize) != 4) {
        @compileError("kernel allocator expects a 32-bit target");
    }
}

inline fn actualLen(len: usize, alignment: Alignment) u32 {
    return @intCast(@max(len, @max(alignment.toByteUnits(), @sizeOf(usize))));
}

/// Single-threaded page-backed kernel allocator with power-of-two small-object classes.
pub const KernelAllocator = struct {
    next_addrs: [small_class_count]usize = @splat(0),
    frees: [small_class_count]usize = @splat(0),
    next_small_search: usize = ARENA_BASE,

    const Self = @This();

    /// Initialize the allocator and pre-create the shared heap page tables.
    pub fn init() Self {
        paging.ensurePageTablesAt(@intCast(ARENA_BASE), @intCast(ARENA_SIZE / paging.PAGE), false);
        return .{};
    }

    /// Return the `std.mem.Allocator` view for this kernel allocator instance.
    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

var global_kernel_allocator: KernelAllocator = .{};

pub const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// Reset and initialize the process-global kernel allocator.
pub fn init() void {
    global_kernel_allocator = KernelAllocator.init();
}

/// Return the process-global kernel allocator instance.
pub fn getAllocator() Allocator {
    return global_kernel_allocator.allocator();
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    _ = return_address;
    const self: *KernelAllocator = @ptrCast(@alignCast(context));

    const actual_len = actualLen(len, alignment);
    const slot_size = ceilPowerOfTwo32(actual_len) orelse return null;
    const class = math.log2(slot_size) - min_class;

    if (class < small_class_count) {
        const addr = allocSmall(self, class, slot_size) orelse return null;
        return @ptrFromInt(addr);
    }

    const num_pages = pagesNeeded(actual_len);
    const addr = findLargeRun(num_pages) orelse return null;

    if (debuglog) {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "alloc: large alloc at {x}, {} pages, {} bytes\n", .{ addr, num_pages, len }) catch unreachable;
        serial.puts(msg);
    }

    _ = paging.allocateMemoryAt(addr, num_pages, false, true);
    return @ptrFromInt(addr);
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

    const old_small_slot_size = ceilPowerOfTwo32Assert(old_actual_len);
    const old_small_class = math.log2(old_small_slot_size) - min_class;
    if (old_small_class < small_class_count) {
        const new_small_slot_size = ceilPowerOfTwo32(new_actual_len) orelse return false;
        return old_small_slot_size == new_small_slot_size;
    }

    return pagesNeeded(old_actual_len) == pagesNeeded(new_actual_len);
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
    const self: *KernelAllocator = @ptrCast(@alignCast(context));

    const actual_len = actualLen(memory.len, alignment);
    const slot_size = ceilPowerOfTwo32Assert(actual_len);
    const class = math.log2(slot_size) - min_class;
    const addr = @intFromPtr(memory.ptr);

    if (class < small_class_count) {
        const next_free: *usize = @ptrFromInt(addr);
        next_free.* = self.frees[class];
        self.frees[class] = addr;
        return;
    }

    if (debuglog) {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, " free: large alloc at {x}, {} pages\n", .{ addr, pagesNeeded(actual_len) }) catch unreachable;
        serial.puts(msg);
    }

    paging.unmapPagesAtKeepTables(@intCast(addr), pagesNeeded(actual_len));
}

fn allocSmall(self: *KernelAllocator, class: u32, slot_size: u32) ?usize {
    const top_free_ptr = self.frees[class];
    if (top_free_ptr != 0) {
        const next_free: *usize = @ptrFromInt(top_free_ptr);
        self.frees[class] = next_free.*;
        return top_free_ptr;
    }

    const next_addr = self.next_addrs[class];
    if (next_addr == 0 or next_addr % slab_size == 0) {
        const slab_addr = allocSmallSlab(self) orelse return null;
        self.next_addrs[class] = slab_addr + slot_size;
        return slab_addr;
    }

    self.next_addrs[class] = next_addr + slot_size;
    return next_addr;
}

fn allocSmallSlab(self: *KernelAllocator) ?usize {
    const start = self.next_small_search;
    var cursor = start;
    while (true) {
        if (!paging.hasPte(@intCast(cursor))) {
            _ = paging.allocateMemoryAt(cursor, 1, false, true);
            self.next_small_search = advancePage(cursor);
            return cursor;
        }

        cursor = advancePage(cursor);
        if (cursor == start) return null;
    }
}

fn findLargeRun(num_pages: u32) ?usize {
    const run_size = @as(usize, num_pages) * slab_size;
    if (run_size > ARENA_SIZE) return null;

    var cursor = ARENA_END - run_size;
    while (true) {
        if (rangeIsUnmapped(cursor, num_pages)) return cursor;
        if (cursor == ARENA_BASE) return null;
        cursor -= slab_size;
    }
}

fn rangeIsUnmapped(base: usize, num_pages: u32) bool {
    for (0..num_pages) |i| {
        const va = base + i * slab_size;
        if (paging.hasPte(@intCast(va))) return false;
    }
    return true;
}

fn advancePage(addr: usize) usize {
    const next = addr + slab_size;
    return if (next >= ARENA_END) ARENA_BASE else next;
}

inline fn pagesNeeded(byte_count: u32) u32 {
    return @intCast((byte_count + (slab_size - 1)) / slab_size);
}

fn ceilPowerOfTwo32(value: u32) ?u32 {
    if (value <= 1) return 1;
    const shift = 32 - @clz(value - 1);
    if (shift >= 32) return null;
    return @as(u32, 1) << @intCast(shift);
}

fn ceilPowerOfTwo32Assert(value: u32) u32 {
    return ceilPowerOfTwo32(value) orelse unreachable;
}
