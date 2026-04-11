const fs_defs = @import("kernel/fs_defs.zig");
const std = @import("std");

const CompileError = error{
    InvalidArgs,
    CannotOpenImage,
    CannotReadInputDir,
    DirectoryInInput,
    TooManyFiles,
    InvalidFileName,
    FileReadError,
    CannotCreateImage,
    CannotWriteImage,
};

const Context = struct {
    file: std.Io.File,
    superblock: fs_defs.Superblock,
};

fn writeSector(ctx: *Context, io: std.Io, lba: u32, buf: []const u8) !void {
    const offset = @as(u64, lba) * 512;
    try ctx.file.writePositionalAll(io, buf, offset);
}

fn writeSuperblock(ctx: *Context, io: std.Io) !void {
    var sector: [512]u8 = [_]u8{0} ** 512;
    @memcpy(sector[0..@sizeOf(fs_defs.Superblock)], std.mem.asBytes(&ctx.superblock));
    try writeSector(ctx, io, fs_defs.FS_START_LBA, &sector);
}

fn writeDirectoryEntry(ctx: *Context, io: std.Io, index: usize, entry: *const fs_defs.DirectoryEntry) !void {
    const sector_lba = ctx.superblock.directory_start_lba + @as(u32, @intCast(index / 8));
    const entry_offset = (index % 8) * @sizeOf(fs_defs.DirectoryEntry);

    var sector: [512]u8 = [_]u8{0} ** 512;
    _ = try ctx.file.readPositionalAll(io, &sector, @as(u64, sector_lba) * 512);
    @memcpy(sector[entry_offset .. entry_offset + @sizeOf(fs_defs.DirectoryEntry)], std.mem.asBytes(entry));
    try writeSector(ctx, io, sector_lba, &sector);
}

fn zeroEntry() fs_defs.DirectoryEntry {
    return .{
        .state = fs_defs.ENTRY_STATE_FREE,
        .name_len = 0,
        .reserved0 = 0,
        .name = [_]u8{0} ** fs_defs.FILENAME_MAX_LEN,
        .start_lba = 0,
        .sector_count = 0,
        .size_bytes = 0,
        .created_ticks = 0,
        .modified_ticks = 0,
        .flags = 0,
        .reserved = [_]u8{0} ** 20,
    };
}

fn writeFileData(ctx: *Context, io: std.Io, data: []const u8, start_lba: u32) !void {
    var offset: usize = 0;
    var lba = start_lba;

    while (offset < data.len) {
        var sector: [512]u8 = [_]u8{0} ** 512;
        const chunk_len = @min(data.len - offset, 512);
        @memcpy(sector[0..chunk_len], data[offset .. offset + chunk_len]);
        try writeSector(ctx, io, lba, &sector);
        offset += chunk_len;
        lba += 1;
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
    if (image_size_sectors < fs_defs.DATA_START_LBA + 1) {
        std.debug.print("Error: image size too small (minimum {} sectors)\n", .{fs_defs.DATA_START_LBA + 1});
        return CompileError.InvalidArgs;
    }

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Opening input directory: {s}\n", .{input_dir_path});
    const input_dir = try std.Io.Dir.cwd().openDir(init.io, input_dir_path, .{ .iterate = true });
    defer input_dir.close(init.io);

    try stdout.print("Collecting files from input directory...\n", .{});

    var files: [fs_defs.DIRECTORY_ENTRY_COUNT - 1]struct { name: []u8, path: []u8 } = undefined;
    var file_count: usize = 0;

    var iter = input_dir.iterateAssumeFirstIteration();
    while (try iter.next(init.io)) |entry| {
        const kind = entry.kind;
        if (kind == .directory) {
            try stdout.print("Error: directories not supported: {s}\n", .{entry.name});
            return CompileError.DirectoryInInput;
        }
        if (kind != .file) {
            continue;
        }

        if (file_count >= files.len) {
            try stdout.print("Error: too many files (max {d})\n", .{fs_defs.DIRECTORY_ENTRY_COUNT - 1});
            return CompileError.TooManyFiles;
        }

        if (!fs_defs.validateName(entry.name)) {
            try stdout.print("Error: invalid filename: {s}\n", .{entry.name});
            return CompileError.InvalidFileName;
        }

        const name_copy = try init.gpa.dupe(u8, entry.name);
        files[file_count] = .{ .name = name_copy, .path = name_copy };
        file_count += 1;
    }

    defer {
        for (files[0..file_count]) |*file| {
            init.gpa.free(file.name);
        }
    }

    try stdout.print("Found {d} files to write\n", .{file_count});

    const fs_sector_count = image_size_sectors - fs_defs.FS_START_LBA;

    try stdout.print("Creating output image: {s} ({d} sectors)\n", .{ output_path, image_size_sectors });

    var image_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{
        .truncate = true,
        .read = true,
    });
    defer image_file.close(init.io);

    try image_file.setLength(init.io, @as(u64, image_size_sectors) * 512);

    var ctx = Context{
        .file = image_file,
        .superblock = .{
            .magic = fs_defs.MAGIC,
            .version = fs_defs.VERSION,
            .directory_entry_count = @intCast(fs_defs.DIRECTORY_ENTRY_COUNT),
            .fs_start_lba = fs_defs.FS_START_LBA,
            .fs_sector_count = fs_sector_count,
            .directory_start_lba = fs_defs.FS_START_LBA + fs_defs.SUPERBLOCK_SECTORS,
            .directory_sector_count = fs_defs.DIRECTORY_SECTORS,
            .data_start_lba = fs_defs.DATA_START_LBA,
            .next_free_lba = fs_defs.DATA_START_LBA,
            .file_count = @intCast(file_count),
            .reserved = [_]u8{0} ** 28,
        },
    };

    try stdout.print("Writing superblock...\n", .{});
    try writeSuperblock(&ctx, init.io);

    var reserved_entry = zeroEntry();
    reserved_entry.state = fs_defs.ENTRY_STATE_RESERVED;
    try writeDirectoryEntry(&ctx, init.io, 0, &reserved_entry);

    var entry_index: usize = 1;
    var data_lba = fs_defs.DATA_START_LBA;

    try stdout.print("Writing files...\n", .{});
    for (files[0..file_count]) |*file| {
        try stdout.print("  Writing: {s}\n", .{file.name});

        const input_file = try input_dir.openFile(init.io, file.name, .{});
        defer input_file.close(init.io);

        const file_size = try input_file.length(init.io);
        const file_data = try init.gpa.alloc(u8, file_size);
        defer init.gpa.free(file_data);
        _ = try input_file.readPositionalAll(init.io, file_data, 0);

        const sector_count = fs_defs.sectorsForBytes(file_data.len);

        try writeFileData(&ctx, init.io, file_data, data_lba);
        data_lba += sector_count;

        var entry = zeroEntry();
        entry.state = fs_defs.ENTRY_STATE_FILE;
        entry.name_len = @intCast(file.name.len);
        @memcpy(entry.name[0..file.name.len], file.name);
        entry.start_lba = data_lba - sector_count;
        entry.sector_count = sector_count;
        entry.size_bytes = @intCast(file_data.len);

        try writeDirectoryEntry(&ctx, init.io, entry_index, &entry);
        entry_index += 1;
    }

    ctx.superblock.next_free_lba = data_lba;
    try writeSuperblock(&ctx, init.io);

    try stdout.print("\nDone. Wrote {d} files to {s}\n", .{ file_count, output_path });
}
