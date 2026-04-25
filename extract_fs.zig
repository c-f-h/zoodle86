const fs = @import("kernel/fs.zig");
const block_device = @import("kernel/block_device.zig");
const file_block_device = @import("file_block_device.zig");
const std = @import("std");

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

    try stdout.print("Filesystem info:\n", .{});
    try stdout.print("  File count: {d}\n", .{disk_fs.fileCount()});

    try std.Io.Dir.cwd().createDirPath(init.io, output_path);
    const output_dir = try std.Io.Dir.cwd().openDir(init.io, output_path, .{});
    defer output_dir.close(init.io);

    try stdout.print("Extracting files to: {s}\n", .{output_path});

    var extracted: u32 = 0;
    var index: usize = 0;
    while (index < fs.DIRECTORY_ENTRY_COUNT) : (index += 1) {
        const info = (try disk_fs.getFileInfo(index)) orelse continue;
        const name = info.name[0..info.name_len];

        try stdout.print("  Extracting: {s} ({d} bytes)\n", .{ name, info.size_bytes });

        const data = try disk_fs.readFile(init.gpa, name);
        defer init.gpa.free(data);

        var out_file = try output_dir.createFile(init.io, name, .{});
        defer out_file.close(init.io);
        try out_file.writeStreamingAll(init.io, data);

        extracted += 1;
    }

    try stdout.print("\nDone. Extracted {d} files.\n", .{extracted});
}
