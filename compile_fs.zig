const fs = @import("kernel/fs.zig");
const block_device = @import("kernel/block_device.zig");
const file_block_device = @import("file_block_device.zig");
const std = @import("std");

const CompileError = error{
    InvalidArgs,
    InvalidPathName,
    InvalidLinkEntry,
};

const ImportCounts = struct {
    files: usize = 0,
    directories: usize = 0,
    links: usize = 0,
};

fn appendPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8, sep: u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, sep, name });
}

fn importDirectory(
    init: std.process.Init,
    stdout: anytype,
    disk_fs: *fs.FileSystem,
    host_dir_path: []const u8,
    fs_dir_inode: u16,
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

                const child_host_path = try appendPath(init.gpa, host_dir_path, entry.name, std.fs.path.sep);
                defer init.gpa.free(child_host_path);
                const child_relative_path = try appendPath(init.gpa, relative_path, entry.name, '/');
                defer init.gpa.free(child_relative_path);

                try stdout.print("  Creating directory: {s}\n", .{child_relative_path});
                const child_inode = try disk_fs.createDirectoryAt(fs_dir_inode, entry.name);
                counts.directories += 1;
                try importDirectory(init, stdout, disk_fs, child_host_path, child_inode, child_relative_path, counts);
            },
            .file => {
                if (std.mem.eql(u8, entry.name, "_links")) continue; // manifest, not a real file
                if (!fs.validateName(entry.name)) {
                    try stdout.print("Error: invalid path component: {s}\n", .{entry.name});
                    return CompileError.InvalidPathName;
                }

                const child_host_path = try appendPath(init.gpa, host_dir_path, entry.name, std.fs.path.sep);
                defer init.gpa.free(child_host_path);
                const child_relative_path = try appendPath(init.gpa, relative_path, entry.name, '/');
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
    const manifest_host_path = try appendPath(init.gpa, root_host_dir_path, "_links", std.fs.path.sep);
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

        var parts = std.mem.splitScalar(u8, line, ' ');
        const source_path = parts.next() orelse continue;
        const target_path = std.mem.trim(u8, parts.rest(), " \t");
        if (target_path.len == 0) {
            try stdout.print("  Error: malformed link entry: {s}\n", .{line});
            return CompileError.InvalidLinkEntry;
        }

        const source_inode = disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, source_path) catch |err| {
            try stdout.print("  Error: link source not found: {s} ({s})\n", .{ source_path, @errorName(err) });
            return err;
        };

        const split = fs.splitPath(target_path);
        const dir_inode = disk_fs.walkPathToInode(fs.ROOT_INODE_INDEX, split.dir) catch |err| {
            try stdout.print("  Error: link target directory not found: {s} ({s})\n", .{ split.dir, @errorName(err) });
            return err;
        };

        try stdout.print("  Creating link: {s} -> {s}\n", .{ target_path, source_path });
        try disk_fs.createLink(dir_inode, split.name, source_inode);
        counts.links += 1;
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
    // The image is blank (all zeros), so mountOrFormat formats a fresh filesystem.
    var disk_fs = try fs.FileSystem.mountOrFormat(&fbd.block_dev);

    try stdout.print("Writing filesystem contents...\n", .{});
    var counts: ImportCounts = .{};
    try importDirectory(init, stdout, &disk_fs, input_dir_path, fs.ROOT_INODE_INDEX, "", &counts);
    try processLinksManifest(init, stdout, &disk_fs, input_dir_path, &counts);

    try stdout.print(
        "\nDone. Wrote {d} files, {d} directories, and {d} hard links to {s}\n",
        .{ counts.files, counts.directories, counts.links, output_path },
    );
}
