// Virtual filesystem layer
//
// For now forwards to a single ZODFS instance

const zodfs = @import("zodfs.zig");
const block_device = @import("../block_device.zig");
const kernel = @import("../kernel.zig");
const ide = @import("../ide.zig");
const console = @import("../console.zig");
const filedesc = @import("../filedesc.zig");
const abi = @import("abi");
const std = @import("std");

pub const FsError = zodfs.FsError;
pub const ReadFileError = FsError || error{OutOfMemory};

pub const Stat = abi.Stat;

const ResolveEntry = struct {
    parent_inode: *zodfs.DiskInode,
    index: u32,
    entry: zodfs.DirectoryEntry,
};

const ResolveOptions = struct {
    follow_final: bool,
    allow_missing_final: bool = false,
};

const ResolveResult = union(enum) {
    found: ResolveEntry,
    missing_final: []u8,
};

const MAX_SYMLINK_EXPANSIONS: usize = 16;

var root_fs: zodfs.FileSystem = undefined;
var root_block_device: ide.IdeBlockDevice = undefined;

pub fn mountRootFs() !void {
    const kernel_console = &console.primary;
    const drive = ide.Drive.master;
    ide.selectDrive(drive);

    const drive_info = try ide.identifyDrive(drive);
    kernel_console.put(.{
        "Drive model:     ",    &drive_info.model,
        "\nDrive serial:    ",  &drive_info.serial,
        "\nSectors (LBA28): ",  drive_info.max_lba28,
        "h\nCapabilities:    ", drive_info.capabilities,
        "h\n",
    });

    root_block_device = ide.IdeBlockDevice.init(drive, drive_info.max_lba28);
    try root_block_device.block_dev.initCache(kernel.getAllocator());
    // TODO: deinit cache on unmount
    root_fs = try zodfs.FileSystem.mount(&root_block_device.block_dev, kernel.getAllocator());
}

pub fn getRootFs() *zodfs.FileSystem {
    return &root_fs;
}

/// Split a file path into directory and filename components.
pub fn splitPath(path: []const u8) struct { dir: []const u8, name: []const u8 } {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    if (last_slash) |idx| {
        return .{ .dir = trimmed[0..idx], .name = trimmed[idx + 1 ..] };
    } else {
        return .{ .dir = &.{}, .name = trimmed };
    }
}

/// Returns stat-like metadata for a filesystem path resolved against `cwd`.
pub fn statAt(cwd: []const u8, path: []const u8, follow_final: bool) FsError!Stat {
    const inode = try resolvePathInodeAt(cwd, path, follow_final);
    defer root_fs.drop(inode);
    return try root_fs.statInode(inode);
}

/// Returns true if a file, directory, or symlink exists at the given path.
pub fn pathExists(path: []const u8) FsError!bool {
    return pathExistsAt("/", path);
}

/// Returns true if a file, directory, or symlink exists at the given path resolved against `cwd`.
pub fn pathExistsAt(cwd: []const u8, path: []const u8) FsError!bool {
    if (path.len == 0) return error.InvalidName;

    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    if (std.mem.eql(u8, canonical, "/")) {
        allocator.free(canonical);
        return true;
    }

    _ = resolvePathCanonicalOwned(canonical, .{ .follow_final = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Reads an entire file, following a final symlink when present.
pub fn getFileContents(allocator: std.mem.Allocator, path: []const u8) (FsError || error{OutOfMemory})![]u8 {
    return getFileContentsAt(allocator, "/", path);
}

/// Reads an entire file resolved against `cwd`, following a final symlink when present.
pub fn getFileContentsAt(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) (FsError || error{OutOfMemory})![]u8 {
    const inode = try resolvePathInodeAt(cwd, path, true);
    defer root_fs.drop(inode);
    return readInodeContents(&root_fs, allocator, inode);
}

/// Reads the full contents of a file identified directly by inode into a newly allocated buffer.
pub fn readInodeContents(fs: *const zodfs.FileSystem, allocator: std.mem.Allocator, inode: *const zodfs.DiskInode) ReadFileError![]u8 {
    if (inode.size_bytes == 0) {
        return allocator.alloc(u8, 0);
    }

    const data = try allocator.alloc(u8, @intCast(inode.size_bytes));
    errdefer allocator.free(data);
    _ = try fs.readInodeAt(inode, 0, data);
    return data;
}

/// Creates or overwrites a file with the given path, following a final symlink when present.
pub fn writeFileContents(path: []const u8, data: []const u8) FsError!void {
    return writeFileContentsAt("/", path, data);
}

/// Creates or overwrites a file resolved against `cwd`, following a final symlink when present.
pub fn writeFileContentsAt(cwd: []const u8, path: []const u8, data: []const u8) FsError!void {
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    const inode = if (std.mem.eql(u8, canonical, "/")) blk: {
        allocator.free(canonical);
        break :blk root_fs.dup(root_fs.getRootInode());
    } else switch (try resolvePathCanonicalOwned(canonical, .{ .follow_final = true, .allow_missing_final = true })) {
        .found => |resolved| blk: {
            defer root_fs.drop(resolved.parent_inode);
            break :blk try root_fs.getInode(resolved.entry.inode_index);
        },
        .missing_final => |expanded_path| blk: {
            defer allocator.free(expanded_path);
            const split = splitPath(expanded_path);
            const parent_path = if (split.dir.len == 0) "/" else split.dir;
            const parent_inode = try resolvePathInodeCanonical(parent_path, true);
            defer root_fs.drop(parent_inode);
            break :blk try root_fs.createFile(parent_inode, split.name);
        },
    };
    defer root_fs.drop(inode);

    if (inode.kind != .Regular) return error.NotAFile;
    try root_fs.writeToInodeAtOffset(inode, 0, data, true);
}

/// Moves (renames) old_path to new_path, atomically replacing any existing non-directory entry at
/// new_path. Directories cannot be moved. Open descriptors keep the replaced inode alive until the
/// final close, but the destination path switches to the source inode immediately.
pub fn moveFile(old_path: []const u8, new_path: []const u8) FsError!void {
    return moveFileAt("/", old_path, new_path);
}

/// Moves a file from `old_path` to `new_path`, resolving both paths against `cwd`.
pub fn moveFileAt(cwd: []const u8, old_path: []const u8, new_path: []const u8) FsError!void {
    if (std.mem.eql(u8, old_path, new_path)) return;

    const allocator = kernel.getAllocator();
    const old_canonical = try canonicalizePath(allocator, cwd, old_path);
    if (std.mem.eql(u8, old_canonical, "/")) {
        allocator.free(old_canonical);
        return error.InvalidName;
    }
    const src = switch (try resolvePathCanonicalOwned(old_canonical, .{ .follow_final = false })) {
        .found => |resolved| resolved,
        .missing_final => unreachable,
    };
    defer root_fs.drop(src.parent_inode);
    if (src.entry.kind == .Directory) return error.NotAFile;

    const src_inode = try root_fs.getInode(src.entry.inode_index);
    defer root_fs.drop(src_inode);

    const new_canonical = try canonicalizePath(allocator, cwd, new_path);
    defer allocator.free(new_canonical);
    const new_split = splitPath(new_canonical);
    const dst_parent_inode = try resolveParentDirectoryCanonical(new_canonical);
    defer root_fs.drop(dst_parent_inode);

    const existing = try root_fs.findDirEntryAndIndex(dst_parent_inode, new_split.name);
    if (existing) |existing_index_and_direntry| {
        const ex_index, const ex_direntry = existing_index_and_direntry;
        if (ex_direntry.kind == .Directory) return error.NotAFile;
        try root_fs.deleteFile(dst_parent_inode, ex_index);
    }

    try root_fs.createLink(dst_parent_inode, new_split.name, src_inode);
    try root_fs.deleteFile(src.parent_inode, src.index);
}

/// Creates a new hard link to an existing non-directory inode.
pub fn linkFile(old_path: []const u8, new_path: []const u8) FsError!void {
    return linkFileAt("/", old_path, new_path);
}

/// Creates a new hard link to an existing non-directory inode, resolving both paths against `cwd`.
pub fn linkFileAt(cwd: []const u8, old_path: []const u8, new_path: []const u8) FsError!void {
    const allocator = kernel.getAllocator();
    const old_canonical = try canonicalizePath(allocator, cwd, old_path);
    if (std.mem.eql(u8, old_canonical, "/")) {
        allocator.free(old_canonical);
        return error.InvalidName;
    }
    const source = switch (try resolvePathCanonicalOwned(old_canonical, .{ .follow_final = false })) {
        .found => |resolved| resolved,
        .missing_final => unreachable,
    };
    defer root_fs.drop(source.parent_inode);

    const target_inode = try root_fs.getInode(source.entry.inode_index);
    defer root_fs.drop(target_inode);

    const new_canonical = try canonicalizePath(allocator, cwd, new_path);
    defer allocator.free(new_canonical);
    const split = splitPath(new_canonical);
    const parent_inode = try resolveParentDirectoryCanonical(new_canonical);
    defer root_fs.drop(parent_inode);

    try root_fs.createLink(parent_inode, split.name, target_inode);
}

pub fn createDirectory(path: []const u8) FsError!void {
    return createDirectoryAt("/", path);
}

/// Creates a directory at the given path resolved against `cwd`.
pub fn createDirectoryAt(cwd: []const u8, path: []const u8) FsError!void {
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    defer allocator.free(canonical);
    const split = splitPath(canonical);
    const parent_inode = try resolveParentDirectoryCanonical(canonical);
    defer root_fs.drop(parent_inode);

    const inode = try root_fs.createDirectory(parent_inode, split.name);
    root_fs.drop(inode);
}

/// Creates a symbolic link whose contents are the raw target path bytes.
pub fn symlink(target_path: []const u8, link_path: []const u8) FsError!void {
    return symlinkAt("/", target_path, link_path);
}

/// Creates a symbolic link at `link_path` resolved against `cwd`.
pub fn symlinkAt(cwd: []const u8, target_path: []const u8, link_path: []const u8) FsError!void {
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, link_path);
    defer allocator.free(canonical);
    const split = splitPath(canonical);
    const parent_inode = try resolveParentDirectoryCanonical(canonical);
    defer root_fs.drop(parent_inode);

    try root_fs.createSymlink(parent_inode, split.name, target_path);
}

/// Removes an empty directory.
pub fn removeDirectory(path: []const u8) FsError!void {
    return removeDirectoryAt("/", path);
}

/// Removes an empty directory resolved against `cwd`.
pub fn removeDirectoryAt(cwd: []const u8, path: []const u8) FsError!void {
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    if (std.mem.eql(u8, canonical, "/")) {
        allocator.free(canonical);
        return error.InvalidName;
    }
    const resolved = switch (try resolvePathCanonicalOwned(canonical, .{ .follow_final = false })) {
        .found => |entry| entry,
        .missing_final => unreachable,
    };
    defer root_fs.drop(resolved.parent_inode);

    try root_fs.deleteDirectory(resolved.parent_inode, resolved.index);
}

/// Unlinks a filesystem path. Open descriptors keep the inode alive until the final close.
pub fn unlink(path: []const u8) FsError!void {
    return unlinkAt("/", path);
}

/// Unlinks a filesystem path resolved against `cwd`.
pub fn unlinkAt(cwd: []const u8, path: []const u8) FsError!void {
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    if (std.mem.eql(u8, canonical, "/")) {
        allocator.free(canonical);
        return error.InvalidName;
    }
    const resolved = switch (try resolvePathCanonicalOwned(canonical, .{ .follow_final = false })) {
        .found => |entry| entry,
        .missing_final => unreachable,
    };
    defer root_fs.drop(resolved.parent_inode);

    try root_fs.deleteFile(resolved.parent_inode, resolved.index);
}

/////////////////////////// Open file handling ///////////////////////////

pub const OpenFile = struct {
    in_use: u8 = 0, // Reference counter
    disk_fs: *zodfs.FileSystem = undefined,
    inode: *zodfs.DiskInode = undefined,
    offset: u32 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,

    pub fn getSize(self: *const OpenFile) u32 {
        return self.inode.size_bytes;
    }
};

pub const MAX_OPEN_FILES = 32;

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;

fn findFreeOpenFileIndex() ?usize {
    for (&open_files, 0..) |open_file, index| {
        if (open_file.in_use == 0) return index;
    }
    return null;
}

pub fn getOpenFile(index: u8) *OpenFile {
    if (index >= open_files.len) @panic("invalid open file index");
    if (open_files[index].in_use == 0) @panic("open file index not in use");
    return &open_files[index];
}

/// Opens or creates a filesystem-backed descriptor, not bound to a particular task.
pub fn createOpenFileEntry(path: []const u8, flags: u32) FsError!u8 {
    return createOpenFileEntryAt("/", path, flags);
}

/// Opens or creates a filesystem-backed descriptor using `cwd` for relative path resolution.
pub fn createOpenFileEntryAt(cwd: []const u8, path: []const u8, flags: u32) FsError!u8 {
    if (path.len == 0) return error.InvalidName;

    const access_mode = try filedesc.validateOpenFlags(flags);
    const open_index = findFreeOpenFileIndex() orelse return error.SystemFileTableFull;
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    const inode = if (std.mem.eql(u8, canonical, "/")) blk: {
        allocator.free(canonical);
        break :blk root_fs.dup(root_fs.getRootInode());
    } else switch (try resolvePathCanonicalOwned(canonical, .{ .follow_final = true, .allow_missing_final = true })) {
        .found => |resolved| blk: {
            defer root_fs.drop(resolved.parent_inode);
            break :blk try root_fs.getInode(resolved.entry.inode_index);
        },
        .missing_final => |expanded_path| blk: {
            defer allocator.free(expanded_path);
            if ((flags & abi.O_CREAT) == 0) return error.FileNotFound;

            const split = splitPath(expanded_path);
            const parent_path = if (split.dir.len == 0) "/" else split.dir;
            const parent_inode = try resolvePathInodeCanonical(parent_path, true);
            defer root_fs.drop(parent_inode);
            break :blk try root_fs.createFile(parent_inode, split.name);
        },
    };
    errdefer root_fs.drop(inode);

    if ((flags & abi.O_TRUNC) != 0) {
        try root_fs.resizeInode(inode, 0);
    }

    open_files[open_index] = .{
        .in_use = 1,
        .disk_fs = &root_fs,
        .inode = inode,
        .offset = 0,
        .readable = access_mode != abi.O_WRONLY,
        .writable = access_mode != abi.O_RDONLY,
        .append = (flags & abi.O_APPEND) != 0,
    };
    return @truncate(open_index);
}

pub fn readOpenFile(index: u8, dest: []u8) FsError!usize {
    const open_file = getOpenFile(index);
    if (!open_file.readable) return error.AccessDenied;

    const bytes_read = try open_file.disk_fs.readInodeAt(open_file.inode, open_file.offset, dest);
    open_file.offset = std.math.add(u32, open_file.offset, bytes_read) catch return error.NoSpace;
    return bytes_read;
}

pub fn writeOpenFile(index: u8, src: []const u8) FsError!usize {
    const open_file = getOpenFile(index);
    if (!open_file.writable) return error.AccessDenied;

    const write_offset = if (open_file.append)
        open_file.inode.size_bytes
    else
        open_file.offset;
    const written = try open_file.disk_fs.writeInodeAt(open_file.inode, write_offset, src);
    open_file.offset = std.math.add(u32, write_offset, written) catch return error.NoSpace;
    return written;
}

pub fn closeOpenFile(index: u8) void {
    const open_file = getOpenFile(index);
    open_file.in_use -= 1;
    if (open_file.in_use == 0) {
        open_file.disk_fs.drop(open_file.inode);
        open_file.* = .{};
    }
}

/// Enumerates directory entries from an open directory file into an ABI buffer.
pub fn readDirEntries(file_index: u8, dest: []abi.DirEntry) FsError!usize {
    if (dest.len == 0) return 0;

    const open_file = getOpenFile(file_index);
    const dir_stat = try open_file.disk_fs.statInode(open_file.inode);
    if (dir_stat.kind != .Directory) return error.NotADirectory;

    const raw_entry_size = @sizeOf(zodfs.DirectoryEntry);
    if (open_file.offset % raw_entry_size != 0) return error.InvalidSeek;

    var dir_index: usize = @intCast(open_file.offset / raw_entry_size);
    var out_count: usize = 0;

    while (dir_index < zodfs.DIRECTORY_ENTRY_COUNT and out_count < dest.len) : (dir_index += 1) {
        open_file.offset = @intCast((dir_index + 1) * raw_entry_size);
        const raw_entry = try open_file.disk_fs.readDirEntry(open_file.inode, dir_index);
        if (raw_entry.kind == .Free) continue;
        const inode = try root_fs.getInode(raw_entry.inode_index);
        defer root_fs.drop(inode);
        const inode_stat = try open_file.disk_fs.statInode(inode);
        dest[out_count] = .{
            .inode = raw_entry.inode_index,
            .size = inode_stat.size,
            .kind = inode_stat.kind,
            .name_len = raw_entry.name_len,
            .name = raw_entry.name,
        };
        out_count += 1;
    }
    return out_count;
}

fn popLastPathComponent(path: []u8, len: *usize) void {
    if (len.* <= 1) {
        len.* = 1;
        return;
    }

    var i = len.* - 1;
    while (i > 0 and path[i] != '/') : (i -= 1) {}
    len.* = if (i == 0) 1 else i;
}

/// Canonicalizes `path` against `cwd`, collapsing repeated slashes and `.` / `..`.
pub fn canonicalizePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) FsError![]u8 {
    if (path.len == 0) return error.InvalidName;
    if (cwd.len == 0 or cwd[0] != '/') return error.InvalidName;

    const base_len = if (path[0] == '/') 1 else cwd.len + @intFromBool(!std.mem.eql(u8, cwd, "/"));
    var normalized = try allocator.alloc(u8, base_len + path.len);
    var out_len: usize = 0;

    if (path[0] == '/') {
        normalized[0] = '/';
        out_len = 1;
    } else {
        @memcpy(normalized[0..cwd.len], cwd);
        out_len = cwd.len;
    }

    var cursor: usize = 0;
    while (cursor < path.len) {
        while (cursor < path.len and path[cursor] == '/') : (cursor += 1) {}
        if (cursor == path.len) break;

        const component_start = cursor;
        while (cursor < path.len and path[cursor] != '/') : (cursor += 1) {}
        const component = path[component_start..cursor];

        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            popLastPathComponent(normalized, &out_len);
            continue;
        }

        if (out_len != 1) {
            normalized[out_len] = '/';
            out_len += 1;
        }
        @memcpy(normalized[out_len .. out_len + component.len], component);
        out_len += component.len;
    }

    return allocator.realloc(normalized, out_len);
}

fn expandSymlinkPath(allocator: std.mem.Allocator, parent_path: []const u8, target_path: []const u8, suffix: []const u8) FsError![]u8 {
    if (target_path.len == 0) return error.InvalidName;

    const needs_join_slash = target_path[0] != '/' and !std.mem.eql(u8, parent_path, "/");
    const prefix_len = if (target_path[0] == '/')
        target_path.len
    else
        parent_path.len + @intFromBool(needs_join_slash) + target_path.len;
    const raw_path = try allocator.alloc(u8, prefix_len + suffix.len);
    errdefer allocator.free(raw_path);

    var cursor: usize = 0;
    if (target_path[0] == '/') {
        @memcpy(raw_path[cursor .. cursor + target_path.len], target_path);
        cursor += target_path.len;
    } else {
        @memcpy(raw_path[cursor .. cursor + parent_path.len], parent_path);
        cursor += parent_path.len;
        if (needs_join_slash) {
            raw_path[cursor] = '/';
            cursor += 1;
        }
        @memcpy(raw_path[cursor .. cursor + target_path.len], target_path);
        cursor += target_path.len;
    }
    @memcpy(raw_path[cursor .. cursor + suffix.len], suffix);

    const normalized = try canonicalizePath(allocator, "/", raw_path);
    allocator.free(raw_path);
    return normalized;
}

fn resolvePathCanonicalOwned(initial_path: []u8, options: ResolveOptions) FsError!ResolveResult {
    const allocator = kernel.getAllocator();
    var current_path = initial_path;
    var keep_path = false;
    defer if (!keep_path) allocator.free(current_path);

    if (std.mem.eql(u8, current_path, "/")) return error.InvalidName;

    var symlink_expansions: usize = 0;

    outer: while (true) {
        var current_dir = root_fs.dup(root_fs.getRootInode());
        errdefer root_fs.drop(current_dir);

        var i: usize = 1; // start after leading slash
        while (true) {
            // find next path component
            const component_start = i;
            while (i < current_path.len and current_path[i] != '/') : (i += 1) {}
            const component = current_path[component_start..i];

            // skip any trailing slashes to find the start of the next component
            var next_component_start = i;
            while (next_component_start < current_path.len and current_path[next_component_start] == '/') : (next_component_start += 1) {}
            const is_final = next_component_start >= current_path.len;

            // check for component in current directory
            const found = try root_fs.findDirEntryAndIndex(current_dir, component);
            if (found == null) {
                if (is_final and options.allow_missing_final) {
                    keep_path = true;
                    root_fs.drop(current_dir);
                    return .{ .missing_final = current_path };
                }
                return error.FileNotFound;
            }
            const index, const entry = found.?;

            // follow symlink if present and allowed by options
            if (entry.kind == .Symlink and (options.follow_final or !is_final)) {
                if (symlink_expansions == MAX_SYMLINK_EXPANSIONS) return error.TooManySymlinks;

                const symlink_inode = try root_fs.getInode(entry.inode_index);
                defer root_fs.drop(symlink_inode);

                const target_path = try readInodeContents(&root_fs, allocator, symlink_inode);
                defer allocator.free(target_path);

                const parent_path = if (component_start == 1) "/" else current_path[0 .. component_start - 1];
                const expanded = try expandSymlinkPath(allocator, parent_path, target_path, current_path[i..]);
                allocator.free(current_path);
                current_path = expanded;
                symlink_expansions += 1;
                root_fs.drop(current_dir);
                continue :outer;
            }

            // if we have found the final component, return it
            if (is_final) {
                return .{ .found = .{
                    .parent_inode = current_dir,
                    .index = index,
                    .entry = entry,
                } };
            }

            // otherwise, keep walking the path; need a directory to continue
            if (entry.kind != .Directory) return error.FileNotFound;

            const next_dir = try root_fs.getInode(entry.inode_index);
            if (next_dir.kind != .Directory) {
                root_fs.drop(next_dir);
                return error.Corrupt;
            }

            root_fs.drop(current_dir);
            current_dir = next_dir;
            i = next_component_start;
        }
    }
}

/// Resolves a path to an inode, optionally following a final symlink. The returned inode must be dropped by the caller.
fn resolvePathInodeAt(cwd: []const u8, path: []const u8, follow_final: bool) FsError!*zodfs.DiskInode {
    if (path.len == 0) return error.InvalidName;
    const canonical = try canonicalizePath(kernel.getAllocator(), cwd, path);
    return resolvePathInodeCanonicalOwned(canonical, follow_final);
}

fn resolvePathInodeCanonicalOwned(canonical: []u8, follow_final: bool) FsError!*zodfs.DiskInode {
    if (std.mem.eql(u8, canonical, "/")) {
        kernel.getAllocator().free(canonical);
        return root_fs.dup(root_fs.getRootInode());
    }

    const resolved = switch (try resolvePathCanonicalOwned(canonical, .{ .follow_final = follow_final })) {
        .found => |entry| entry,
        .missing_final => unreachable,
    };
    defer root_fs.drop(resolved.parent_inode);
    return try root_fs.getInode(resolved.entry.inode_index);
}

fn resolvePathInodeCanonical(path: []const u8, follow_final: bool) FsError!*zodfs.DiskInode {
    return resolvePathInodeCanonicalOwned(try kernel.getAllocator().dupe(u8, path), follow_final);
}

fn resolveParentDirectoryCanonical(path: []const u8) FsError!*zodfs.DiskInode {
    const split = splitPath(path);
    const parent_path = if (split.dir.len == 0) "/" else split.dir;
    const parent_inode = try resolvePathInodeCanonical(parent_path, true);
    errdefer root_fs.drop(parent_inode);
    if (parent_inode.kind != .Directory) return error.NotADirectory;
    return parent_inode;
}

/// Resolves `path` against `cwd`, ensuring it names a directory, and returns the canonical path.
pub fn changeDirectory(cwd: []const u8, path: []const u8) FsError![]u8 {
    const allocator = kernel.getAllocator();
    const canonical = try canonicalizePath(allocator, cwd, path);
    errdefer allocator.free(canonical);

    const inode = try resolvePathInodeCanonical(canonical, true);
    defer root_fs.drop(inode);
    if (inode.kind != .Directory) return error.NotADirectory;
    return canonical;
}
