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
const symlink_target_file = tmpdir ++ "/syl_tgt.txt";
const symlink_abs_file = tmpdir ++ "/syl_abs.txt";
const symlink_rel_file = tmpdir ++ "/syl_rel.txt";
const symlink_loop_file = tmpdir ++ "/syl_loop.txt";
const rename_src = tmpdir ++ "/rename_src.txt";
const rename_dst = tmpdir ++ "/rename_dst.txt";
const stat_file = tmpdir ++ "/stat.txt";
const stat_link = tmpdir ++ "/stat_link.txt";
const stat_dir = tmpdir ++ "/stat_dir";
const dirent_dir = tmpdir ++ "/dirents";
const dirent_file = dirent_dir ++ "/entry.txt";
const dirent_subdir = dirent_dir ++ "/nested";
const cwd_dir = tmpdir ++ "/cwd";
const cwd_nested_dir = cwd_dir ++ "/nested";
const cwd_child_dir = cwd_nested_dir ++ "/child";
const cwd_file = cwd_dir ++ "/note.txt";
const cwd_renamed_file = cwd_dir ++ "/renamed.txt";
const cwd_link_file = cwd_dir ++ "/hard.txt";
const cwd_symlink_file = cwd_nested_dir ++ "/rel_link.txt";
const nonexistent_file = "/missing.txt";
const sector_size = 512;
const pipe_capacity = 4096;
const chunk_size = 640;
const chunk_count = 6;
const total_bytes = chunk_size * chunk_count;
const seek_expected = "01234AB789XY\x00\x00Z";
const truncate_expected = "ABCD\x00\x00\x00\x00\x00\x00";
const symlink_relative_target = "syl_tgt.txt";
const symlink_loop_target = "syl_loop.txt";
const symlink_payload = "symlink payload";
const stat_payload = "stat payload";
const cwd_payload = "cwd payload";

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

fn expectKind(actual: sys.InodeKind, expected: sys.InodeKind) !void {
    if (actual != expected) return error.UnexpectedKind;
}

fn expectFlags(actual: u32, expected_mask: u32) !void {
    if ((actual & expected_mask) != expected_mask) return error.MissingFlags;
}

fn expectDirEntryName(actual: *const sys.DirEntry, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual.name[0..actual.name_len], expected)) return error.DataMismatch;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.DataMismatch;
}

fn expectCwd(expected: []const u8) !void {
    var cwd_buf: [sys.PATH_MAX]u8 = undefined;
    const cwd = try expectSyscall(sys.getCwd(&cwd_buf), "expectCwd: getcwd", @src());
    try expectBytes(cwd, expected);
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
    var seed_name_buf: [15]u8 = undefined;
    for (0..10) |seed_index| {
        const seed_name = try std.fmt.bufPrint(&seed_name_buf, "/tmp/seed{d:0>2}.txt", .{seed_index});
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
    errdefer sys.close(fd) catch {};

    try writeAll(fd, "temporary contents");
    var original_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(fd, &original_stat), "testUnlink: fstat before unlink", @src());
    try expectOffset(original_stat.nlink, 1);

    _ = try expectSyscall(sys.unlink(unlink_file), "testUnlink: unlink open file", @src());
    _ = try syscallShouldFail(sys.open(unlink_file, .{}), "testUnlink: path removed after unlink", @src());

    var unlinked_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(fd, &unlinked_stat), "testUnlink: fstat after unlink", @src());
    if (unlinked_stat.inode != original_stat.inode) return error.InodeMismatch;
    try expectOffset(unlinked_stat.nlink, 0);

    try writeAll(fd, "!");
    try expectOffset(try expectSyscall(sys.lseek(fd, 0, .Set), "testUnlink: rewind unlinked fd", @src()), 0);

    var old_contents: ["temporary contents!".len]u8 = undefined;
    try readExact(fd, &old_contents);
    try expectEof(fd);
    try expectBytes(&old_contents, "temporary contents!");

    const replacement_fd = try expectSyscall(sys.open(unlink_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testUnlink: recreate path after unlink", @src());
    errdefer sys.close(replacement_fd) catch {};
    try writeAll(replacement_fd, "replacement");

    var replacement_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(replacement_fd, &replacement_stat), "testUnlink: fstat replacement file", @src());
    if (replacement_stat.inode == original_stat.inode) return error.InodeMismatch;
    try expectOffset(replacement_stat.nlink, 1);

    try expectOffset(try expectSyscall(sys.lseek(replacement_fd, 0, .Set), "testUnlink: rewind replacement fd", @src()), 0);
    var replacement_contents: ["replacement".len]u8 = undefined;
    try readExact(replacement_fd, &replacement_contents);
    try expectEof(replacement_fd);
    try expectBytes(&replacement_contents, "replacement");

    _ = try expectSyscall(sys.close(fd), "testUnlink: close unlinked file", @src());
    _ = try expectSyscall(sys.close(replacement_fd), "testUnlink: close replacement file", @src());
    _ = try expectSyscall(sys.unlink(unlink_file), "testUnlink: unlink replacement path", @src());
    _ = try syscallShouldFail(sys.open(unlink_file, .{}), "testUnlink: open missing file", @src());
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

fn testSymlink() !void {
    sys.unlink(symlink_loop_file) catch {};
    sys.unlink(symlink_rel_file) catch {};
    sys.unlink(symlink_abs_file) catch {};
    sys.unlink(symlink_target_file) catch {};

    const fd = try expectSyscall(sys.open(symlink_target_file, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testSymlink: create target file", @src());
    errdefer sys.close(fd) catch {};
    try writeAll(fd, symlink_payload);

    var target_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(fd, &target_stat), "testSymlink: fstat target file", @src());
    try expectKind(target_stat.kind, .Regular);
    _ = try expectSyscall(sys.close(fd), "testSymlink: close target file", @src());

    _ = try expectSyscall(sys.symlink(symlink_target_file, symlink_abs_file), "testSymlink: create absolute symlink", @src());
    _ = try expectSyscall(sys.symlink(symlink_relative_target, symlink_rel_file), "testSymlink: create relative symlink", @src());
    _ = try syscallShouldFail(sys.symlink(symlink_target_file, symlink_abs_file), "testSymlink: duplicate absolute symlink path", @src());

    var abs_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(symlink_abs_file, &abs_stat), "testSymlink: stat absolute symlink", @src());
    try expectKind(abs_stat.kind, .Symlink);
    try expectOffset(abs_stat.size, @intCast(symlink_target_file.len));
    try expectOffset(abs_stat.nlink, 1);
    if (abs_stat.inode == target_stat.inode) return error.InodeMismatch;

    var rel_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(symlink_rel_file, &rel_stat), "testSymlink: stat relative symlink", @src());
    try expectKind(rel_stat.kind, .Symlink);
    try expectOffset(rel_stat.size, @intCast(symlink_relative_target.len));
    try expectOffset(rel_stat.nlink, 1);
    if (rel_stat.inode == target_stat.inode) return error.InodeMismatch;

    const via_abs_fd = try expectSyscall(sys.open(symlink_abs_file, .{}), "testSymlink: open absolute symlink", @src());
    errdefer sys.close(via_abs_fd) catch {};
    var via_abs_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(via_abs_fd, &via_abs_stat), "testSymlink: fstat absolute symlink fd", @src());
    try expectKind(via_abs_stat.kind, .Regular);
    if (via_abs_stat.inode != target_stat.inode) return error.InodeMismatch;
    var via_abs: [symlink_payload.len]u8 = undefined;
    try readExact(via_abs_fd, &via_abs);
    try expectEof(via_abs_fd);
    try expectBytes(&via_abs, symlink_payload);
    _ = try expectSyscall(sys.close(via_abs_fd), "testSymlink: close absolute symlink fd", @src());

    const via_rel_fd = try expectSyscall(sys.open(symlink_rel_file, .{}), "testSymlink: open relative symlink", @src());
    errdefer sys.close(via_rel_fd) catch {};
    var via_rel: [symlink_payload.len]u8 = undefined;
    try readExact(via_rel_fd, &via_rel);
    try expectEof(via_rel_fd);
    try expectBytes(&via_rel, symlink_payload);
    _ = try expectSyscall(sys.close(via_rel_fd), "testSymlink: close relative symlink fd", @src());

    _ = try expectSyscall(sys.unlink(symlink_target_file), "testSymlink: unlink target file", @src());

    _ = try expectSyscall(sys.stat(symlink_abs_file, &abs_stat), "testSymlink: stat dangling absolute symlink", @src());
    try expectKind(abs_stat.kind, .Symlink);
    _ = try expectSyscall(sys.stat(symlink_rel_file, &rel_stat), "testSymlink: stat dangling relative symlink", @src());
    try expectKind(rel_stat.kind, .Symlink);
    _ = try syscallShouldFail(sys.open(symlink_abs_file, .{}), "testSymlink: open dangling absolute symlink", @src());
    _ = try syscallShouldFail(sys.open(symlink_rel_file, .{}), "testSymlink: open dangling relative symlink", @src());

    _ = try expectSyscall(sys.symlink(symlink_loop_target, symlink_loop_file), "testSymlink: create self-loop symlink", @src());
    var loop_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(symlink_loop_file, &loop_stat), "testSymlink: stat self-loop symlink", @src());
    try expectKind(loop_stat.kind, .Symlink);
    try expectOffset(loop_stat.size, @intCast(symlink_loop_target.len));
    _ = try syscallShouldFail(sys.open(symlink_loop_file, .{}), "testSymlink: open self-loop symlink", @src());

    _ = try expectSyscall(sys.unlink(symlink_abs_file), "testSymlink: unlink absolute symlink", @src());
    _ = try expectSyscall(sys.unlink(symlink_rel_file), "testSymlink: unlink relative symlink", @src());
    _ = try expectSyscall(sys.unlink(symlink_loop_file), "testSymlink: unlink self-loop symlink", @src());
    _ = try syscallShouldFail(sys.stat(symlink_abs_file, &abs_stat), "testSymlink: stat removed absolute symlink", @src());
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

    // 7. Rename over an open destination replaces the path, while the old descriptor keeps the
    //    replaced inode alive until close.
    const src4_fd = try expectSyscall(sys.open(rename_src, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create src for open-dst test", @src());
    try writeAll(src4_fd, "data");
    var src4_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(src4_fd, &src4_stat), "testRename: fstat src for open-dst test", @src());
    _ = try expectSyscall(sys.close(src4_fd), "testRename: close src for open-dst test", @src());

    const open_dst_fd = try expectSyscall(sys.open(rename_dst, .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    }), "testRename: create open dst", @src());
    errdefer sys.close(open_dst_fd) catch {};
    try writeAll(open_dst_fd, "open");
    var old_dst_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(open_dst_fd, &old_dst_stat), "testRename: fstat open dst before rename", @src());

    _ = try expectSyscall(sys.rename(rename_src, rename_dst), "testRename: rename onto open dst", @src());
    _ = try syscallShouldFail(sys.open(rename_src, .{}), "testRename: src gone after open-dst rename", @src());

    var replaced_dst_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(open_dst_fd, &replaced_dst_stat), "testRename: fstat replaced dst", @src());
    if (replaced_dst_stat.inode != old_dst_stat.inode) return error.InodeMismatch;
    try expectOffset(replaced_dst_stat.nlink, 0);
    try expectOffset(try expectSyscall(sys.lseek(open_dst_fd, 0, .Set), "testRename: rewind replaced dst", @src()), 0);
    var old_dst_contents: ["open".len]u8 = undefined;
    try readExact(open_dst_fd, &old_dst_contents);
    try expectEof(open_dst_fd);
    try expectBytes(&old_dst_contents, "open");

    const renamed_fd = try expectSyscall(sys.open(rename_dst, .{}), "testRename: open renamed dst", @src());
    errdefer sys.close(renamed_fd) catch {};
    var renamed_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.fstat(renamed_fd, &renamed_stat), "testRename: fstat renamed dst", @src());
    if (renamed_stat.inode != src4_stat.inode) return error.InodeMismatch;
    if (renamed_stat.inode == old_dst_stat.inode) return error.InodeMismatch;
    var renamed_contents: ["data".len]u8 = undefined;
    try readExact(renamed_fd, &renamed_contents);
    try expectEof(renamed_fd);
    try expectBytes(&renamed_contents, "data");
    _ = try expectSyscall(sys.close(renamed_fd), "testRename: close renamed dst", @src());

    _ = try expectSyscall(sys.close(open_dst_fd), "testRename: close open dst", @src());
    _ = try expectSyscall(sys.unlink(rename_dst), "testRename: cleanup renamed dst", @src());
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

const SpawnedCatPipes = struct {
    pid: u32,
    stdin_write: u32,
    stdout_read: u32,
};

fn spawnCatPipePair() !SpawnedCatPipes {
    const stdin_read, const stdin_write = try checkSyscall(sys.pipe(), "spawnCatPipePair: create stdin pipe", @src());
    errdefer sys.close(stdin_read) catch {};
    errdefer sys.close(stdin_write) catch {};

    const stdout_read, const stdout_write = try checkSyscall(sys.pipe(), "spawnCatPipePair: create stdout pipe", @src());
    errdefer sys.close(stdout_read) catch {};
    errdefer sys.close(stdout_write) catch {};

    const fd_remaps = [_]sys.FdRemap{
        .{ .dst = sys.STDIN, .src = stdin_read },
        .{ .dst = sys.STDOUT, .src = stdout_write },
    };
    const pid = try checkSyscall(sys.spawnOpts("/bin/cat", &.{}, &fd_remaps), "spawnCatPipePair: spawn cat", @src());

    _ = try expectSyscall(sys.close(stdin_read), "spawnCatPipePair: close stdin read in parent", @src());
    _ = try expectSyscall(sys.close(stdout_write), "spawnCatPipePair: close stdout write in parent", @src());

    return .{
        .pid = pid,
        .stdin_write = stdin_write,
        .stdout_read = stdout_read,
    };
}

fn captureCommandStdout(path: []const u8, args: []const []const u8, buf: []u8) ![]const u8 {
    const stdout_read, const stdout_write = try checkSyscall(sys.pipe(), "captureCommandStdout: create stdout pipe", @src());
    errdefer sys.close(stdout_read) catch {};
    errdefer sys.close(stdout_write) catch {};

    const fd_remaps = [_]sys.FdRemap{
        .{ .dst = sys.STDOUT, .src = stdout_write },
    };
    const pid = try checkSyscall(sys.spawnOpts(path, args, &fd_remaps), "captureCommandStdout: spawn command", @src());
    _ = try expectSyscall(sys.close(stdout_write), "captureCommandStdout: close stdout write in parent", @src());

    var used: usize = 0;
    while (used < buf.len) {
        const bytes_read = try expectSyscall(sys.read(stdout_read, buf[used..]), "captureCommandStdout: read stdout", @src());
        if (bytes_read == 0) break;
        used += bytes_read;
    }
    if (used == buf.len) return error.ShortRead;

    _ = try expectSyscall(sys.close(stdout_read), "captureCommandStdout: close stdout read in parent", @src());
    try expectOffset(try expectSyscall(sys.waitpid(pid), "captureCommandStdout: wait for child", @src()), 0);
    return buf[0..used];
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
    const pipes = try spawnCatPipePair();
    errdefer sys.close(pipes.stdin_write) catch {};
    errdefer sys.close(pipes.stdout_read) catch {};

    // Feed known input to cat and signal EOF.
    const input = "pipe spawn ok\n";
    try writeAll(pipes.stdin_write, input);
    // Closing cat's stdin should cause it to detect EOF and exit.
    _ = try expectSyscall(sys.close(pipes.stdin_write), "testPipeSpawn: close stdin write in parent", @src());

    // Read cat's output and verify it matches the input.
    var buf: [64]u8 = undefined;
    try readExact(pipes.stdout_read, buf[0..input.len]);
    try expectEof(pipes.stdout_read);
    try expectBytes(buf[0..input.len], input);
    _ = try expectSyscall(sys.close(pipes.stdout_read), "testPipeSpawn: close stdout read in parent", @src());

    _ = try expectSyscall(sys.waitpid(pipes.pid), "testPipeSpawn: wait for cat", @src());
}

fn testPipeSpawnWriterCloseWakeup() !void {
    const pipes = try spawnCatPipePair();
    errdefer sys.close(pipes.stdin_write) catch {};
    errdefer sys.close(pipes.stdout_read) catch {};

    _ = try expectSyscall(sys.close(pipes.stdin_write), "testPipeSpawnWriterCloseWakeup: close stdin write in parent", @src());
    try expectEof(pipes.stdout_read);
    _ = try expectSyscall(sys.close(pipes.stdout_read), "testPipeSpawnWriterCloseWakeup: close stdout read in parent", @src());
    _ = try expectSyscall(sys.waitpid(pipes.pid), "testPipeSpawnWriterCloseWakeup: wait for cat", @src());
}

fn testBrokenPipe() !void {
    const read_fd, const write_fd = try checkSyscall(sys.pipe(), "testBrokenPipe: create pipe", @src());
    _ = try expectSyscall(sys.close(read_fd), "testBrokenPipe: close read end", @src());
    try syscallShouldFail(sys.write(write_fd, "x"), "testBrokenPipe: write with no readers", @src());
    _ = try expectSyscall(sys.close(write_fd), "testBrokenPipe: close write end", @src());
}

fn testCwd() !void {
    var original_cwd_buf: [sys.PATH_MAX]u8 = undefined;
    const original_cwd = try expectSyscall(sys.getCwd(&original_cwd_buf), "testCwd: get original cwd", @src());

    var restore_cwd_buf: [sys.PATH_MAX]u8 = undefined;
    @memcpy(restore_cwd_buf[0..original_cwd.len], original_cwd);
    const restore_cwd = restore_cwd_buf[0..original_cwd.len];
    defer sys.chdir(restore_cwd) catch {};

    sys.unlink(cwd_symlink_file) catch {};
    sys.unlink(cwd_link_file) catch {};
    sys.unlink(cwd_renamed_file) catch {};
    sys.unlink(cwd_file) catch {};
    sys.rmdir(cwd_child_dir) catch {};
    sys.rmdir(cwd_nested_dir) catch {};
    sys.rmdir(cwd_dir) catch {};

    _ = try expectSyscall(sys.mkdir(cwd_dir), "testCwd: mkdir cwd dir", @src());
    _ = try expectSyscall(sys.chdir(cwd_dir), "testCwd: chdir cwd dir", @src());
    try expectCwd(cwd_dir);

    var short_buf: [4]u8 = undefined;
    try syscallShouldFail(sys.getCwd(&short_buf), "testCwd: getcwd short buffer", @src());

    _ = try expectSyscall(sys.mkdir("nested"), "testCwd: mkdir nested", @src());
    _ = try expectSyscall(sys.mkdir("nested/child"), "testCwd: mkdir child", @src());

    var dot_stat: sys.Stat = undefined;
    var dotdot_stat: sys.Stat = undefined;
    _ = try expectSyscall(sys.stat(".", &dot_stat), "testCwd: stat dot", @src());
    _ = try expectSyscall(sys.stat("nested/..", &dotdot_stat), "testCwd: stat nested dotdot", @src());
    if (dot_stat.inode != dotdot_stat.inode) return error.InodeMismatch;

    const create_flags: sys.FileOpenFlags = .{
        .open_mode = .ReadWrite,
        .create = true,
        .truncate = true,
    };
    const fd = try expectSyscall(sys.open("note.txt", create_flags), "testCwd: create note", @src());
    try writeAll(fd, cwd_payload);
    _ = try expectSyscall(sys.close(fd), "testCwd: close note", @src());

    _ = try expectSyscall(sys.rename("note.txt", "./renamed.txt"), "testCwd: rename note", @src());
    _ = try expectSyscall(sys.link("renamed.txt", "hard.txt"), "testCwd: link renamed", @src());
    _ = try expectSyscall(sys.symlink("../renamed.txt", "nested/rel_link.txt"), "testCwd: symlink renamed", @src());

    const verify_fd = try expectSyscall(sys.open("nested/../renamed.txt", .{}), "testCwd: open renamed via dotdot", @src());
    defer sys.close(verify_fd) catch {};
    var verify_buf: [cwd_payload.len]u8 = undefined;
    try readExact(verify_fd, &verify_buf);
    try expectEof(verify_fd);
    try expectBytes(&verify_buf, cwd_payload);

    const symlink_fd = try expectSyscall(sys.open("nested/rel_link.txt", .{}), "testCwd: open symlink", @src());
    defer sys.close(symlink_fd) catch {};
    var symlink_buf: [cwd_payload.len]u8 = undefined;
    try readExact(symlink_fd, &symlink_buf);
    try expectEof(symlink_fd);
    try expectBytes(&symlink_buf, cwd_payload);

    var ls_buf: [256]u8 = undefined;
    const ls_output = try captureCommandStdout("/bin/ls", &.{}, &ls_buf);
    try expectContains(ls_output, "renamed.txt");
    try expectContains(ls_output, "hard.txt");
    try expectContains(ls_output, "nested");

    // avoid stat output on the terminal by redirecting to /dev/null
    const dev_null = try sys.open("/dev/null", .{ .open_mode = .WriteOnly });
    defer sys.close(dev_null) catch {};
    const to_null = [_]sys.FdRemap{.{ .dst = sys.STDOUT, .src = dev_null }};

    const inherited_cwd_pid = try expectSyscall(sys.spawnOpts("/bin/stat", &.{"renamed.txt"}, &to_null), "testCwd: spawn inherited cwd stat", @src());
    try expectOffset(try expectSyscall(sys.waitpid(inherited_cwd_pid), "testCwd: wait inherited cwd stat", @src()), 0);

    _ = try expectSyscall(sys.chdir("/bin"), "testCwd: chdir bin", @src());
    const relative_exec_pid = try expectSyscall(sys.spawnOpts("./stat", &.{cwd_renamed_file}, &to_null), "testCwd: spawn relative executable", @src());
    try expectOffset(try expectSyscall(sys.waitpid(relative_exec_pid), "testCwd: wait relative executable", @src()), 0);

    _ = try expectSyscall(sys.chdir(cwd_dir), "testCwd: chdir cwd dir again", @src());
    _ = try expectSyscall(sys.chdir("nested/child"), "testCwd: chdir child", @src());
    try expectCwd(cwd_child_dir);

    const child_fd = try expectSyscall(sys.open("../../renamed.txt", .{}), "testCwd: open from child", @src());
    defer sys.close(child_fd) catch {};
    var child_buf: [cwd_payload.len]u8 = undefined;
    try readExact(child_fd, &child_buf);
    try expectEof(child_fd);
    try expectBytes(&child_buf, cwd_payload);

    _ = try expectSyscall(sys.chdir("./.."), "testCwd: chdir parent", @src());
    try expectCwd(cwd_nested_dir);
    _ = try expectSyscall(sys.chdir(".."), "testCwd: chdir cwd dir from nested", @src());
    try expectCwd(cwd_dir);

    _ = try expectSyscall(sys.chdir("/"), "testCwd: chdir root", @src());
    try expectCwd("/");

    const root_fd = try expectSyscall(sys.open("tmp/cwd/renamed.txt", .{}), "testCwd: open from root relative", @src());
    defer sys.close(root_fd) catch {};
    var root_buf: [cwd_payload.len]u8 = undefined;
    try readExact(root_fd, &root_buf);
    try expectEof(root_fd);
    try expectBytes(&root_buf, cwd_payload);

    _ = try expectSyscall(sys.unlink(cwd_symlink_file), "testCwd: unlink symlink", @src());
    _ = try expectSyscall(sys.unlink(cwd_link_file), "testCwd: unlink hard link", @src());
    _ = try expectSyscall(sys.unlink(cwd_renamed_file), "testCwd: unlink renamed", @src());
    _ = try expectSyscall(sys.rmdir(cwd_child_dir), "testCwd: rmdir child", @src());
    _ = try expectSyscall(sys.rmdir(cwd_nested_dir), "testCwd: rmdir nested", @src());
    _ = try expectSyscall(sys.rmdir(cwd_dir), "testCwd: rmdir cwd dir", @src());
}

fn testPoll() !void {
    {
        var fds = [_]sys.PollFd{
            .{ .fd = 0, .events = sys.POLLIN, .revents = 0 },
        };
        try syscallShouldFail(sys.poll(&fds, 1), "testPoll: non-zero timeout", @src());
    }

    {
        const poll_test_file = tmpdir ++ "/poll_test.txt";
        const fd = try expectSyscall(sys.open(poll_test_file, .{
            .open_mode = .ReadWrite,
            .create = true,
            .truncate = true,
        }), "testPoll: open file", @src());
        defer sys.close(fd) catch {};
        _ = try expectSyscall(sys.write(fd, "data"), "testPoll: write file", @src());
        _ = try expectSyscall(sys.lseek(fd, 0, .Set), "testPoll: rewind file", @src());

        var fds = [_]sys.PollFd{
            .{ .fd = @as(i32, @intCast(fd)), .events = sys.POLLIN | sys.POLLOUT, .revents = 0 },
        };
        const ready = try expectSyscall(sys.poll(&fds, 0), "testPoll: poll file", @src());
        try expectOffset(ready, 1);
        if (fds[0].revents & sys.POLLIN == 0) return error.PollMissingPollIn;
        if (fds[0].revents & sys.POLLOUT == 0) return error.PollMissingPollOut;
        _ = try expectSyscall(sys.unlink(poll_test_file), "testPoll: unlink file", @src());
    }

    {
        var fds = [_]sys.PollFd{
            .{ .fd = 1, .events = sys.POLLOUT, .revents = 0 },
        };
        const ready = try expectSyscall(sys.poll(&fds, 0), "testPoll: poll stdout", @src());
        try expectOffset(ready, 1);
        if (fds[0].revents & sys.POLLOUT == 0) return error.PollMissingPollOut;
    }

    {
        var fds = [_]sys.PollFd{
            .{ .fd = 99, .events = sys.POLLIN, .revents = 0 },
        };
        try syscallShouldFail(sys.poll(&fds, 0), "testPoll: poll bad fd", @src());
    }

    {
        var fds = [_]sys.PollFd{
            .{ .fd = -1, .events = sys.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = sys.POLLOUT, .revents = 0 },
        };
        const ready = try expectSyscall(sys.poll(&fds, 0), "testPoll: poll skip -1", @src());
        try expectOffset(ready, 0);
        if (fds[0].revents != 0) return error.PollUnexpectedRevents;
        if (fds[1].revents != 0) return error.PollUnexpectedRevents;
    }

    {
        const read_fd, const write_fd = try checkSyscall(sys.pipe(), "testPoll: create pipe", @src());

        var fds = [_]sys.PollFd{
            .{ .fd = @as(i32, @intCast(read_fd)), .events = sys.POLLIN, .revents = 0 },
            .{ .fd = @as(i32, @intCast(write_fd)), .events = sys.POLLOUT, .revents = 0 },
        };
        _ = try expectSyscall(sys.poll(&fds, 0), "testPoll: poll empty pipe", @src());
        if (fds[0].revents & sys.POLLIN != 0) return error.PollUnexpectedPollIn;

        _ = try expectSyscall(sys.write(write_fd, "hello"), "testPoll: write pipe", @src());
        fds[0].revents = 0;
        fds[1].revents = 0;
        _ = try expectSyscall(sys.poll(&fds, 0), "testPoll: poll pipe after write", @src());
        if (fds[0].revents & sys.POLLIN == 0) return error.PollMissingPollIn;

        _ = try expectSyscall(sys.close(read_fd), "testPoll: close pipe read", @src());
        _ = try expectSyscall(sys.close(write_fd), "testPoll: close pipe write", @src());
    }

    {
        const read_fd, const write_fd = try checkSyscall(sys.pipe(), "testPoll: create events pipe", @src());
        _ = try expectSyscall(sys.write(write_fd, "data"), "testPoll: write events pipe", @src());

        var fds = [_]sys.PollFd{
            .{ .fd = @as(i32, @intCast(read_fd)), .events = 0, .revents = 0 },
        };
        const ready = try expectSyscall(sys.poll(&fds, 0), "testPoll: poll with 0 events", @src());
        try expectOffset(ready, 0);
        if (fds[0].revents != 0) return error.PollUnexpectedRevents;

        _ = try expectSyscall(sys.close(read_fd), "testPoll: close events pipe read", @src());
        _ = try expectSyscall(sys.close(write_fd), "testPoll: close events pipe write", @src());
    }
}

/// Exercises filesystem syscalls with alternating writes, seeks, and unlinks.
pub fn main(argv: []const []const u8) !void {
    _ = argv;
    _ = try sys.write(sys.STDOUT, "testing filesystem syscalls");

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
    try testSymlink();
    try testRename();
    try testStat();
    try testGetDents();
    try testRmdir();
    try testPipe();
    try testBrokenPipe();
    try testCwd();
    try testPipeSpawn();
    try testPipeSpawnWriterCloseWakeup();
    try testPoll();

    _ = try expectSyscall(sys.close(sys.STDIN), "main: close stdin", @src());
    _ = try expectSyscall(sys.close(sys.STDERR), "main: close stderr", @src());
    _ = try sys.write(sys.STDOUT, "OK\n");
    _ = try expectSyscall(sys.close(sys.STDOUT), "main: close stdout", @src());
    sys.yield();
}

comptime {
    _ = sys._start;
}
