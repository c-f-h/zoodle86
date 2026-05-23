/// Host-side tool to locate what a given LBA block number is used for
/// in a ZOD2 filesystem image.
///
/// Usage:
///   zig run --dep abi '-Mroot=block_locate.zig' '-Mabi=common/abi.zig' -- <image-file> <lba>
///
/// The LBA may be specified in decimal or hex (0x...).
const std = @import("std");
const fs = @import("kernel/fs/zodfs.zig");
const block_device = @import("kernel/block_device.zig");
const file_block_device = @import("file_block_device.zig");

const Context = struct {
    disk_fs: *const fs.FileSystem,
    allocator: std.mem.Allocator,

    fn logicalToLba(ctx: *const Context, block_index: u32) u32 {
        return ctx.disk_fs.superblock.data_start_lba + block_index;
    }
};

fn readInodeDirect(self: *const fs.FileSystem, inode_index: fs.InodeT) fs.FsError!fs.DiskInode {
    if (inode_index >= self.superblock.inode_count) return error.Corrupt;
    const sector_lba = self.superblock.inode_table_start_lba +
        @divFloor(@as(u32, inode_index), @as(u32, @intCast(fs.INODES_PER_SECTOR)));
    const inode_offset = (@as(usize, inode_index) % fs.INODES_PER_SECTOR) * @sizeOf(fs.DiskInode);
    var sector: [512]u8 = undefined;
    try self.block_dev.readBlock(sector_lba, &sector);
    var inode: fs.DiskInode = undefined;
    @memcpy(std.mem.asBytes(&inode), sector[inode_offset .. inode_offset + @sizeOf(fs.DiskInode)]);
    return inode;
}

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    _ = it.skip();

    const image_path = it.next() orelse {
        std.debug.print("Usage: block_locate <image-file> <lba>\n", .{});
        return error.InvalidArgs;
    };
    const lba_str = it.next() orelse {
        std.debug.print("Usage: block_locate <image-file> <lba>\n", .{});
        return error.InvalidArgs;
    };
    const target_lba = std.fmt.parseUnsigned(u32, lba_str, 0) catch {
        std.debug.print("Invalid LBA: {s}\n", .{lba_str});
        return error.InvalidArgs;
    };

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Opening image: {s}\n", .{image_path});

    var image_file = try std.Io.Dir.cwd().openFile(init.io, image_path, .{});
    defer image_file.close(init.io);

    const file_size = try image_file.length(init.io);
    const block_count = @as(u32, @intCast(file_size / block_device.BLOCK_SIZE));

    var fbd = file_block_device.FileBlockDevice.init(image_file, init.io, block_count);
    var disk_fs = try fs.FileSystem.mount(&fbd.block_dev, init.gpa);
    defer disk_fs.unmount();

    const ctx = Context{ .disk_fs = &disk_fs, .allocator = init.gpa };

    try classifyLba(&ctx, target_lba, stdout);
    try stdout_writer.flush();
}

fn classifyLba(ctx: *const Context, lba: u32, stdout: anytype) !void {
    const sb = &ctx.disk_fs.superblock;
    const total_blocks = ctx.disk_fs.block_dev.block_count;

    try stdout.print("Image: {} blocks ({} bytes)\n\n", .{
        total_blocks,
        total_blocks * block_device.BLOCK_SIZE,
    });

    try stdout.print("Region layout:\n", .{});
    try stdout.print("  LBA {:<5}  Boot sector\n", .{0});
    try stdout.print("  LBA 1..{}  Stage 2 loader\n", .{fs.FS_START_LBA - 1});
    try stdout.print("  LBA {:<5}  Superblock\n", .{fs.FS_START_LBA});
    try stdout.print("  LBA {}..{}  Bitmap ({} sectors)\n", .{
        sb.bitmap_start_lba,
        sb.bitmap_start_lba + sb.bitmap_sector_count - 1,
        sb.bitmap_sector_count,
    });
    try stdout.print("  LBA {}..{}  Inode table ({} sectors, {} inodes)\n", .{
        sb.inode_table_start_lba,
        sb.inode_table_start_lba + sb.inode_table_sector_count - 1,
        sb.inode_table_sector_count,
        sb.inode_count,
    });
    try stdout.print("  LBA {}..{}  Data blocks ({} blocks)\n", .{
        sb.data_start_lba,
        sb.data_start_lba + sb.data_block_count - 1,
        sb.data_block_count,
    });

    try stdout.print("\nTarget LBA {} (0x{x}): ", .{ lba, lba });

    if (lba >= total_blocks) {
        try stdout.print("OUT OF RANGE (image has only {} blocks)\n", .{total_blocks});
        return;
    }

    if (lba == 0) {
        try stdout.print("Boot sector\n", .{});
        return;
    }

    if (lba < fs.FS_START_LBA) {
        try stdout.print("Stage 2 loader area (reserved, LBA 1..{})\n", .{fs.FS_START_LBA - 1});
        return;
    }

    if (lba == fs.FS_START_LBA) {
        try stdout.print("Superblock\n", .{});
        try printSuperblockInfo(ctx, stdout);
        return;
    }

    const bitmap_end = sb.bitmap_start_lba + sb.bitmap_sector_count;
    if (lba >= sb.bitmap_start_lba and lba < bitmap_end) {
        try stdout.print("Block allocation bitmap\n", .{});
        try printBitmapInfo(ctx, lba, stdout);
        return;
    }

    const inode_end = sb.inode_table_start_lba + sb.inode_table_sector_count;
    if (lba >= sb.inode_table_start_lba and lba < inode_end) {
        try stdout.print("Inode table\n", .{});
        try printInodeTableInfo(ctx, lba, stdout);
        return;
    }

    const data_end = sb.data_start_lba + sb.data_block_count;
    if (lba >= sb.data_start_lba and lba < data_end) {
        try stdout.print("Data block\n", .{});
        try printDataBlockInfo(ctx, lba, stdout);
        return;
    }

    try stdout.print("Unused area (past the filesystem data region)\n", .{});
}

fn printSuperblockInfo(ctx: *const Context, stdout: anytype) !void {
    const sb = &ctx.disk_fs.superblock;
    try stdout.print("  Magic:         {s}\n", .{sb.magic});
    try stdout.print("  Version:       {}\n", .{sb.version});
    try stdout.print("  Block size:    {} bytes\n", .{sb.block_size});
    try stdout.print("  FS sectors:    {}\n", .{sb.fs_sector_count});
    try stdout.print("  File count:    {}\n", .{sb.file_count});
    try stdout.print("  Bitmap:        LBA {} ({} sectors)\n", .{ sb.bitmap_start_lba, sb.bitmap_sector_count });
    try stdout.print("  Inode table:   LBA {} ({} sectors, {} inodes)\n", .{ sb.inode_table_start_lba, sb.inode_table_sector_count, sb.inode_count });
    try stdout.print("  Data region:   LBA {} ({} blocks)\n", .{ sb.data_start_lba, sb.data_block_count });
}

fn printBitmapInfo(ctx: *const Context, lba: u32, stdout: anytype) !void {
    const sb = &ctx.disk_fs.superblock;
    const sector_offset = lba - sb.bitmap_start_lba;
    try stdout.print("  Sector {}/{} of bitmap\n", .{ sector_offset + 1, sb.bitmap_sector_count });

    const first_block = sector_offset * 4096;
    const last_block = @min(first_block + 4095, sb.data_block_count - 1);
    try stdout.print("  Covers data blocks {}..{}\n", .{ first_block, last_block });

    var sector: [512]u8 = undefined;
    try ctx.disk_fs.block_dev.readBlock(lba, &sector);

    var allocated: usize = 0;
    var free_count: usize = 0;
    const bits = @min(@as(usize, 4096), sb.data_block_count - first_block);
    for (0..bits) |bit| {
        const byte_idx = bit / 8;
        const bit_idx: u8 = @intCast(bit % 8);
        if ((sector[byte_idx] & (@as(u8, 1) << @intCast(bit_idx))) != 0) {
            allocated += 1;
        } else {
            free_count += 1;
        }
    }
    try stdout.print("  Status: {} allocated, {} free\n", .{ allocated, free_count });
}

fn printInodeTableInfo(ctx: *const Context, lba: u32, stdout: anytype) !void {
    const sb = &ctx.disk_fs.superblock;
    const sector_offset = lba - sb.inode_table_start_lba;
    const start_inode = sector_offset * fs.INODES_PER_SECTOR;
    const end_inode = @min(start_inode + fs.INODES_PER_SECTOR, sb.inode_count);
    try stdout.print("  Sector {}/{} of inode table\n", .{ sector_offset + 1, sb.inode_table_sector_count });
    try stdout.print("  Inodes {}..{}:\n", .{ start_inode, end_inode - 1 });

    var sector: [512]u8 = undefined;
    try ctx.disk_fs.block_dev.readBlock(lba, &sector);

    var inode_idx = start_inode;
    while (inode_idx < end_inode) : (inode_idx += 1) {
        const offset = (inode_idx % fs.INODES_PER_SECTOR) * @sizeOf(fs.DiskInode);
        var inode: fs.DiskInode = undefined;
        @memcpy(std.mem.asBytes(&inode), sector[offset .. offset + @sizeOf(fs.DiskInode)]);

        try stdout.print("    Inode {}: ", .{inode_idx});
        switch (inode.kind) {
            .Free => try stdout.print("free\n", .{}),
            .Regular => try stdout.print("regular file, size={}, links={}\n", .{ inode.size_bytes, inode.link_count }),
            .Directory => try stdout.print("directory, links={}\n", .{inode.link_count}),
            .CharDevice => try stdout.print("char device {}.{}\n", .{ @intFromEnum(inode.device.major), inode.device.minor }),
            .BlockDevice => try stdout.print("block device {}.{}\n", .{ @intFromEnum(inode.device.major), inode.device.minor }),
            .Symlink => try stdout.print("symlink, size={}\n", .{inode.size_bytes}),
            else => try stdout.print("unknown (kind={})\n", .{@intFromEnum(inode.kind)}),
        }
    }
}

fn printDataBlockInfo(ctx: *const Context, lba: u32, stdout: anytype) !void {
    const sb = &ctx.disk_fs.superblock;
    const block_index = lba - sb.data_start_lba;
    try stdout.print("  Data block index: {} (LBA offset from data region start)\n", .{block_index});

    var allocated = false;
    {
        const bitmap_sector = block_index / 4096;
        const bit = block_index % 4096;
        if (bitmap_sector < sb.bitmap_sector_count) {
            var sector: [512]u8 = undefined;
            try ctx.disk_fs.block_dev.readBlock(sb.bitmap_start_lba + bitmap_sector, &sector);
            const byte_idx: usize = @intCast(bit / 8);
            const bit_idx: u8 = @intCast(bit % 8);
            allocated = (sector[byte_idx] & (@as(u8, 1) << @intCast(bit_idx))) != 0;
        }
    }
    try stdout.print("  Allocated: {}\n", .{allocated});

    if (allocated) {
        try stdout.print("  Used by:\n", .{});
        var found: usize = 0;
        var role: ?BlockRole = null;
        const root_inode = try ctx.disk_fs.readRootInode();
        try findInodeUsage(ctx, &root_inode, block_index, "/", &found, &role, stdout);
        if (found == 0) {
            try stdout.print("    (orphan data block - no inode references it)\n", .{});
        }
        if (role.? == .indirect) {
            try dumpPointerBlockContents(ctx, block_index, stdout);
        }
    }
}

fn dumpPointerBlockContents(ctx: *const Context, block_index: u32, stdout: anytype) !void {
    var block_data: [512]u8 = undefined;
    const lba = ctx.disk_fs.superblock.data_start_lba + block_index;
    try ctx.disk_fs.block_dev.readBlock(lba, &block_data);
    const pointers = std.mem.bytesAsSlice(u32, &block_data);

    var count: usize = 0;
    for (pointers) |ptr| {
        if (ptr != fs.BLOCK_POINTER_NONE) count += 1;
    }
    if (count == 0) return;

    try stdout.print("  Pointer block contents ({} of {} slots used):\n", .{ count, pointers.len });
    for (pointers, 0..) |ptr, i| {
        if (ptr == fs.BLOCK_POINTER_NONE) continue;
        try stdout.print("    [{}] -> data block {} (LBA {})\n", .{ i, ptr, ctx.disk_fs.superblock.data_start_lba + ptr });
    }
}

fn findInodeUsage(ctx: *const Context, inode: *const fs.DiskInode, target_block: u32, path: []const u8, found: *usize, out_role: *?BlockRole, stdout: anytype) !void {
    if (inode.kind == .Free) return;

    if (inode.kind != .CharDevice and inode.kind != .BlockDevice) {
        if (blockInInode(ctx, inode, target_block)) |role| {
            try stdout.print("    {s} (kind: {s}, size: {} bytes) - ", .{
                path,
                @tagName(inode.kind),
                inode.size_bytes,
            });
            switch (role) {
                .direct => try stdout.writeAll("direct\n"),
                .indirect => |level| try stdout.print("indirect({d})\n", .{level}),
            }
            if (found.* == 0) {
                out_role.* = role;
            }
            found.* += 1;
        }
    }

    if (inode.kind == .Directory) {
        var index: usize = 0;
        while (index < fs.DIRECTORY_ENTRY_COUNT) : (index += 1) {
            const entry = ctx.disk_fs.readDirEntry(inode, index) catch |err| switch (err) {
                error.Corrupt, error.NotADirectory => continue,
                else => return err,
            };
            if (entry.kind == .Free) continue;

            const name = entry.name[0..@as(usize, entry.name_len)];
            const child_path = if (std.mem.eql(u8, path, "/"))
                try ctx.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, name });
            defer ctx.allocator.free(child_path);

            const child_inode = try readInodeDirect(ctx.disk_fs, entry.inode_index);
            try findInodeUsage(ctx, &child_inode, target_block, child_path, found, out_role, stdout);
        }
    }
}

const BlockRole = union(enum) {
    direct: void,
    indirect: u32,
};

fn blockInInode(ctx: *const Context, inode: *const fs.DiskInode, target_block: u32) ?BlockRole {
    for (inode.direct_blocks) |block| {
        if (block == target_block) return .direct;
    }

    if (inode.indirect_block != fs.BLOCK_POINTER_NONE) {
        if (inode.indirect_block == target_block) return .{ .indirect = 1 };
        if (blockInIndirect(ctx, inode.indirect_block, target_block, 1)) |role| return role;
    }

    if (inode.double_indirect_block != fs.BLOCK_POINTER_NONE) {
        if (inode.double_indirect_block == target_block) return .{ .indirect = 2 };
        if (blockInIndirect(ctx, inode.double_indirect_block, target_block, 2)) |role| return role;
    }

    return null;
}

fn blockInIndirect(ctx: *const Context, block_index: u32, target_block: u32, level: u32) ?BlockRole {
    var pointers: [fs.POINTERS_PER_INDIRECT_BLOCK]u32 = undefined;
    const lba = ctx.logicalToLba(block_index);
    ctx.disk_fs.block_dev.readBlock(lba, @ptrCast(&pointers)) catch return null;

    for (pointers) |ptr| {
        if (ptr == fs.BLOCK_POINTER_NONE) continue;
        if (level == 1) {
            if (ptr == target_block) return .{ .direct = {} };
        } else if (level > 1) {
            if (ptr == target_block) return .{ .indirect = level - 1 };
            if (blockInIndirect(ctx, ptr, target_block, level - 1)) |role| return role;
        } else @panic("invalid level");
    }
    return null;
}
