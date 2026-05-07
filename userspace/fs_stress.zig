const std = @import("std");
const sys = @import("sys.zig");

const FAIL = 0xFFFFFFFF;

inline fn expectSyscall(rc: u32, comptime step: []const u8, comptime callsite: std.builtin.SourceLocation) !u32 {
    if (rc == FAIL) {
        var buf: [160]u8 = undefined;
        _ = sys.write(sys.STDOUT, try std.fmt.bufPrint(&buf, "syscall failed: {s} ({s}:{})\n", .{ step, callsite.file, callsite.line }));
        return error.SyscallFailed;
    }
    _ = sys.write(sys.STDOUT, ".");
    return rc;
}

inline fn syscallShouldFail(rc: u32, comptime step: []const u8, comptime callsite: std.builtin.SourceLocation) !void {
    if (rc != FAIL) {
        var buf: [160]u8 = undefined;
        _ = sys.write(sys.STDOUT, try std.fmt.bufPrint(&buf, "syscall unexpectedly succeeded: {s} ({s}:{})\n", .{ step, callsite.file, callsite.line }));
        return error.ExpectedFailure;
    }
    _ = sys.write(sys.STDOUT, ".");
}

const tmpdir = "/tmp";
const stress_file_a = tmpdir ++ "/fdstrs_a.txt";
const stress_file_b = tmpdir ++ "/fdstrs_b.txt";
const seek_file = tmpdir ++ "/seek.txt";
const sparse_seek_file = tmpdir ++ "/sparse_seek.txt";
const unlink_file = tmpdir ++ "/unlink.txt";
const nonexistent_file = "nonexistent.txt";
const sector_size = 512;
const chunk_size = 640;
const chunk_count = 6;
const total_bytes = chunk_size * chunk_count;
const seek_expected = "01234AB789XY\x00\x00Z";

fn writeAll(fd: u32, buf: []const u8) !void {
    const written = try expectSyscall(sys.write(fd, buf), "writeAll: write", @src());
    if (written != buf.len) return error.ShortWrite;
}

fn readExact(fd: u32, dest: []u8) !void {
    var filled: usize = 0;
    while (filled < dest.len) {
        const bytes_read = try expectSyscall(sys.read(fd, dest[filled..]), "readExact: read", @src());
        if (bytes_read == 0) return error.ShortRead;
        filled += bytes_read;
    }
}

fn expectEof(fd: u32) !void {
    var buf: [1]u8 = undefined;
    const bytes_read = try expectSyscall(sys.read(fd, &buf), "expectEof: read", @src());
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
    const fd = try expectSyscall(sys.open(path, .{}), "verifyFileContents: open", @src());
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
    }), "verifySeekSemantics: open seek file", @src());
    errdefer _ = sys.close(fd);

    try writeAll(fd, "0123456789");
    try expectOffset(try expectSyscall(sys.lseek(fd, 4, .Set), "verifySeekSemantics: lseek set 4", @src()), 4);

    var window: [3]u8 = undefined;
    const bytes_read = try expectSyscall(sys.read(fd, &window), "verifySeekSemantics: read window", @src());
    if (bytes_read != window.len) return error.ShortRead;
    try expectBytes(&window, "456");

    try expectOffset(try expectSyscall(sys.lseek(fd, -2, .Cur), "verifySeekSemantics: lseek cur -2", @src()), 5);
    try writeAll(fd, "AB");

    try expectOffset(try expectSyscall(sys.lseek(fd, 0, .End), "verifySeekSemantics: lseek end 0", @src()), 10);
    try writeAll(fd, "XY");

    try expectOffset(try expectSyscall(sys.lseek(fd, 2, .End), "verifySeekSemantics: lseek end +2", @src()), 14);
    try writeAll(fd, "Z");

    try syscallShouldFail(sys.lseek(fd, -100, .Cur), "verifySeekSemantics: lseek cur -100", @src());
    try syscallShouldFail(sys.lseek(sys.STDOUT, 0, .Set), "verifySeekSemantics: lseek stdout set 0", @src());

    if (sys.close(fd) == FAIL) return error.SyscallFailed;

    const verify_fd = try expectSyscall(sys.open(seek_file, .{}), "verifySeekSemantics: reopen seek file", @src());
    defer _ = sys.close(verify_fd);

    var actual: [seek_expected.len]u8 = undefined;
    try readExact(verify_fd, &actual);
    try expectEof(verify_fd);
    try expectBytes(&actual, seek_expected);
}

// Writes several seed files with nonzero data, then deletes them.
// This hardens the seeking test by ensuring that the disk contains sectors that must be explicitly zeroed.
fn seedDiskWithNonzeroData() !void {
    var seed: [sector_size]u8 = undefined;
    var seed_name_buf: [10]u8 = undefined;
    for (0..10) |seed_index| {
        const seed_name = try std.fmt.bufPrint(&seed_name_buf, "seed{d:0>2}.txt", .{seed_index});
        const seed_fd = try expectSyscall(sys.open(seed_name, .{
            .open_mode = .ReadWrite,
            .create = true,
            .truncate = true,
        }), "verifySparseSeekSemantics: open seed file", @src());
        errdefer _ = sys.close(seed_fd);

        @memset(&seed, @as(u8, '0') + @as(u8, @intCast(seed_index)));
        try writeAll(seed_fd, &seed);
        _ = try expectSyscall(sys.close(seed_fd), "verifySparseSeekSemantics: close seed file", @src());
        _ = try expectSyscall(sys.unlink(seed_name), "verifySparseSeekSemantics: unlink seed file", @src());
    }
}

fn verifySparseSeekSemantics() !void {
    try seedDiskWithNonzeroData();

    const fd = try expectSyscall(sys.open(sparse_seek_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "verifySparseSeekSemantics: open sparse file", @src());
    errdefer _ = sys.close(fd);

    var head: [sector_size]u8 = undefined;
    var tail: [sector_size]u8 = undefined;
    @memset(&head, 'H');
    @memset(&tail, 'T');

    try writeAll(fd, &head);
    try expectOffset(try expectSyscall(sys.lseek(fd, sector_size * 2, .End), "verifySparseSeekSemantics: lseek end +2 sectors", @src()), sector_size * 3);
    try writeAll(fd, &tail);
    _ = try expectSyscall(sys.close(fd), "verifySparseSeekSemantics: close sparse file", @src());

    const verify_fd = try expectSyscall(sys.open(sparse_seek_file, .{}), "verifySparseSeekSemantics: reopen sparse file", @src());
    defer _ = sys.close(verify_fd);

    var actual: [sector_size * 4]u8 = undefined;
    var expected: [sector_size * 4]u8 = undefined;
    @memset(&expected, 0);
    @memcpy(expected[0..sector_size], &head);
    @memcpy(expected[sector_size * 3 ..], &tail);

    try readExact(verify_fd, &actual);
    try expectEof(verify_fd);
    try expectBytes(&actual, &expected);
}

fn verifyUnlinkSemantics() !void {
    const fd = try expectSyscall(sys.open(unlink_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "verifyUnlinkSemantics: open unlink file", @src());

    try writeAll(fd, "temporary contents");

    if (sys.unlink(unlink_file) != FAIL) {
        _ = sys.write(sys.STDOUT, "unexpectedly unlinked open file\n");
        _ = sys.close(fd);
        return error.SyscallFailed;
    }

    _ = try expectSyscall(sys.close(fd), "verifyUnlinkSemantics: close before unlink", @src());
    _ = try expectSyscall(sys.unlink(unlink_file), "verifyUnlinkSemantics: unlink closed file", @src());

    _ = try syscallShouldFail(sys.open(unlink_file, .{}), "verifyUnlinkSemantics: open unlinked file", @src());
    _ = try syscallShouldFail(sys.unlink(unlink_file), "verifyUnlinkSemantics: unlink missing file", @src());
}

fn verifyRmdirSemantics() !void {
    const test_dir = "/tmp_rmdir";
    const sub_file = test_dir ++ "/file.txt";

    _ = try syscallShouldFail(sys.open(sub_file, .{
        .open_mode = .ReadWrite,
        .create = true,
    }), "verifyRmdirSemantics: open subfile in non-existent directory", @src());

    _ = sys.mkdir(test_dir) catch {};

    // 1. Fail to remove non-empty directory
    const fd = try expectSyscall(sys.open(sub_file, .{
        .open_mode = .ReadWrite,
        .create = true,
    }), "verifyRmdirSemantics: create subfile", @src());
    _ = try expectSyscall(sys.write(fd, "data"), "verifyRmdirSemantics: write subfile", @src());
    _ = try expectSyscall(sys.close(fd), "verifyRmdirSemantics: close subfile", @src());

    _ = try syscallShouldFail(sys.rmdir(test_dir), "verifyRmdirSemantics: rmdir non-empty directory", @src());

    // 2. Succeed to remove empty directory
    _ = try expectSyscall(sys.unlink(sub_file), "verifyRmdirSemantics: unlink subfile", @src());
    _ = try expectSyscall(sys.rmdir(test_dir), "verifyRmdirSemantics: rmdir empty directory", @src());

    // 3. Fail to remove nonexistent directory
    _ = try syscallShouldFail(sys.rmdir(test_dir), "verifyRmdirSemantics: rmdir missing directory", @src());
}

/// Exercises filesystem syscalls with alternating writes, seeks, and unlinks.
pub fn main(argv: []const []const u8) !void {
    _ = argv;
    var buf: [96]u8 = undefined;
    _ = sys.write(sys.STDOUT, try std.fmt.bufPrint(&buf, "pid {d}: stress-testing filesystem syscalls...\n", .{sys.getpid()}));

    _ = sys.mkdir(tmpdir) catch {}; // on error, assume tmp exists

    const create_flags: sys.FileOpenFlags = .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    };
    const fd_a = try expectSyscall(sys.open(stress_file_a, create_flags), "main: open stress_file_a", @src());
    const fd_b = try expectSyscall(sys.open(stress_file_b, create_flags), "main: open stress_file_b", @src());

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

    _ = try expectSyscall(sys.close(fd_a), "main: close stress_file_a", @src());
    _ = try expectSyscall(sys.close(fd_b), "main: close stress_file_b", @src());

    try verifyFileContents(stress_file_a, &expected_a);
    try verifyFileContents(stress_file_b, &expected_b);
    try verifySeekSemantics();
    try verifySparseSeekSemantics();
    try verifyUnlinkSemantics();
    try verifyRmdirSemantics();

    _ = sys.write(sys.STDOUT, "filesystem tests OK\n");
    sys.yield();
}

comptime {
    _ = sys._start;
}
