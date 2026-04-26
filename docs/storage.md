# Storage & Filesystem

## Disk Image Layout

Sector 0 is the boot sector. Sectors 1–16 are reserved for the stage-2 loader (kernel/stage2.zig). The custom filesystem begins at sector 17. The filesystem layout is a one-sector superblock followed by a block bitmap, inode table, and data region. The root directory lives in the data region as a fixed-size inode-backed directory file containing 64 entries.

## ZOD2 Filesystem

The ZOD2 filesystem is inode-based and optimized for tiny disk images. It keeps a block bitmap plus a compact inode table (with no separate inode bitmap), uses 8 direct block pointers plus 2 single-indirect pointers per inode, and stores the root directory as a fixed-size inode-backed directory file containing 64 entries with 16-byte maximum names. Version 1 exposes only the root directory, but the on-disk inode and directory-entry structures are designed so hierarchical directories can be added later. Open descriptors now track inode identity rather than directory-slot identity, and `unlink` still rejects files that are currently open rather than emulating delete-on-last-close semantics.

## IDE & Storage

The kernel uses LBA28 addressing (maximum 128 GB disks) and communicates with the primary IDE bus (I/O base 0x1F0, control base 0x3F6). Sector-level I/O with status polling and error handling (timeout, device fault, controller error).
