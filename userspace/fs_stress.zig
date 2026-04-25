const std = @import("std");
const sys = @import("sys.zig");

const FAIL = 0xFFFFFFFF;

fn expectSyscall(rc: u32) !u32 {
    if (rc == FAIL) return error.SyscallFailed;
    return rc;
}

const stress_file_a = "fdstrs_a.txt";
const stress_file_b = "fdstrs_b.txt";
const seek_file = "seek.txt";
const unlink_file = "unlink.txt";
const nonexistent_file = "nonexistent.txt";
const chunk_size = 640;
const chunk_count = 6;
const total_bytes = chunk_size * chunk_count;
const seek_expected = "01234AB789XY\x00\x00Z";

fn writeAll(fd: u32, buf: []const u8) !void {
    const written = try expectSyscall(sys.write(fd, buf));
    if (written != buf.len) return error.ShortWrite;
}

fn readExact(fd: u32, dest: []u8) !void {
    var filled: usize = 0;
    while (filled < dest.len) {
        const bytes_read = try expectSyscall(sys.read(fd, dest[filled..]));
        if (bytes_read == 0) return error.ShortRead;
        filled += bytes_read;
    }
}

fn expectEof(fd: u32) !void {
    var buf: [1]u8 = undefined;
    const bytes_read = try expectSyscall(sys.read(fd, &buf));
    if (bytes_read != 0) return error.ExpectedEof;
}

fn expectOffset(actual: u32, expected: u32) !void {
    if (actual != expected) return error.UnexpectedOffset;
}

fn expectBytes(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) return error.DataMismatch;
}

fn fillChunk(dest: []u8, file_tag: u8, iteration: usize) void {
    var index: usize = 0;
    while (index < dest.len) : (index += 1) {
        const iter_byte: u8 = @intCast(iteration);
        const idx_byte: u8 = @intCast(index % 251);
        dest[index] = switch (index % 8) {
            0 => file_tag,
            1 => '0' + iter_byte,
            2 => ':',
            3 => 'a' + iter_byte,
            4 => '0' + @as(u8, @intCast(iteration % 10)),
            5 => 'A' + idx_byte % 26,
            6 => '0' + idx_byte % 10,
            else => '#',
        };
    }
}

fn verifyFileContents(path: []const u8, expected: []const u8) !void {
    const fd = try expectSyscall(sys.open(path, .{}));
    defer _ = sys.close(fd);

    var actual: [total_bytes]u8 = undefined;
    try readExact(fd, &actual);
    try expectEof(fd);
    if (!std.mem.eql(u8, &actual, expected)) return error.DataMismatch;
}

fn verifySeekSemantics() !void {
    const fd = try expectSyscall(sys.open(seek_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }));
    errdefer _ = sys.close(fd);

    try writeAll(fd, "0123456789");
    try expectOffset(try expectSyscall(sys.lseek(fd, 4, .Set)), 4);

    var window: [3]u8 = undefined;
    const bytes_read = try expectSyscall(sys.read(fd, &window));
    if (bytes_read != window.len) return error.ShortRead;
    try expectBytes(&window, "456");

    try expectOffset(try expectSyscall(sys.lseek(fd, -2, .Cur)), 5);
    try writeAll(fd, "AB");

    try expectOffset(try expectSyscall(sys.lseek(fd, 0, .End)), 10);
    try writeAll(fd, "XY");

    try expectOffset(try expectSyscall(sys.lseek(fd, 2, .End)), 14);
    try writeAll(fd, "Z");

    if (sys.lseek(fd, -100, .Cur) != FAIL) return error.ExpectedFailure;
    if (sys.lseek(sys.STDOUT, 0, .Set) != FAIL) return error.ExpectedFailure;

    if (sys.close(fd) == FAIL) return error.SyscallFailed;

    const verify_fd = try expectSyscall(sys.open(seek_file, .{}));
    defer _ = sys.close(verify_fd);

    var actual: [seek_expected.len]u8 = undefined;
    try readExact(verify_fd, &actual);
    try expectEof(verify_fd);
    try expectBytes(&actual, seek_expected);
}

fn verifyUnlinkSemantics() !void {
    const fd = try expectSyscall(sys.open(unlink_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }));

    try writeAll(fd, "temporary contents");

    if (sys.unlink(unlink_file) != FAIL) {
        _ = sys.write(sys.STDOUT, "unexpectedly unlinked open file\n");
        _ = sys.close(fd);
        return error.SyscallFailed;
    }

    if (sys.close(fd) == FAIL) return error.SyscallFailed;
    if (sys.unlink(unlink_file) == FAIL) return error.SyscallFailed;

    if (sys.open(unlink_file, .{}) != FAIL) {
        _ = sys.write(sys.STDOUT, "unexpectedly reopened unlinked file\n");
        return error.SyscallFailed;
    }

    if (sys.unlink(unlink_file) != FAIL) {
        _ = sys.write(sys.STDOUT, "unexpectedly unlinked missing file\n");
        return error.SyscallFailed;
    }
}

/// Exercises filesystem syscalls with alternating writes, seeks, and unlinks.
pub fn main(argv: []const []const u8) !void {
    _ = argv;
    var buf: [96]u8 = undefined;
    _ = sys.write(sys.STDOUT, try std.fmt.bufPrint(&buf, "pid {d}: stress-testing filesystem syscalls...\n", .{sys.getpid()}));

    const create_flags: sys.FileOpenFlags = .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    };
    const fd_a = try expectSyscall(sys.open(stress_file_a, create_flags));
    const fd_b = try expectSyscall(sys.open(stress_file_b, create_flags));

    const fd_c = sys.open(nonexistent_file, .{});
    if (fd_c != FAIL) {
        _ = sys.write(sys.STDOUT, "unexpectedly opened nonexistent file\n");
        _ = sys.close(fd_c);
        return error.SyscallFailed;
    }

    var expected_a: [total_bytes]u8 = undefined;
    var expected_b: [total_bytes]u8 = undefined;
    var chunk_a: [chunk_size]u8 = undefined;
    var chunk_b: [chunk_size]u8 = undefined;

    var iteration: usize = 0;
    while (iteration < chunk_count) : (iteration += 1) {
        fillChunk(&chunk_a, 'A', iteration);
        fillChunk(&chunk_b, 'B', iteration);

        const start = iteration * chunk_size;
        @memcpy(expected_a[start .. start + chunk_size], &chunk_a);
        @memcpy(expected_b[start .. start + chunk_size], &chunk_b);

        try writeAll(fd_a, &chunk_a);
        try writeAll(fd_b, &chunk_b);
    }

    _ = try expectSyscall(sys.close(fd_a));
    _ = try expectSyscall(sys.close(fd_b));

    try verifyFileContents(stress_file_a, &expected_a);
    try verifyFileContents(stress_file_b, &expected_b);
    try verifySeekSemantics();
    try verifyUnlinkSemantics();

    _ = sys.write(sys.STDOUT, "filesystem alternating descriptor stress test OK\n");
    sys.yield();
}

comptime {
    _ = sys._start;
}
