const fs_mod = @import("zodfs.zig");
const std = @import("std");

const FileSystem = fs_mod.FileSystem;
const DiskInode = fs_mod.DiskInode;
const DirectoryEntry = fs_mod.DirectoryEntry;
const InodeCache = fs_mod.InodeCache;
const InodeT = fs_mod.InodeT;
const FsError = fs_mod.FsError;

//////////// PATH WALKING ////////////

/// Returns a new reference to the inode for a file given by its full path.
/// NB: This does not support the full vfs feature set and is only used for the compile_fs.zig tool.
pub fn getInodeAtPath(fs: *FileSystem, path: []const u8) FsError!*DiskInode {
    if (path.len == 1 and path[0] == '/') {
        return fs.dup(fs.getRootInode());
    }
    const inode_index = try walkPathToInodeIndex(fs, fs.getRootInode(), path);
    return fs.getInode(inode_index);
}

/// Walk a full file path, starting from the given directory inode index.
/// Returns the final file's inode index or error.FileNotFound.
fn walkPathToInodeIndex(fs: *FileSystem, dir_inode: *DiskInode, path: []const u8) FsError!InodeT {
    if (path.len == 0) return fs.getInodeIndex(dir_inode);
    if (path.len == 1 and path[0] == '/') return fs_mod.ROOT_INODE_INDEX;
    const parent_inode, _, const entry = try walkPathToDirEntry(fs, dir_inode, path);
    fs.drop(parent_inode);
    return entry.inode_index;
}

/// Walk a full file path, starting from the given directory inode index.
/// Returns { parent_dir_inode, dir_entry_index, dir_entry } or error.FileNotFound.
fn walkPathToDirEntry(fs: *FileSystem, dir_inode: *DiskInode, path: []const u8) FsError!struct { *DiskInode, u32, DirectoryEntry } {
    // Invariant: current_dir always holds a temporary reference to a directory
    // used during path walking, which we need to drop when returning.
    var current_dir = fs.dup(dir_inode);
    defer fs.drop(current_dir);

    if (current_dir.kind != .Directory) return error.NotADirectory;

    var path_iter = std.mem.splitScalar(u8, path, '/');

    // TODO: proper handling of absolute vs relative paths
    // TODO: handle "." and ".." components
    while (path_iter.next()) |component| {
        if (component.len == 0) continue;

        const index, const entry = try fs.findDirEntryAndIndex(current_dir, component) orelse {
            return error.FileNotFound;
        };
        if (path_iter.peek() == null) {
            // At end of path - return the entry
            return .{ fs.dup(current_dir), index, entry };
        } else {
            // Not at end of path - must be a directory to continue traversal
            if (entry.kind != .Directory) return error.FileNotFound;
        }

        const next_dir = try fs.getDirectoryInode(entry.inode_index);
        fs.drop(current_dir);
        current_dir = next_dir;
    }
    // TODO: this is reachable if the path is empty or "/"
    @panic("walkPathToDirEntry called with invalid path");
}

//////////// FILE WRITING ////////////

/// Creates or overwrites a file in the given directory with the provided full contents.
pub fn writeFileAt(fs: *FileSystem, dir_inode: *DiskInode, name: []const u8, data: []const u8) FsError!void {
    const inode = try findDirEntryInode(fs, dir_inode, name) orelse
        try fs.createFile(dir_inode, name);
    defer fs.drop(inode);
    if (inode.kind != .Regular) return error.NotAFile;
    try fs.writeToInodeAtOffset(inode, 0, data, true);
}

pub fn findDirEntryInode(fs: *FileSystem, dir_inode: *DiskInode, name: []const u8) FsError!?*DiskInode {
    if (try fs.findDirEntryAndIndex(dir_inode, name)) |index_and_entry| {
        return fs.getInode(index_and_entry.@"1".inode_index);
    } else {
        return null;
    }
}
