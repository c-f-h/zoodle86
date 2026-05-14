# Storage & Filesystem

## Virtual Filesystem Layer

The kernel provides a unified virtual filesystem (VFS) layer via `kernel/fs/vfs.zig` that abstracts the underlying filesystem implementation. The VFS layer:
- Manages mounting of the root filesystem at boot time on the IDE master drive
- Provides a public API for filesystem operations (open, read, write, stat, mkdir, etc.) without exposing filesystem-specific details
- Forwards operations to the underlying `zodfs.FileSystem` instance
- Handles special device files (character and block devices) via the `filedesc` layer
- Allows path-based operations to work uniformly across all file types

This abstraction makes it possible to support multiple filesystem implementations or replace the current implementation in the future without changing kernel and userspace code that depends on filesystem operations.

## Disk Image Layout

Sector 0 is the boot sector. Sectors 1–16 are reserved for the stage-2 loader (kernel/stage2.zig). The custom filesystem begins at sector 17. The filesystem layout is a one-sector superblock followed by a block bitmap, inode table, and data region. The root directory lives in the data region as a fixed-size inode-backed directory file containing 64 entries.

## ZOD2 Filesystem

The ZOD2 filesystem is inode-based and optimized for tiny disk images. It keeps a block bitmap plus a compact inode table (with no separate inode bitmap), uses 8 direct block pointers plus one single-indirect and one double-indirect pointer per inode, and stores the root directory as a fixed-size inode-backed directory file containing 64 entries with 16-byte maximum names. Filesystem images support hierarchical directories built from inode-backed directory entries. Open descriptors track inode identity, and `unlink` rejects files that are currently open rather than emulating delete-on-last-close semantics.

The build pipeline assembles the filesystem image from `build/fsimage/`, which is populated with the stripped kernel module (`build/kernel.elf`), userspace binaries in the `/bin` directory, optional `autoexec`, and the full file and directory tree from `static/` with relative paths preserved. Before compiling the image, SCons rebuilds `/dev` from scratch and writes root-level `_special` and `_links` manifests that `compile_fs.zig` consumes to create device nodes and hard links. The generated special files currently include `/dev/hda`, `/dev/hdb`, `/dev/tty0`, `/dev/tty1`, and `/dev/fb0`.

`scons` also keeps `build/kernel.full.elf` and writes an annotated disassembly to `build/kernel.disasm` before stripping the runtime copy, while `zig build` provides a kernel-only helper that emits the full and stripped kernel ELFs without the disk-image pipeline.

## IDE & Storage

The kernel uses LBA28 addressing (maximum 128 GB disks) and communicates with the primary IDE bus (I/O base 0x1F0, control base 0x3F6). Sector-level I/O with status polling and error handling (timeout, device fault, controller error).
