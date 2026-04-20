const fs = @import("kernel/fs.zig");
const block_device = @import("kernel/block_device.zig");
const file_block_device = @import("file_block_device.zig");
const std = @import("std");

const CompileError = error{
    InvalidArgs,
    DirectoryInInput,
    TooManyFiles,
    InvalidFileName,
};

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
    if (image_size_sectors < fs.DATA_START_LBA + 1) {
        std.debug.print("Error: image size too small (minimum {} sectors)\n", .{fs.DATA_START_LBA + 1});
        return CompileError.InvalidArgs;
    }

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Opening input directory: {s}\n", .{input_dir_path});
    const input_dir = try std.Io.Dir.cwd().openDir(init.io, input_dir_path, .{ .iterate = true });
    defer input_dir.close(init.io);

    try stdout.print("Collecting files from input directory...\n", .{});

    var files: [fs.DIRECTORY_ENTRY_COUNT - 1][]u8 = undefined;
    var file_count: usize = 0;

    var iter = input_dir.iterateAssumeFirstIteration();
    while (try iter.next(init.io)) |entry| {
        const kind = entry.kind;
        if (kind == .directory) {
            try stdout.print("Error: directories not supported: {s}\n", .{entry.name});
            return CompileError.DirectoryInInput;
        }
        if (kind != .file) continue;

        if (file_count >= files.len) {
            try stdout.print("Error: too many files (max {d})\n", .{fs.DIRECTORY_ENTRY_COUNT - 1});
            return CompileError.TooManyFiles;
        }

        if (!fs.validateName(entry.name)) {
            try stdout.print("Error: invalid filename: {s}\n", .{entry.name});
            return CompileError.InvalidFileName;
        }

        files[file_count] = try init.gpa.dupe(u8, entry.name);
        file_count += 1;
    }

    defer for (files[0..file_count]) |name| init.gpa.free(name);

    try stdout.print("Found {d} files to write\n", .{file_count});
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

    try stdout.print("Writing files...\n", .{});
    for (files[0..file_count]) |name| {
        try stdout.print("  Writing: {s}\n", .{name});

        const input_file = try input_dir.openFile(init.io, name, .{});
        defer input_file.close(init.io);

        const file_size = try input_file.length(init.io);
        const file_data = try init.gpa.alloc(u8, file_size);
        defer init.gpa.free(file_data);
        _ = try input_file.readPositionalAll(init.io, file_data, 0);

        try disk_fs.writeFile(name, file_data);
    }

    try stdout.print("\nDone. Wrote {d} files to {s}\n", .{ file_count, output_path });
}
