const std = @import("std");

pub export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

pub export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = val;
    }
    return dest;
}

inline fn syscall(nr: u32, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        : [nr] "{eax}" (nr),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
        : .{ .memory = true });
}

pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

pub fn write(fd: u32, buf: []const u8) u32 {
    return syscall(1, fd, @intFromPtr(buf.ptr), buf.len);
}

const pid_t = u32;

pub fn getpid() pid_t {
    return syscall(39, 0, 0, 0);
}

pub fn yield() void {
    _ = syscall(24, 0, 0, 0);
}

pub fn exit(exitcode: u32) noreturn {
    _ = syscall(60, exitcode, 0, 0);
    unreachable;
}

const STDOUT = 1;

fn main() !void {
    var buf: [80]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Hello, world from process {0}!\n", .{getpid()});
    var count: u32 = 10;
    while (count > 0) : (count -= 1) {
        _ = write(STDOUT, msg);
        yield();
    }
}

pub export fn _start() void {
    main() catch {
        _ = write(STDOUT, "Error occurred.\n");
        exit(1);
    };
    exit(0);
}
