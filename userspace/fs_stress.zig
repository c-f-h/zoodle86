const std = @import("std");
const sys = @import("sys.zig");

inline fn expectSyscall(rc: anytype, comptime step: []const u8, comptime callsite: std.builtin.SourceLocation) !@typeInfo(@TypeOf(rc)).error_union.payload {
    const result = rc catch |err| {
        var buf: [160]u8 = undefined;
        _ = sys.write(
            sys.STDOUT,
            try std.fmt.bufPrint(&buf, "syscall failed: {s} ({s}:{}): {s}\n", .{ step, callsite.file, callsite.line, @errorName(err) }),
        ) catch {};
        return error.SyscallFailed;
    };
    _ = sys.write(sys.STDOUT, ".") catch {};
    return result;
}

inline fn checkSyscall(rc: anytype, comptime step: []const u8, comptime callsite: std.builtin.SourceLocation) !@typeInfo(@TypeOf(rc)).error_union.payload {
    return expectSyscall(rc, step, callsite);
}

inline fn syscallShouldFail(rc: anytype, comptime step: []const u8, comptime callsite: std.builtin.SourceLocation) !void {
    _ = rc catch {
        _ = sys.write(sys.STDOUT, ".") catch {};
        return;
    };
    var buf: [160]u8 = undefined;
    _ = sys.write(
        sys.STDOUT,
        try std.fmt.bufPrint(&buf, "syscall unexpectedly succeeded: {s} ({s}:{})\n", .{ step, callsite.file, callsite.line }),
    ) catch {};
    return error.ExpectedFailure;
}

inline fn callShouldFail(rc: anytype, comptime step: []const u8, comptime callsite: std.builtin.SourceLocation) !void {
    return syscallShouldFail(rc, step, callsite);
}

const tmpdir = "/tmp";
const stress_file_a = tmpdir ++ "/fdstrs_a.txt";
const stress_file_b = tmpdir ++ "/fdstrs_b.txt";
const seek_file = tmpdir ++ "/seek.txt";
const sparse_seek_file = tmpdir ++ "/sparse_seek.txt";
const truncate_file = tmpdir ++ "/truncate.txt";
const unlink_file = tmpdir ++ "/unlink.txt";
const link_source_file = tmpdir ++ "/link_src.txt";
const link_alias_file = tmpdir ++ "/link_alias.txt";
const rename_src = tmpdir ++ "/rename_src.txt";
const rename_dst = tmpdir ++ "/rename_dst.txt";
const stat_file = tmpdir ++ "/stat.txt";
const stat_link = tmpdir ++ "/stat_link.txt";
const stat_dir = tmpdir ++ "/stat_dir";
const dirent_dir = tmpdir ++ "/dirents";
const dirent_file = dirent_dir ++ "/entry.txt";
const dirent_subdir = dirent_dir ++ "/nested";
const nonexistent_file = "nonexistent.txt";
const sector_size = 512;
const pipe_capacity = 4096;
const chunk_size = 640;
const chunk_count = 6;
const total_bytes = chunk_size * chunk_count;
const seek_expected = "01234AB789XY\x00\x00Z";
const truncate_expected = "ABCD\x00\x00\x00\x00\x00\x00";
const stat_payload = "stat payload";

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

fn expectKind(actual: sys.FileKind, expected: sys.FileKind) !void {
    if (actual != expected) return error.UnexpectedKind;
}

fn expectFlags(actual: u32, expected_mask: u32) !void {
    if ((actual & expected_mask) != expected_mask) return error.MissingFlags;
}

fn expectDirEntryName(actual: *const sys.DirEntry, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual.name[0..actual.name_len], expected)) return error.DataMismatch;
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
    defer sys.close(fd) catch {};

    var actual: [total_bytes]u8 = undefined;
    try readExact(fd, &actual);
    try expectEof(fd);
    try expectBytes(&actual, expected);
}

fn testSeek() !void {
    const fd = try expectSyscall(sys.open(seek_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testSeek: open seek file", @src());
    errdefer sys.close(fd) catch {};

    try writeAll(fd, "0123456789");
    try expectOffset(try expectSyscall(sys.lseek(fd, 4, .Set), "testSeek: lseek set 4", @src()), 4);

    var window: [3]u8 = undefined;
    const bytes_read = try expectSyscall(sys.read(fd, &window), "testSeek: read window", @src());
    if (bytes_read != window.len) return error.ShortRead;
    try expectBytes(&window, "456");

    try expectOffset(try expectSyscall(sys.lseek(fd, -2, .Cur), "testSeek: lseek cur -2", @src()), 5);
    try writeAll(fd, "AB");

    try expectOffset(try expectSyscall(sys.lseek(fd, 0, .End), "testSeek: lseek end 0", @src()), 10);
    try writeAll(fd, "XY");

    try expectOffset(try expectSyscall(sys.lseek(fd, 2, .End), "testSeek: lseek end +2", @src()), 14);
    try writeAll(fd, "Z");

    try syscallShouldFail(sys.lseek(fd, -100, .Cur), "testSeek: lseek cur -100", @src());
    try syscallShouldFail(sys.lseek(sys.STDOUT, 0, .Set), "testSeek: lseek stdout set 0", @src());

    _ = try expectSyscall(sys.close(fd), "testSeek: close seek file", @src());

    const verify_fd = try expectSyscall(sys.open(seek_file, .{}), "testSeek: reopen seek file", @src());
    defer sys.close(verify_fd) catch {};

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
        }), "testSparseSeek: open seed file", @src());
        errdefer sys.close(seed_fd) catch {};

        @memset(&seed, @as(u8, '0') + @as(u8, @intCast(seed_index)));
        try writeAll(seed_fd, &seed);
        _ = try expectSyscall(sys.close(seed_fd), "testSparseSeek: close seed file", @src());
        _ = try expectSyscall(sys.unlink(seed_name), "testSparseSeek: unlink seed file", @src());
    }
}

fn testSparseSeek() !void {
    try seedDiskWithNonzeroData();

    const fd = try expectSyscall(sys.open(sparse_seek_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testSparseSeek: open sparse file", @src());
    errdefer sys.close(fd) catch {};

    var head: [sector_size]u8 = undefined;
    var tail: [sector_size]u8 = undefined;
    @memset(&head, 'H');
    @memset(&tail, 'T');

    try writeAll(fd, &head);
    try expectOffset(try expectSyscall(sys.lseek(fd, sector_size * 2, .End), "testSparseSeek: lseek end +2 sectors", @src()), sector_size * 3);
    try writeAll(fd, &tail);
    _ = try expectSyscall(sys.close(fd), "testSparseSeek: close sparse file", @src());

    const verify_fd = try expectSyscall(sys.open(sparse_seek_file, .{}), "testSparseSeek: reopen sparse file", @src());
    defer sys.close(verify_fd) catch {};

    var actual: [sector_size * 4]u8 = undefined;
    var expected: [sector_size * 4]u8 = undefined;
    @memset(&expected, 0);
    @memcpy(expected[0..sector_size], &head);
    @memcpy(expected[sector_size * 3 ..], &tail);

    try readExact(verify_fd, &actual);
    try expectEof(verify_fd);
    try expectBytes(&actual, &expected);
}

fn testUnlink() !void {
    const fd = try expectSyscall(sys.open(unlink_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testUnlink: open unlink file", @src());

    try writeAll(fd, "temporary contents");

    var unlinked_open_file = true;
    sys.unlink(unlink_file) catch {
        unlinked_open_file = false;
    };
    if (unlinked_open_file) {
        _ = sys.write(sys.STDOUT, "unexpectedly unlinked open file\n") catch {};
        sys.close(fd) catch {};
        return error.SyscallFailed;
    }

    _ = try expectSyscall(sys.close(fd), "testUnlink: close before unlink", @src());
    _ = try expectSyscall(sys.unlink(unlink_file), "testUnlink: unlink closed file", @src());

    _ = try syscallShouldFail(sys.open(unlink_file, .{}), "testUnlink: open unlinked file", @src());
    _ = try syscallShouldFail(sys.unlink(unlink_file), "testUnlink: unlink missing file", @src());
}

fn testLink() !void {
    const fd = try expectSyscall(sys.open(link_source_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testLink: create source file", @src());
    errdefer sys.close(fd) catch {};

    try writeAll(fd, "hard");
    _ = try expectSyscall(sys.close(fd), "testLink: close source file", @src());

    _ = try expectSyscall(sys.link(link_source_file, link_alias_file), "testLink: create hard link", @src());
    _ = try syscallShouldFail(sys.link(link_source_file, link_alias_file), "testLink: duplicate hard link path", @src());
    _ = try syscallShouldFail(sys.link(nonexistent_file, link_alias_file ++ "2"), "testLink: missing source path", @src());
    _ = try syscallShouldFail(sys.link(tmpdir, link_alias_file ++ "3"), "testLink: directory source path", @src());

    const append_fd = try expectSyscall(sys.open(link_alias_file, .{
        .open_mode = .ReadWrite,
    }), "testLink: open hard link", @src());
    errdefer sys.close(append_fd) catch {};
    try expectOffset(try expectSyscall(sys.lseek(append_fd, 0, .End), "testLink: seek hard link end", @src()), 4);
    try writeAll(append_fd, " link");
    _ = try expectSyscall(sys.close(append_fd), "testLink: close hard link", @src());

    const source_verify_fd = try expectSyscall(sys.open(link_source_file, .{}), "testLink: reopen source file", @src());
    var shared_contents: ["hard link".len]u8 = undefined;
    try readExact(source_verify_fd, &shared_contents);
    try expectEof(source_verify_fd);
    try expectBytes(&shared_contents, "hard link");
    _ = try expectSyscall(sys.close(source_verify_fd), "testLink: close source verify fd", @src());

    _ = try expectSyscall(sys.unlink(link_source_file), "testLink: unlink source path", @src());
    _ = try syscallShouldFail(sys.open(link_source_file, .{}), "testLink: source path removed", @src());

    const alias_verify_fd = try expectSyscall(sys.open(link_alias_file, .{}), "testLink: reopen remaining link", @src());
    var alias_contents: ["hard link".len]u8 = undefined;
    try readExact(alias_verify_fd, &alias_contents);
    try expectEof(alias_verify_fd);
    try expectBytes(&alias_contents, "hard link");
    _ = try expectSyscall(sys.close(alias_verify_fd), "testLink: close alias verify fd", @src());

    _ = try expectSyscall(sys.unlink(link_alias_file), "testLink: unlink remaining link", @src());
    _ = try syscallShouldFail(sys.open(link_alias_file, .{}), "testLink: alias path removed", @src());
}

fn testRename() !void {
    sys.unlink(rename_src) catch {};
    sys.unlink(rename_dst) catch {};

    // 1. Basic rename: old path disappears, new path holds the content, inode is preserved.
    const fd = try expectSyscall(sys.open(rename_src, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create src", @src());
    try writeAll(fd, "rename me");
    var src_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(fd, &src_stat), "testRename: fstat src", @src());
    _ = try expectSyscall(sys.close(fd), "testRename: close src", @src());

    _ = try expectSyscall(sys.rename(rename_src, rename_dst), "testRename: basic rename", @src());
    _ = try syscallShouldFail(sys.open(rename_src, .{}), "testRename: src gone", @src());

    const verify_fd = try expectSyscall(sys.open(rename_dst, .{}), "testRename: open dst", @src());
    var dst_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(verify_fd, &dst_stat), "testRename: fstat dst", @src());
    if (dst_stat.inode != src_stat.inode) return error.InodeMismatch;
    _ = sys.write(sys.STDOUT, ".") catch {};
    var content: ["rename me".len]u8 = undefined;
    try readExact(verify_fd, &content);
    try expectEof(verify_fd);
    try expectBytes(&content, "rename me");
    _ = try expectSyscall(sys.close(verify_fd), "testRename: close dst", @src());

    // 2. Rename onto an existing file replaces it; new file's data must be visible.
    const src2_fd = try expectSyscall(sys.open(rename_src, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create src for overwrite", @src());
    try writeAll(src2_fd, "winner");
    _ = try expectSyscall(sys.close(src2_fd), "testRename: close src for overwrite", @src());

    _ = try expectSyscall(sys.rename(rename_src, rename_dst), "testRename: overwrite rename", @src());
    _ = try syscallShouldFail(sys.open(rename_src, .{}), "testRename: src gone after overwrite", @src());

    const overwrite_fd = try expectSyscall(sys.open(rename_dst, .{}), "testRename: open overwritten dst", @src());
    var winner: ["winner".len]u8 = undefined;
    try readExact(overwrite_fd, &winner);
    try expectEof(overwrite_fd);
    try expectBytes(&winner, "winner");
    _ = try expectSyscall(sys.close(overwrite_fd), "testRename: close overwrite verify", @src());
    _ = try expectSyscall(sys.unlink(rename_dst), "testRename: unlink dst", @src());

    // 3. Rename to itself is a no-op; file must still exist.
    const self_fd = try expectSyscall(sys.open(rename_src, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create self-rename file", @src());
    try writeAll(self_fd, "self");
    _ = try expectSyscall(sys.close(self_fd), "testRename: close self-rename file", @src());
    _ = try expectSyscall(sys.rename(rename_src, rename_src), "testRename: self-rename", @src());
    _ = try expectSyscall(sys.unlink(rename_src), "testRename: cleanup self-rename", @src());

    // 4. Rename fails when source does not exist.
    _ = try syscallShouldFail(sys.rename(rename_src, rename_dst), "testRename: nonexistent src", @src());

    // 5. Rename fails when source is a directory.
    _ = try syscallShouldFail(sys.rename(tmpdir, rename_dst), "testRename: directory src", @src());

    // 6. Rename fails when the destination parent directory does not exist.
    const src3_fd = try expectSyscall(sys.open(rename_src, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create src for bad-parent test", @src());
    _ = try expectSyscall(sys.close(src3_fd), "testRename: close src for bad-parent test", @src());
    _ = try syscallShouldFail(sys.rename(rename_src, "/no_such_dir/file.txt"), "testRename: bad dst parent", @src());
    _ = try expectSyscall(sys.unlink(rename_src), "testRename: cleanup src (bad-parent)", @src());

    // 7. Rename fails when the destination file is currently open.
    const src4_fd = try expectSyscall(sys.open(rename_src, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create src for open-dst test", @src());
    try writeAll(src4_fd, "data");
    _ = try expectSyscall(sys.close(src4_fd), "testRename: close src for open-dst test", @src());

    const open_dst_fd = try expectSyscall(sys.open(rename_dst, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create open dst", @src());
    try writeAll(open_dst_fd, "open");
    _ = try syscallShouldFail(sys.rename(rename_src, rename_dst), "testRename: rename onto open dst", @src());
    _ = try expectSyscall(sys.close(open_dst_fd), "testRename: close open dst", @src());
    _ = try expectSyscall(sys.unlink(rename_src), "testRename: cleanup src (open-dst)", @src());
    _ = try expectSyscall(sys.unlink(rename_dst), "testRename: cleanup open dst", @src());
}

fn testTruncate() !void {
    const fd = try expectSyscall(sys.open(truncate_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testTruncate: open truncate file", @src());
    errdefer sys.close(fd) catch {};

    try writeAll(fd, "ABCDEFGHIJ");
    try expectOffset(try expectSyscall(sys.lseek(fd, 3, .Set), "testTruncate: lseek set 3", @src()), 3);
    _ = try expectSyscall(sys.ftruncate(fd, 4), "testTruncate: shrink to 4", @src());
    try expectOffset(try expectSyscall(sys.lseek(fd, 0, .Cur), "testTruncate: current offset after shrink", @src()), 3);

    try expectOffset(try expectSyscall(sys.lseek(fd, 1, .Set), "testTruncate: lseek set 1", @src()), 1);
    _ = try expectSyscall(sys.ftruncate(fd, 10), "testTruncate: grow to 10", @src());
    try expectOffset(try expectSyscall(sys.lseek(fd, 0, .Cur), "testTruncate: current offset after grow", @src()), 1);

    _ = try expectSyscall(sys.close(fd), "testTruncate: close truncation fd", @src());

    const verify_fd = try expectSyscall(sys.open(truncate_file, .{}), "testTruncate: reopen truncate file", @src());
    defer sys.close(verify_fd) catch {};

    var actual: [truncate_expected.len]u8 = undefined;
    try readExact(verify_fd, &actual);
    try expectEof(verify_fd);
    try expectBytes(&actual, truncate_expected);

    try syscallShouldFail(sys.ftruncate(verify_fd, 2), "testTruncate: truncate readonly fd", @src());
    try syscallShouldFail(sys.ftruncate(sys.STDOUT, 0), "testTruncate: truncate stdout", @src());
}

fn testRmdir() !void {
    const test_dir = "/tmp_rmdir";
    const sub_file = test_dir ++ "/file.txt";

    _ = try syscallShouldFail(sys.open(sub_file, .{
        .open_mode = .ReadWrite,
        .create = true,
    }), "testRmdir: open subfile in non-existent directory", @src());

    sys.mkdir(test_dir) catch {};

    // 1. Fail to remove non-empty directory
    const fd = try expectSyscall(sys.open(sub_file, .{
        .open_mode = .ReadWrite,
        .create = true,
    }), "testRmdir: create subfile", @src());
    _ = try expectSyscall(sys.write(fd, "data"), "testRmdir: write subfile", @src());
    _ = try expectSyscall(sys.close(fd), "testRmdir: close subfile", @src());

    _ = try syscallShouldFail(sys.rmdir(test_dir), "testRmdir: rmdir non-empty directory", @src());

    // 2. Succeed to remove empty directory
    _ = try expectSyscall(sys.unlink(sub_file), "testRmdir: unlink subfile", @src());
    _ = try expectSyscall(sys.rmdir(test_dir), "testRmdir: rmdir empty directory", @src());

    // 3. Fail to remove nonexistent directory
    _ = try syscallShouldFail(sys.rmdir(test_dir), "testRmdir: rmdir missing directory", @src());
}

fn testPipe() !void {
    const read_fd, const write_fd = try checkSyscall(sys.pipe(), "testPipe: create pipe", @src());

    try writeAll(write_fd, "hello, ");
    try writeAll(write_fd, "world!");

    var buf: [13]u8 = undefined;
    try readExact(read_fd, &buf);

    // close writer so that reader can detect EOF
    _ = try expectSyscall(sys.close(write_fd), "testPipe: close write end", @src());

    try expectEof(read_fd);
    try expectBytes(&buf, "hello, world!");

    _ = try expectSyscall(sys.close(read_fd), "testPipe: close read end", @src());
}

fn testStat() !void {
    sys.unlink(stat_link) catch {};
    sys.unlink(stat_file) catch {};
    sys.rmdir(stat_dir) catch {};
    sys.mkdir(stat_dir) catch {};

    const fd = try expectSyscall(sys.open(stat_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testStat: open stat file", @src());
    errdefer sys.close(fd) catch {};

    try writeAll(fd, stat_payload);

    var fd_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(fd, &fd_stat), "testStat: fstat regular file", @src());
    try expectKind(fd_stat.kind, .Regular);
    try expectOffset(fd_stat.size, stat_payload.len);
    try expectOffset(fd_stat.blocks, 1);
    try expectOffset(fd_stat.blksize, sector_size);
    try expectOffset(fd_stat.nlink, 1);
    try expectFlags(fd_stat.flags, sys.STAT_FLAG_READABLE | sys.STAT_FLAG_WRITABLE);

    var path_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(stat_file, &path_stat), "testStat: stat regular file", @src());
    try expectKind(path_stat.kind, .Regular);
    try expectOffset(path_stat.size, stat_payload.len);
    try expectOffset(path_stat.blocks, 1);
    try expectOffset(path_stat.blksize, sector_size);
    try expectOffset(path_stat.nlink, 1);
    if (path_stat.inode != fd_stat.inode) return error.StatMismatch;
    if (path_stat.flags != 0) return error.UnexpectedFlags;

    _ = try expectSyscall(sys.link(stat_file, stat_link), "testStat: create hard link", @src());

    var link_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(stat_link, &link_stat), "testStat: stat hard link", @src());
    if (link_stat.inode != fd_stat.inode) return error.StatMismatch;
    try expectOffset(link_stat.nlink, 2);

    _ = try expectSyscall(sys.fstat(fd, &fd_stat), "testStat: fstat linked file", @src());
    try expectOffset(fd_stat.nlink, 2);

    var dir_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(stat_dir, &dir_stat), "testStat: stat directory", @src());
    try expectKind(dir_stat.kind, .Directory);
    if (dir_stat.size == 0) return error.StatMismatch;
    try expectOffset(dir_stat.blksize, sector_size);
    try expectOffset(dir_stat.nlink, 1);

    var stdout_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(sys.STDOUT, &stdout_stat), "testStat: fstat stdout", @src());
    try expectKind(stdout_stat.kind, .CharDevice);
    try expectOffset(stdout_stat.inode, 0);
    try expectOffset(stdout_stat.blksize, 4096); // size of tty buffer
    try expectOffset(stdout_stat.nlink, 1);
    try expectFlags(stdout_stat.flags, sys.STAT_FLAG_WRITABLE | sys.STAT_FLAG_SYNTHETIC);

    const read_fd, const write_fd = try checkSyscall(sys.pipe(), "testStat: create pipe", @src());
    errdefer sys.close(read_fd) catch {};
    errdefer sys.close(write_fd) catch {};

    var read_stat: sys.Stat = undefined;
    var write_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(read_fd, &read_stat), "testStat: fstat pipe reader", @src());
    _ = try expectSyscall(sys.fstat(write_fd, &write_stat), "testStat: fstat pipe writer", @src());
    try expectKind(read_stat.kind, .Pipe);
    try expectKind(write_stat.kind, .Pipe);
    try expectOffset(read_stat.size, 0);
    try expectOffset(read_stat.blksize, pipe_capacity);
    try expectOffset(write_stat.blksize, pipe_capacity);
    try expectFlags(read_stat.flags, sys.STAT_FLAG_READABLE | sys.STAT_FLAG_SYNTHETIC);
    try expectFlags(write_stat.flags, sys.STAT_FLAG_WRITABLE | sys.STAT_FLAG_SYNTHETIC);

    try writeAll(write_fd, "hi");
    _ = try expectSyscall(sys.fstat(read_fd, &read_stat), "testStat: fstat pipe after write", @src());
    try expectOffset(read_stat.size, 2);

    _ = try expectSyscall(sys.close(read_fd), "testStat: close pipe reader", @src());
    _ = try expectSyscall(sys.close(write_fd), "testStat: close pipe writer", @src());

    _ = try expectSyscall(sys.close(fd), "testStat: close stat file", @src());
    _ = try expectSyscall(sys.unlink(stat_link), "testStat: unlink hard link", @src());
    _ = try expectSyscall(sys.unlink(stat_file), "testStat: unlink stat file", @src());
    _ = try expectSyscall(sys.rmdir(stat_dir), "testStat: rmdir stat dir", @src());

    try syscallShouldFail(sys.stat(nonexistent_file, &path_stat), "testStat: stat missing path", @src());
    try syscallShouldFail(sys.fstat(99, &path_stat), "testStat: fstat bad fd", @src());
}

fn testGetDents() !void {
    sys.unlink(dirent_file) catch {};
    sys.rmdir(dirent_subdir) catch {};
    sys.rmdir(dirent_dir) catch {};
    sys.mkdir(dirent_dir) catch {};
    sys.mkdir(dirent_subdir) catch {};

    const fd = try expectSyscall(sys.open(dirent_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testGetDents: create directory file", @src());
    _ = try expectSyscall(sys.write(fd, "dirent payload"), "testGetDents: write directory file", @src());
    _ = try expectSyscall(sys.close(fd), "testGetDents: close directory file", @src());

    const dir_fd = try expectSyscall(sys.open(dirent_dir, .{}), "testGetDents: open directory", @src());
    errdefer sys.close(dir_fd) catch {};

    var batch: [2]sys.DirEntry = undefined;
    const first_batch = try expectSyscall(sys.getdents(dir_fd, &batch), "testGetDents: first batch", @src());
    try expectOffset(first_batch, 2);

    var saw_file = false;
    var saw_dir = false;
    for (batch[0..first_batch]) |*entry| {
        if (std.mem.eql(u8, entry.name[0..entry.name_len], "entry.txt")) {
            saw_file = true;
            try expectKind(entry.kind, .Regular);
            try expectOffset(entry.size, 14);
        } else if (std.mem.eql(u8, entry.name[0..entry.name_len], "nested")) {
            saw_dir = true;
            try expectKind(entry.kind, .Directory);
        } else {
            return error.UnexpectedDirectoryEntry;
        }
    }
    if (!saw_file or !saw_dir) return error.UnexpectedDirectoryEntry;

    const second_batch = try expectSyscall(sys.getdents(dir_fd, &batch), "testGetDents: second batch eof", @src());
    try expectOffset(second_batch, 0);

    try expectOffset(try expectSyscall(sys.lseek(dir_fd, 0, .Set), "testGetDents: rewind directory", @src()), 0);
    var single: sys.DirEntry = undefined;
    const has_entry = try checkSyscall(sys.readdir(dir_fd, &single), "testGetDents: readdir entry", @src());
    if (!has_entry) return error.ExpectedDirectoryEntry;
    if (single.kind == .Regular) {
        try expectDirEntryName(&single, "entry.txt");
    } else if (single.kind == .Directory) {
        try expectDirEntryName(&single, "nested");
    } else {
        return error.UnexpectedKind;
    }

    _ = try expectSyscall(sys.close(dir_fd), "testGetDents: close directory", @src());

    const file_fd = try expectSyscall(sys.open(dirent_file, .{}), "testGetDents: reopen regular file", @src());
    try syscallShouldFail(sys.getdents(file_fd, &batch), "testGetDents: getdents on regular file", @src());
    _ = try expectSyscall(sys.close(file_fd), "testGetDents: close regular file", @src());

    _ = try expectSyscall(sys.unlink(dirent_file), "testGetDents: unlink file", @src());
    _ = try expectSyscall(sys.rmdir(dirent_subdir), "testGetDents: rmdir subdir", @src());
    _ = try expectSyscall(sys.rmdir(dirent_dir), "testGetDents: rmdir dir", @src());
}

fn testPipeSpawn() !void {
    // Create two pipes: one for feeding cat's stdin, one for capturing cat's stdout.
    const stdin_read, const stdin_write = try checkSyscall(sys.pipe(), "testPipeSpawn: create stdin pipe", @src());
    const stdout_read, const stdout_write = try checkSyscall(sys.pipe(), "testPipeSpawn: create stdout pipe", @src());

    // Remap child's stdin (fd 0) to the read end of the stdin pipe,
    // and child's stdout (fd 1) to the write end of the stdout pipe.
    const fd_remaps = [_]sys.FdRemap{
        .{ .dst = sys.STDIN, .src = stdin_read },
        .{ .dst = sys.STDOUT, .src = stdout_write },
    };
    const pid = try checkSyscall(sys.spawnOpts("/bin/cat", &.{}, &fd_remaps), "testPipeSpawn: spawn cat", @src());

    // Parent no longer needs the child-side ends of the pipes.
    _ = try expectSyscall(sys.close(stdin_read), "testPipeSpawn: close stdin read in parent", @src());
    _ = try expectSyscall(sys.close(stdout_write), "testPipeSpawn: close stdout write in parent", @src());

    // Feed known input to cat and signal EOF.
    const input = "pipe spawn ok\n";
    try writeAll(stdin_write, input);
    // Closing cat's stdin should cause it to detect EOF and exit.
    _ = try expectSyscall(sys.close(stdin_write), "testPipeSpawn: close stdin write in parent", @src());

    // Read cat's output and verify it matches the input.
    var buf: [64]u8 = undefined;
    try readExact(stdout_read, buf[0..input.len]);
    try expectEof(stdout_read);
    try expectBytes(buf[0..input.len], input);
    _ = try expectSyscall(sys.close(stdout_read), "testPipeSpawn: close stdout read in parent", @src());

    _ = try expectSyscall(sys.waitpid(pid), "testPipeSpawn: wait for cat", @src());
}

fn testBrokenPipe() !void {
    const read_fd, const write_fd = try checkSyscall(sys.pipe(), "testBrokenPipe: create pipe", @src());
    _ = try expectSyscall(sys.close(read_fd), "testBrokenPipe: close read end", @src());
    try syscallShouldFail(sys.write(write_fd, "x"), "testBrokenPipe: write with no readers", @src());
    _ = try expectSyscall(sys.close(write_fd), "testBrokenPipe: close write end", @src());
}

/// Exercises filesystem syscalls with alternating writes, seeks, and unlinks.
pub fn main(argv: []const []const u8) !void {
    _ = argv;
    var buf: [96]u8 = undefined;
    _ = try sys.write(sys.STDOUT, try std.fmt.bufPrint(&buf, "pid {d}: stress-testing filesystem syscalls...\n", .{sys.getpid()}));

    sys.mkdir(tmpdir) catch {}; // on error, assume tmp exists

    const create_flags: sys.FileOpenFlags = .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    };
    const fd_a = try expectSyscall(sys.open(stress_file_a, create_flags), "main: open stress_file_a", @src());
    const fd_b = try expectSyscall(sys.open(stress_file_b, create_flags), "main: open stress_file_b", @src());

    var opened_missing_file = true;
    const fd_c = sys.open(nonexistent_file, .{}) catch blk: {
        opened_missing_file = false;
        break :blk 0;
    };
    if (opened_missing_file) {
        _ = sys.write(sys.STDOUT, "unexpectedly opened nonexistent file\n") catch {};
        sys.close(fd_c) catch {};
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

    _ = try syscallShouldFail(sys.close(fd_a), "main: double close file a", @src());
    _ = try syscallShouldFail(sys.close(fd_b), "main: double close file b", @src());

    try verifyFileContents(stress_file_a, &expected_a);
    try verifyFileContents(stress_file_b, &expected_b);
    try testSeek();
    try testSparseSeek();
    try testTruncate();
    try testUnlink();
    try testLink();
    try testRename();
    try testStat();
    try testGetDents();
    try testRmdir();
    try testPipe();
    try testBrokenPipe();
    try testPipeSpawn();

    _ = try expectSyscall(sys.close(sys.STDIN), "main: close stdin", @src());
    _ = try expectSyscall(sys.close(sys.STDERR), "main: close stderr", @src());
    _ = try sys.write(sys.STDOUT, "filesystem tests OK\n");
    _ = try expectSyscall(sys.close(sys.STDOUT), "main: close stdout", @src());
    sys.yield();
}

comptime {
    _ = sys._start;
}
