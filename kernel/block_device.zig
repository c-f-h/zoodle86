const abi = @import("abi");
const std = @import("std");

/// Block device abstraction layer.
///
/// Provides a vtable-based interface for 512-byte sector I/O.
pub const BLOCK_SIZE: u32 = 512;

pub const BlockError = error{
    /// The underlying device failed to read the requested block.
    ReadError,
    /// The underlying device failed to write the requested block.
    WriteError,
    /// The requested LBA is out of range for this device.
    InvalidBlock,
};

/// Abstract block device. Concrete implementations embed this struct as a field
/// named `block_dev` and dispatch I/O through the vtable.
pub const BlockDevice = struct {
    vtable: *const VTable,
    /// Total number of 512-byte blocks available on this device.
    block_count: u32,
    device: abi.Device,
    cache: BlockCache = .{},

    pub const VTable = struct {
        /// Read one 512-byte block at `lba` into `buf`.
        readBlock: *const fn (self: *BlockDevice, lba: u32, buf: *[BLOCK_SIZE]u8) BlockError!void,
        /// Write one 512-byte block at `lba` from `buf`.
        writeBlock: *const fn (self: *BlockDevice, lba: u32, buf: *const [BLOCK_SIZE]u8) BlockError!void,
    };

    /// Read one 512-byte block at `lba` into `buf`.
    pub fn readBlock(self: *BlockDevice, lba: u32, buf: *[BLOCK_SIZE]u8) BlockError!void {
        if (self.cache.inited) {
            return self.readBlockCached(lba, buf);
        }
        return self.vtable.readBlock(self, lba, buf);
    }

    /// Write one 512-byte block at `lba` from `buf`.
    pub fn writeBlock(self: *BlockDevice, lba: u32, buf: *const [BLOCK_SIZE]u8) BlockError!void {
        if (self.cache.inited) {
            return self.writeBlockCached(lba, buf);
        }
        return self.vtable.writeBlock(self, lba, buf);
    }

    pub fn initCache(self: *BlockDevice, alloc: std.mem.Allocator) error{OutOfMemory}!void {
        return self.cache.init(alloc);
    }

    pub fn deinitCache(self: *BlockDevice, alloc: std.mem.Allocator) void {
        self.cache.deinit(alloc);
    }

    fn readBlockCached(self: *BlockDevice, lba: u32, buf: *[BLOCK_SIZE]u8) BlockError!void {
        const has_i = self.cache.find(lba);
        if (has_i) |i| {
            @memcpy(buf, self.cache.cachedData(i));
            self.cache.cache_hits += 1;
        } else {
            const new_i = self.cache.evict();
            const data = self.cache.cachedData(new_i);
            try self.vtable.readBlock(self, lba, data);
            @memcpy(buf, data);
            self.cache.info[new_i].lba = lba;
            self.cache.cache_misses += 1;
        }
    }

    fn writeBlockCached(self: *BlockDevice, lba: u32, buf: *const [BLOCK_SIZE]u8) BlockError!void {
        const has_i = self.cache.find(lba);
        if (has_i) |i| {
            // Note that writing also increases the use flag
            @memcpy(self.cache.cachedData(i), buf);
        }
        // We don't create a cache entry if none exists to avoid streaming writes flooding the cache
        return self.vtable.writeBlock(self, lba, buf);
    }
};

// At 8 blocks of 512 bytes each, the cache is one page in size.
const CACHE_SIZE = 8;

const LBA_NONE: u32 = 0xFFFF_FFFF;

const CacheEntry = struct {
    // Block index
    lba: u32 = LBA_NONE,
    // Usage hint for eviction
    used: u8 = 0,
};

const BlockCache = struct {
    cache: []u8 = undefined,
    info: []CacheEntry = undefined,
    clock_hand: u32 = 0, // advancing index for eviction
    inited: bool = false,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,

    fn init(self: *BlockCache, alloc: std.mem.Allocator) error{OutOfMemory}!void {
        self.cache = try alloc.alloc(u8, CACHE_SIZE * BLOCK_SIZE);
        self.info = try alloc.alloc(CacheEntry, CACHE_SIZE);
        @memset(self.info, .{});
        self.inited = true;
    }

    fn deinit(self: *BlockCache, alloc: std.mem.Allocator) void {
        alloc.free(self.cache);
        alloc.free(self.info);
        self.inited = false;
    }

    fn find(self: *BlockCache, lba: u32) ?u32 {
        var i: u32 = 0;
        while (i < CACHE_SIZE) : (i += 1) {
            if (self.info[i].lba == lba) {
                self.info[i].used +|= 1; // increase with saturation
                return i;
            }
        }
        return null;
    }

    fn evict(self: *BlockCache) u32 {
        while (true) {
            const cur_entry = &self.info[self.clock_hand];
            if (cur_entry.used == 0) {
                cur_entry.lba = LBA_NONE;
                cur_entry.used = 1;

                const i = self.clock_hand;
                self.clock_hand = (self.clock_hand + 1) % CACHE_SIZE;
                return i;
            } else {
                cur_entry.used -= 1;
                self.clock_hand = (self.clock_hand + 1) % CACHE_SIZE;
            }
        }
    }

    fn cachedData(self: *BlockCache, i: u32) *[BLOCK_SIZE]u8 {
        return self.cache[i * BLOCK_SIZE ..][0..BLOCK_SIZE];
    }
};
