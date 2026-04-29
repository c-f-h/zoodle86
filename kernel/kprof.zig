const std = @import("std");

const pageallocator = @import("pageallocator.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const SAMPLE_BASE_VA: usize = 0xE100_0000;
const SAMPLES_PER_PAGE: usize = paging.PAGE / @sizeOf(u32);
const MAX_PROFILE_PAGES: usize = 1024;

const CountEntry = struct {
    eip: u32,
    count: u32,
};

var alloc: std.mem.Allocator = undefined;
var initialized = false;
var enabled = false;

var page_count: usize = 0;
var write_index: usize = 0;
var dropped_samples: u32 = 0;

var page_phys: [MAX_PROFILE_PAGES]u32 = [_]u32{0} ** MAX_PROFILE_PAGES;

/// Errors returned by profiler control operations.
pub const ProfilerError = error{
    NotInitialized,
    AlreadyRunning,
    NotRunning,
    OutOfMemory,
};

/// Initialize kernel profiler state with the kernel allocator.
pub fn init(kernel_alloc: std.mem.Allocator) void {
    alloc = kernel_alloc;
    initialized = true;
}

/// Return whether profiling is currently enabled.
pub fn isEnabled() bool {
    return enabled;
}

/// Start sampling EIP values on each timer tick.
pub fn start() ProfilerError!void {
    if (!initialized) return error.NotInitialized;

    const was_enabled = disableInterrupts();
    defer restoreInterrupts(was_enabled);

    if (enabled) return error.AlreadyRunning;

    resetStateLocked();
    try allocateNextPageLocked();
    enabled = true;
}

/// Stop sampling, aggregate counts by EIP, and write a descending histogram to serial.
pub fn stop() ProfilerError!void {
    if (!initialized) return error.NotInitialized;

    var snapshot_page_count: usize = 0;
    var snapshot_write_index: usize = 0;
    var snapshot_dropped: u32 = 0;

    {
        const was_enabled = disableInterrupts();
        defer restoreInterrupts(was_enabled);

        if (!enabled) return error.NotRunning;

        enabled = false;
        snapshot_page_count = page_count;
        snapshot_write_index = write_index;
        snapshot_dropped = dropped_samples;
    }

    var sampled_entries: usize = 0;
    if (snapshot_page_count != 0) {
        sampled_entries = (snapshot_page_count - 1) * SAMPLES_PER_PAGE + snapshot_write_index;
    }

    var entries = try alloc.alloc(CountEntry, sampled_entries);
    defer alloc.free(entries);
    var unique_count: usize = 0;

    var page_idx: usize = 0;
    while (page_idx < snapshot_page_count) : (page_idx += 1) {
        const count_in_page = if (page_idx + 1 == snapshot_page_count) snapshot_write_index else SAMPLES_PER_PAGE;
        const samples = pageSamplePtr(page_idx)[0..count_in_page];
        for (samples) |eip| {
            var matched = false;
            var i: usize = 0;
            while (i < unique_count) : (i += 1) {
                if (entries[i].eip == eip) {
                    entries[i].count += 1;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                entries[unique_count] = .{ .eip = eip, .count = 1 };
                unique_count += 1;
            }
        }
    }

    sortEntriesByCountDesc(entries[0..unique_count]);

    serial.puts("kprof stop: samples=");
    putDecU32(@intCast(sampled_entries));
    serial.puts(" unique=");
    putDecU32(@intCast(unique_count));
    serial.puts(" pages=");
    putDecU32(@intCast(snapshot_page_count));
    serial.puts(" dropped=");
    putDecU32(snapshot_dropped);
    serial.putch('\n');

    for (entries[0..unique_count]) |entry| {
        serial.puts("eip=0x");
        serial.putHexU32(entry.eip);
        serial.puts(" count=");
        putDecU32(entry.count);
        serial.putch('\n');
    }

    const was_enabled = disableInterrupts();
    resetStateLocked();
    restoreInterrupts(was_enabled);
}

/// Record one sampled EIP value from the timer interrupt path.
pub fn onTimerTick(eip: u32) void {
    if (!enabled) return;

    if (write_index == SAMPLES_PER_PAGE) {
        allocateNextPageLocked() catch {
            dropped_samples += 1;
            return;
        };
        write_index = 0;
    }

    pageSamplePtr(page_count - 1)[write_index] = eip;
    write_index += 1;
}

fn disableInterrupts() bool {
    const flags = asm volatile (
        \\ pushf
        \\ pop %%eax
        : [ret] "={eax}" (-> u32),
    );
    asm volatile ("cli");
    return (flags & (1 << 9)) != 0;
}

fn restoreInterrupts(was_enabled: bool) void {
    if (was_enabled) {
        asm volatile ("sti");
    }
}

fn pageSamplePtr(page_idx: usize) [*]u32 {
    const page_va = SAMPLE_BASE_VA + page_idx * paging.PAGE;
    return @ptrFromInt(page_va);
}

fn allocateNextPageLocked() ProfilerError!void {
    if (page_count >= MAX_PROFILE_PAGES) {
        return error.OutOfMemory;
    }

    const phys = pageallocator.allocPage();
    const page_va = SAMPLE_BASE_VA + page_count * paging.PAGE;
    paging.mapContiguousRangeAt(page_va, phys, 1, false, true, false);
    @memset(pageSamplePtr(page_count)[0..SAMPLES_PER_PAGE], 0);

    page_phys[page_count] = @intCast(phys);
    page_count += 1;
}

fn resetStateLocked() void {
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const page_va: u32 = @intCast(SAMPLE_BASE_VA + i * paging.PAGE);
        paging.unmapPagesAt(page_va, 1);
        page_phys[i] = 0;
    }

    page_count = 0;
    write_index = 0;
    dropped_samples = 0;
}

fn shouldComeBefore(a: CountEntry, b: CountEntry) bool {
    if (a.count != b.count) {
        return a.count > b.count;
    }
    return a.eip < b.eip;
}

fn sortEntriesByCountDesc(entries: []CountEntry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const key = entries[i];
        var j = i;
        while (j > 0 and shouldComeBefore(key, entries[j - 1])) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = key;
    }
}

fn putDecU32(value: u32) void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{}", .{value}) catch return;
    serial.puts(text);
}
