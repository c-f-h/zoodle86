const fs = @import("kernel/fs/zodfs.zig");
const block_device = @import("kernel/block_device.zig");
const file_block_device = @import("file_block_device.zig");
const std = @import("std");

const ExtractCounts = struct {
    files: usize = 0,
    directories: usize = 0,
    specials_skipped: usize = 0,
};

fn extractDirectory(
    init: std.process.Init,
    stdout: anytype,
    disk_fs: *fs.FileSystem,
    dir_inode_index: u16,
    output_dir_path: []const u8,
    relative_path: []const u8,
    counts: *ExtractCounts,
) !void {
    var index: usize = 0;
    while (index < fs.DIRECTORY_ENTRY_COUNT) : (index += 1) {
        const entry = (try disk_fs.getDirectoryEntry(dir_inode_index, index)) orelse continue;
        const name = entry.name[0..@as(usize, entry.name_len)];
        const child_output_path = try std.fs.path.join(init.gpa, &.{ output_dir_path, name });
        defer init.gpa.free(child_output_path);
        const child_relative_path = try std.fs.path.join(init.gpa, &.{ relative_path, name });
        defer init.gpa.free(child_relative_path);

        switch (entry.kind) {
            .Regular => {
                const data = try disk_fs.getFileInodeContents(init.gpa, entry.inode_index);
                defer init.gpa.free(data);

                try stdout.print("  Extracting file: {s} ({d} bytes)\n", .{ child_relative_path, data.len });

                var out_file = try std.Io.Dir.cwd().createFile(init.io, child_output_path, .{});
                defer out_file.close(init.io);
                try out_file.writeStreamingAll(init.io, data);
                counts.files += 1;
            },
            .Directory => {
                try stdout.print("  Creating directory: {s}\n", .{child_relative_path});
                try std.Io.Dir.cwd().createDirPath(init.io, child_output_path);
                counts.directories += 1;
                try extractDirectory(init, stdout, disk_fs, entry.inode_index, child_output_path, child_relative_path, counts);
            },
            .CharDevice, .BlockDevice => {
                counts.specials_skipped += 1;
            },
            else => return error.Corrupt,
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    _ = it.skip();

    const image_path = it.next() orelse {
        std.debug.print("Usage: extract_fs <image-file> <output-directory>\n", .{});
        return error.InvalidArgs;
    };
    const output_path = it.next() orelse {
        std.debug.print("Usage: extract_fs <image-file> <output-directory>\n", .{});
        return error.InvalidArgs;
    };

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Opening image: {s}\n", .{image_path});

    var image_file = try std.Io.Dir.cwd().openFile(init.io, image_path, .{});
    defer image_file.close(init.io);

    const file_size = try image_file.length(init.io);
    var fbd = file_block_device.FileBlockDevice.init(image_file, init.io, @intCast(file_size / block_device.BLOCK_SIZE));
    var disk_fs = try fs.FileSystem.mount(&fbd.block_dev);

    //try stdout.print("Filesystem info:\n", .{});
    //try stdout.print("  File count: {d}\n", .{disk_fs.fileCount()});

    try std.Io.Dir.cwd().createDirPath(init.io, output_path);
    try stdout.print("Extracting files to: {s}\n", .{output_path});

    var counts: ExtractCounts = .{};
    try extractDirectory(init, stdout, &disk_fs, fs.ROOT_INODE_INDEX, output_path, "", &counts);

    try stdout.print(
        "\nDone. Extracted {d} files, {d} directories, and skipped {d} special files.\n",
        .{ counts.files, counts.directories, counts.specials_skipped },
    );
}
