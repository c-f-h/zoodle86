const acpi = @import("acpi.zig");
const abi = @import("abi");

var last_pm_timer: u32 = undefined;
var clock_count: u64 = undefined;

const TICKS_PER_SEC = 3579545;
const NSECS_PER_TICK = 1_000_000_000 / TICKS_PER_SEC;

pub const Clock = abi.Clock;

pub fn initClock() void {
    last_pm_timer = acpi.readPmTimer();
    clock_count = 0;
}

pub fn updateClock() void {
    const new_timer = acpi.readPmTimer();
    if (new_timer < last_pm_timer) {
        clock_count += @as(u64, acpi.pm_timer_mask) + 1;
    }
    last_pm_timer = new_timer;
}

pub fn getClock() Clock {
    updateClock();
    const total_ticks = clock_count + last_pm_timer;
    // Ticks since the start of the current clock second
    const cur_sec_ticks: u32 = @truncate(total_ticks % TICKS_PER_SEC);
    return .{
        .secs = total_ticks / TICKS_PER_SEC,
        .nsecs = NSECS_PER_TICK * cur_sec_ticks,
    };
}
