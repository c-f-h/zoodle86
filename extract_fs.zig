const fs_defs = @import("fs_defs.zig");
const std = @import("std");

const Context = struct {
    file: std.Io.File,
    superblock: fs_defs.Superblock,
};

fn readSector(ctx: *Context, io: std.Io, lba: u32, buf: []u8) !void {
    const offset = @as(u64, lba) * 512;
    _ = try ctx.file.readPositionalAll(io, buf, offset);
}

fn readSuperblock(ctx: *Context, io: std.Io) !void {
    var sector: [512]u8 = undefined;
    try readSector(ctx, io, fs_defs.FS_START_LBA, &sector);

    var superblock: fs_defs.Superblock = undefined;
    @memcpy(std.mem.asBytes(&superblock), sector[0..@sizeOf(fs_defs.Superblock)]);

    if (!fs_defs.isValidSuperblock(&superblock)) {
        return error.InvalidSuperblock;
    }

    ctx.superblock = superblock;
}

fn readDirectoryEntry(ctx: *Context, io: std.Io, index: usize) !fs_defs.DirectoryEntry {
    const sector_lba = ctx.superblock.directory_start_lba + @as(u32, @intCast(index / 8));
    const entry_offset = (index % 8) * @sizeOf(fs_defs.DirectoryEntry);

    var sector: [512]u8 = undefined;
    try readSector(ctx, io, sector_lba, &sector);

    var entry: fs_defs.DirectoryEntry = undefined;
    @memcpy(std.mem.asBytes(&entry), sector[entry_offset .. entry_offset + @sizeOf(fs_defs.DirectoryEntry)]);
    return entry;
}

fn extractFile(ctx: *Context, io: std.Io, entry: *const fs_defs.DirectoryEntry, output_dir: std.Io.Dir, output_name: []const u8) !void {
    if (entry.size_bytes == 0) return;

    var file = try output_dir.createFile(io, output_name, .{});
    defer file.close(io);

    var remaining: usize = entry.size_bytes;
    var lba = entry.start_lba;

    while (remaining > 0) {
        var sector: [512]u8 = undefined;
        try readSector(ctx, io, lba, &sector);

        const chunk_len = @min(remaining, sector.len);
        try file.writeStreamingAll(io, sector[0..chunk_len]);

        remaining -= chunk_len;
        lba += 1;
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

    var ctx = Context{
        .file = image_file,
        .superblock = undefined,
    };

    try stdout.print("Reading superblock from LBA {}...\n", .{fs_defs.FS_START_LBA});
    try readSuperblock(&ctx, init.io);

    try stdout.print("Filesystem info:\n", .{});
    try stdout.print("  File count: {d}\n", .{ctx.superblock.file_count});
    try stdout.print("  Data starts at LBA: {d}\n", .{ctx.superblock.data_start_lba});

    try std.Io.Dir.cwd().createDirPath(init.io, output_path);
    const output_dir = try std.Io.Dir.cwd().openDir(init.io, output_path, .{});
    defer output_dir.close(init.io);

    try stdout.print("Extracting files to: {s}\n", .{output_path});

    var extracted: u32 = 0;

    var index: usize = 1;
    while (index < fs_defs.DIRECTORY_ENTRY_COUNT) : (index += 1) {
        const entry = try readDirectoryEntry(&ctx, init.io, index);

        if (entry.state == fs_defs.ENTRY_STATE_FILE) {
            const name = entry.name[0..entry.name_len];
            try stdout.print("  Extracting: {s} ({d} bytes)\n", .{ name, entry.size_bytes });
            try extractFile(&ctx, init.io, &entry, output_dir, name);
            extracted += 1;
        }
    }

    try stdout.print("\nDone. Extracted {d} files.\n", .{extracted});
}
