const abi = @import("abi");
const fs = @import("kernel/fs/zodfs.zig");
const block_device = @import("kernel/block_device.zig");
const file_block_device = @import("file_block_device.zig");
const std = @import("std");

const CompileError = error{
    InvalidArgs,
    InvalidPathName,
    InvalidLinkEntry,
    InvalidSpecialEntry,
};

const ImportCounts = struct {
    files: usize = 0,
    directories: usize = 0,
    links: usize = 0,
    specials: usize = 0,
};

fn parseDeviceMajor(raw_major: u8) ?abi.DeviceMajor {
    return switch (raw_major) {
        @intFromEnum(abi.DeviceMajor.Unnamed) => .Unnamed,
        @intFromEnum(abi.DeviceMajor.Ide) => .Ide,
        @intFromEnum(abi.DeviceMajor.Tty) => .Tty,
        @intFromEnum(abi.DeviceMajor.FrameBuffer) => .FrameBuffer,
        else => null,
    };
}

fn importDirectory(
    init: std.process.Init,
    stdout: anytype,
    disk_fs: *fs.FileSystem,
    host_dir_path: []const u8,
    fs_dir_inode: *fs.DiskInode,
    relative_path: []const u8,
    counts: *ImportCounts,
) !void {
    const input_dir = try std.Io.Dir.cwd().openDir(init.io, host_dir_path, .{ .iterate = true });
    defer input_dir.close(init.io);

    var iter = input_dir.iterateAssumeFirstIteration();
    while (try iter.next(init.io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!fs.validateName(entry.name)) {
                    try stdout.print("Error: invalid path component: {s}\n", .{entry.name});
                    return CompileError.InvalidPathName;
                }

                const child_host_path = try std.fs.path.join(init.gpa, &.{ host_dir_path, entry.name });
                defer init.gpa.free(child_host_path);
                const child_relative_path = try std.fs.path.join(init.gpa, &.{ relative_path, entry.name });
                defer init.gpa.free(child_relative_path);

                try stdout.print("  Creating directory: {s}\n", .{child_relative_path});
                const child_inode = try disk_fs.createDirectoryAt(fs_dir_inode, entry.name);
                defer disk_fs.drop(child_inode);

                counts.directories += 1;
                try importDirectory(init, stdout, disk_fs, child_host_path, child_inode, child_relative_path, counts);
            },
            .file => {
                if (std.mem.eql(u8, entry.name, "_links") or std.mem.eql(u8, entry.name, "_special")) continue; // manifests, not real files
                if (!fs.validateName(entry.name)) {
                    try stdout.print("Error: invalid path component: {s}\n", .{entry.name});
                    return CompileError.InvalidPathName;
                }

                const child_host_path = try std.fs.path.join(init.gpa, &.{ host_dir_path, entry.name });
                defer init.gpa.free(child_host_path);
                const child_relative_path = try std.fs.path.join(init.gpa, &.{ relative_path, entry.name });
                defer init.gpa.free(child_relative_path);

                try stdout.print("  Writing file: {s}\n", .{child_relative_path});

                const input_file = try std.Io.Dir.cwd().openFile(init.io, child_host_path, .{});
                defer input_file.close(init.io);

                const file_size = try input_file.length(init.io);
                const file_data = try init.gpa.alloc(u8, file_size);
                defer init.gpa.free(file_data);
                _ = try input_file.readPositionalAll(init.io, file_data, 0);

                try disk_fs.writeFileAt(fs_dir_inode, entry.name, file_data);

                counts.files += 1;
            },
            else => {},
        }
    }
}

/// Reads the optional `_links` manifest from the root input directory and creates
/// hard links in the filesystem image.  Each non-blank, non-comment line must
/// contain exactly two whitespace-separated filesystem paths:
///   <existing-path> <new-link-path>
/// Both paths are relative to the filesystem root and use '/' as the separator.
fn processLinksManifest(
    init: std.process.Init,
    stdout: anytype,
    disk_fs: *fs.FileSystem,
    root_host_dir_path: []const u8,
    counts: *ImportCounts,
) !void {
    const manifest_host_path = try std.fs.path.join(init.gpa, &.{ root_host_dir_path, "_links" });
    defer init.gpa.free(manifest_host_path);

    const manifest_file = std.Io.Dir.cwd().openFile(init.io, manifest_host_path, .{}) catch return;
    defer manifest_file.close(init.io);

    const file_size = try manifest_file.length(init.io);
    const content = try init.gpa.alloc(u8, file_size);
    defer init.gpa.free(content);
    _ = try manifest_file.readPositionalAll(init.io, content, 0);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const source_path = parts.next() orelse {
            try stdout.print("  Error: malformed link entry: {s}\n", .{line});
            return CompileError.InvalidLinkEntry;
        };
        const target_path = parts.next() orelse {
            try stdout.print("  Error: malformed link entry: {s}\n", .{line});
            return CompileError.InvalidLinkEntry;
        };
        if (parts.next() != null) {
            try stdout.print("  Error: malformed link entry: {s}\n", .{line});
            return CompileError.InvalidLinkEntry;
        }

        const source_inode = disk_fs.getInodeAtPath(source_path) catch |err| {
            try stdout.print("  Error: link source not found: {s} ({s})\n", .{ source_path, @errorName(err) });
            return err;
        };
        defer disk_fs.drop(source_inode);

        const split = fs.splitPath(target_path);
        const dir_inode = disk_fs.getInodeAtPath(split.dir) catch |err| {
            try stdout.print("  Error: link target directory not found: {s} ({s})\n", .{ split.dir, @errorName(err) });
            return err;
        };
        defer disk_fs.drop(dir_inode);

        try stdout.print("  Creating link: {s} -> {s}\n", .{ target_path, source_path });
        try disk_fs.createLink(dir_inode, split.name, source_inode);
        counts.links += 1;
    }
}

const SpecialDeviceEntry = struct {
    target_path: []const u8,
    kind: abi.InodeKind,
    major: abi.DeviceMajor,
    minor: u8,
};

fn parseSpecialDeviceEntry(raw_line: []const u8) !?SpecialDeviceEntry {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;

    var result: SpecialDeviceEntry = undefined;

    var parts = std.mem.tokenizeAny(u8, line, " \t");
    result.target_path = parts.next() orelse return CompileError.InvalidSpecialEntry;
    const block_text = parts.next() orelse return CompileError.InvalidSpecialEntry;
    const major_text = parts.next() orelse return CompileError.InvalidSpecialEntry;
    const minor_text = parts.next() orelse return CompileError.InvalidSpecialEntry;
    if (parts.next() != null) return CompileError.InvalidSpecialEntry;

    const block_flag = try std.fmt.parseInt(u8, block_text, 10);
    result.kind = switch (block_flag) {
        0 => .CharDevice,
        1 => .BlockDevice,
        else => return CompileError.InvalidSpecialEntry,
    };
    const raw_major = try std.fmt.parseInt(u8, major_text, 0);
    result.major = parseDeviceMajor(raw_major) orelse return CompileError.InvalidSpecialEntry;
    result.minor = try std.fmt.parseInt(u8, minor_text, 0);
    return result;
}

/// Reads the optional `_special` manifest from the root input directory and creates
/// character or block device inodes in the filesystem image. Each non-blank,
/// non-comment line must contain exactly four whitespace-separated fields:
///   <path> <block:0|1> <devmajor> <devminor>
/// Paths are relative to the filesystem root and use '/' as the separator.
fn processSpecialManifest(
    init: std.process.Init,
    stdout: anytype,
    disk_fs: *fs.FileSystem,
    root_host_dir_path: []const u8,
    counts: *ImportCounts,
) !void {
    const manifest_host_path = try std.fs.path.join(init.gpa, &.{ root_host_dir_path, "_special" });
    defer init.gpa.free(manifest_host_path);

    const manifest_file = std.Io.Dir.cwd().openFile(init.io, manifest_host_path, .{}) catch return;
    defer manifest_file.close(init.io);

    const file_size = try manifest_file.length(init.io);
    const content = try init.gpa.alloc(u8, file_size);
    defer init.gpa.free(content);
    _ = try manifest_file.readPositionalAll(init.io, content, 0);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const entry = parseSpecialDeviceEntry(raw_line) catch {
            stdout.print("  Error: malformed special entry: {s}\n", .{raw_line}) catch {};
            return CompileError.InvalidSpecialEntry;
        } orelse continue;
        const split = fs.splitPath(entry.target_path);
        const dir_inode = disk_fs.getInodeAtPath(split.dir) catch |err| {
            try stdout.print("  Error: special-file directory not found: {s} ({s})\n", .{ split.dir, @errorName(err) });
            return err;
        };
        defer disk_fs.drop(dir_inode);

        try stdout.print(
            "  Creating special file: {s} (kind={d}, major={d}, minor={d})\n",
            .{ entry.target_path, @intFromEnum(entry.kind), entry.major, entry.minor },
        );
        const inode = try disk_fs.createSpecialFile(dir_inode, split.name, entry.kind, .{
            .major = entry.major,
            .minor = entry.minor,
        });
        disk_fs.drop(inode);
        counts.specials += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    _ = it.skip();

    const input_dir_path = it.next() orelse {
        std.debug.print("Usage: compile_fs <input-dir> <image-size-sectors> <output-image>\n", .{});
        return CompileError.InvalidArgs;
    };
    const size_arg = it.next() orelse {
        std.debug.print("Usage: compile_fs <input-dir> <image-size-sectors> <output-image>\n", .{});
        return CompileError.InvalidArgs;
    };
    const output_path = it.next() orelse {
        std.debug.print("Usage: compile_fs <input-dir> <image-size-sectors> <output-image>\n", .{});
        return CompileError.InvalidArgs;
    };

    const image_size_sectors = try std.fmt.parseInt(u32, size_arg, 10);
    if (image_size_sectors < fs.minimumImageSectorCount()) {
        std.debug.print("Error: image size too small (minimum {} sectors)\n", .{fs.minimumImageSectorCount()});
        return CompileError.InvalidArgs;
    }

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Opening input directory: {s}\n", .{input_dir_path});
    try stdout.print("Creating output image: {s} ({d} sectors)\n", .{ output_path, image_size_sectors });

    var image_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{
        .truncate = true,
        .read = true,
    });
    defer image_file.close(init.io);
    try image_file.setLength(init.io, @as(u64, image_size_sectors) * block_device.BLOCK_SIZE);

    var fbd = file_block_device.FileBlockDevice.init(image_file, init.io, image_size_sectors);
    try fs.FileSystem.format(&fbd.block_dev);
    var disk_fs = try fs.FileSystem.mount(&fbd.block_dev, init.gpa);
    defer disk_fs.unmount();

    try stdout.print("Writing filesystem contents...\n", .{});
    var counts: ImportCounts = .{};
    try importDirectory(init, stdout, &disk_fs, input_dir_path, disk_fs.getRootInode(), "", &counts);
    try processSpecialManifest(init, stdout, &disk_fs, input_dir_path, &counts);
    try processLinksManifest(init, stdout, &disk_fs, input_dir_path, &counts);

    try stdout.print(
        "\nDone. Wrote {d} files, {d} directories, {d} special files, and {d} hard links to {s}\n",
        .{ counts.files, counts.directories, counts.specials, counts.links, output_path },
    );
}
