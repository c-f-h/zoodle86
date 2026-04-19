const std = @import("std");

const STDIN: u32 = 0;
const STDOUT: u32 = 1;
const STDERR: u32 = 2;

const O_RDONLY: u32 = 0;
const O_WRONLY: u32 = 1;
const O_RDWR: u32 = 2;
const O_CREAT: u32 = 64;
const O_TRUNC: u32 = 512;
const O_APPEND: u32 = 1024;

const Syscall = enum(u32) {
    read = 0,
    write = 1,
    open = 2,
    close = 3,
    sched_yield = 24,
    getpid = 39,
    exit = 60,
};

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

inline fn syscallRaw(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32),
        : [nr] "{eax}" (@intFromEnum(nr)),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
        : .{ .memory = true });
}

inline fn syscall(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) i32 {
    return @bitCast(syscallRaw(nr, arg1, arg2, arg3));
}

pub inline fn bochsDebugBreak() void {
    _ = asm volatile ("xchg %%bx, %%bx");
}

pub fn write(fd: u32, buf: []const u8) i32 {
    return syscall(.write, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

pub fn read(fd: u32, buf: []u8) i32 {
    return syscall(.read, fd, @intFromPtr(buf.ptr), @intCast(buf.len));
}

pub fn open(path: []const u8, flags: u32) i32 {
    return syscall(.open, @intFromPtr(path.ptr), @intCast(path.len), flags);
}

pub fn close(fd: u32) i32 {
    return syscall(.close, fd, 0, 0);
}

const pid_t = u32;

pub fn getpid() pid_t {
    return @bitCast(syscall(.getpid, 0, 0, 0));
}

pub fn yield() void {
    _ = syscall(.sched_yield, 0, 0, 0);
}

pub fn exit(exitcode: u32) noreturn {
    _ = syscall(.exit, exitcode, 0, 0);
    unreachable;
}

fn expectSyscall(rc: i32) !u32 {
    if (rc < 0) return error.SyscallFailed;
    return @intCast(rc);
}

fn main() !void {
    const file_name = "fdtest.txt";
    const first = "hello from file io\n";
    const second = "and append works too\n";
    const expected = first ++ second;

    var banner: [96]u8 = undefined;
    const msg = try std.fmt.bufPrint(&banner, "Hello from process {d}, testing filesystem syscalls...\n", .{getpid()});
    _ = write(STDOUT, msg);

    const create_fd = try expectSyscall(open(file_name, O_CREAT | O_TRUNC | O_RDWR));
    const first_written = try expectSyscall(write(create_fd, first));
    if (first_written != first.len) return error.ShortWrite;
    if (close(create_fd) < 0) return error.SyscallFailed;

    const append_fd = try expectSyscall(open(file_name, O_WRONLY | O_APPEND));
    const second_written = try expectSyscall(write(append_fd, second));
    if (second_written != second.len) return error.ShortWrite;
    if (close(append_fd) < 0) return error.SyscallFailed;

    const read_fd = try expectSyscall(open(file_name, O_RDONLY));
    var read_buf: [expected.len]u8 = undefined;
    const bytes_read = try expectSyscall(read(read_fd, &read_buf));
    if (close(read_fd) < 0) return error.SyscallFailed;

    if (bytes_read != expected.len) return error.ShortRead;
    if (!std.mem.eql(u8, read_buf[0..bytes_read], expected)) return error.DataMismatch;

    _ = write(STDOUT, "filesystem descriptor API OK\n");
    yield();
    _ = write(STDOUT, "stdout still works after file I/O\n");
    _ = STDERR;
    _ = STDIN;
}

pub export fn _start() void {
    main() catch {
        _ = write(STDOUT, "Error occurred.\n");
        exit(1);
    };
    exit(0);
}
