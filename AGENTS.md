# `zoodle86` - Project Overview

This is a tiny x86 boot loader/OS kernel (32-bit protected mode) toy project in Zig.

## Project Structure & Module Organization

This repository builds a bootable x86 disk image with a tiny freestanding kernel and a small command-driven text UI.

### Core Kernel Modules
- `kernel/kernel.zig`: kernel entrypoint, E820 memory discovery, GDT/IDT setup, paging initialization, memory allocator, filesystem mounting, shell startup, exception handling, and syscall dispatcher.
- `kernel/paging.zig`: page directory and page table management, recursive page directory mapping, identity mapping setup, virtual address translation.
- `kernel/pageallocator.zig`: page-level allocator for user processes and kernel structures.
- `kernel/gdt.zig`: Global Descriptor Table structures (segments, TSS, access flags).
- `kernel/idt.zig`: Interrupt Descriptor Table structures and gate types.
- `kernel/task.zig`: task/process management with per-task GDT entries, kernel stacks, user memory regions, and page directories.

### Console & Input/Output
- `kernel/console.zig`: high-level console output with scrolling, cursor management, hex formatting, and memory dumps.
- `kernel/vgatext.zig`: low-level VGA 80x25 text-mode driver with cell read/write, cursor control.
- `kernel/keyboard.zig`: scancode-to-keycode conversion, extended key support, modifier tracking, ASCII conversion.
- `kernel/readline.zig`: line editing with cursor navigation, character insertion/deletion, line clearing.

### Storage & Filesystem
- `kernel/fs.zig`: extent-based filesystem with mount, format, read, write, delete, and rename operations.
- `kernel/fs_defs.zig`: filesystem constants, superblock and directory entry structures, fixed layout definitions.
- `kernel/elf32.zig`: ELF32 binary format structures (headers, program headers), segment type/flag constants, image extent computation.
- `kernel/ide.zig`: IDE/ATA disk controller with LBA28 addressing, sector-level I/O.
- `kernel/io.zig`: low-level port I/O helpers (inb, inw, outb, outw).

### Assembly & Low-Level
- `boot.asm`: boot sector and stage-2 loader.
- `interrupts.asm`: low-level exception/IRQ entry points, scancode buffering, interrupt statistics.

### Applications & Tools
- `kernel/app_keylog.zig`: the keylog app state and implementation for real-time keyboard debugging.
- `kernel/shell.zig`: command loop and table-driven shell command dispatch (help, ls, cat, write, rm, mv, run, mkfs, dumpmem, keylog, shutdown, break).
- `flatten_elf.zig`: converts the linked ELF stage-2 image into a flat binary plus metadata.
- `extract_fs.zig`, `compile_fs.zig`: tools for extracting and compiling filesystem images.
- `userspace.zig`, `userspace.ld`: freestanding userspace ELF binary and linker script.

### Build Configuration
- `stage2.ld`, `userspace.ld`: linker scripts for stage-2 and userspace.
- `SConstruct`: SCons build and run entrypoints.
- `build/`: generated objects, binaries, emulator config/output, and `image.img`.

## Build, Test, and Development Commands

- `scons`: build the boot sector, stage-2 payload, userspace ELF, filesystem image, and final `build/image.img`.
- `scons run`: build and run the image in Bochs.
- `scons debug`: build and run the image in Bochs with the debugger attached.
- `scons qemu`: build and run the image in QEMU.

Build pipeline overview:
- `build/stage2.elf`: linked from `kernel/kernel.zig` and `interrupts.asm`.
- `build/stage2.bin`: flattened from `build/stage2.elf` by `flatten_elf.zig`.
- `build/userspace.elf`: linked from `userspace.zig` and copied into the filesystem image.
- `build/fsimage.img`: filesystem image compiled from `build/fsimage/` by `compile_fs.zig`.
- `build/image.img`: final disk image combining boot sector, stage-2 loader, and filesystem.

There is no separate unit-test suite yet. A successful build is the current baseline check.

## Architecture Notes

**Boot & Real-Mode Setup**: The boot sector collects the BIOS E820 memory map at `0x7E00`, loads a flat stage-2 image at `0x8000`, and switches to 32-bit protected mode before jumping into Zig code. On hard-disk boots it uses BIOS extended LBA reads for stage 2; the older CHS path is only used for floppy-style boots.

**Virtual Memory Layout**: The kernel uses a higher-half design with paging enabled. The first 1 MB of physical RAM is identity-mapped at both 0x0 (for boot compatibility) and 0xC0000000+ (for kernel code/data). A recursive page directory entry at PD[1023] → PD allows the kernel to calculate physical addresses and manipulate page tables without additional data structures. User-mode code and data execute in the lower half (0x0–0x3FFFFFFF) with dedicated per-process page directories.

| Virtual Address | Size | Purpose |
|---|---|---|
| 0x00000000 - 0x00100000 | 1 MB | Identity-mapped low memory (boot, real-mode data) |
| 0x00400000 - 0x10000000 | ~252 MB | User-mode text (code) |
| 0x10000000 - 0x40000000 | ~768 MB | User-mode rodata/data/stack/heap (per-process) |
| 0x40000000 - 0xC0000000 | 2 GB | Unused |
| 0xC0008000 - 0xC0200000 | ~2 MB | Kernel code and data (stage-2) |
| 0xE0000000 - 0xE0400000 | 4 MB | Kernel heap (fixed-buffer allocator) |
| 0xFFC00000 - 0xFFFFF000 | ~4 MB | Recursively mapped page tables (PD[1023] entry points to PD) |
| 0xFFFFF000 - 0x100000000 | 4 KB | Recursively mapped page directory |

**Paging Implementation**: The kernel initially maps only the first 1 MB of physical RAM (both at 0x0 and 0xC0000000 for higher-half transition). Virtual-to-physical address translation uses recursive mapping tricks. Both page tables and user memory are allocated on-demand via the page allocator.

**Protected Mode & Segmentation**: The kernel initializes a GDT with kernel code/data segments (DPL 0), user code/data segments (DPL 3), and per-task Task State Segment (TSS) descriptors for ring transitions. Interrupts and exceptions load a 256-entry IDT with gate types for task gates and 16/32-bit interrupt/trap gates.

**Exception Handling**: The kernel handles multiple exception types including Page Fault (0x0E), General Protection Fault (0x0D), and others. User-mode faults (such as page faults) terminate the offending task without crashing the kernel.

**Memory Management**: The kernel allocates a 4 MB kernel data region (1024 pages at 0xE000_0000) as a fixed-buffer allocator for all kernel-mode dynamic allocations. User processes are allocated private memory slices from the largest contiguous usable RAM region reported by E820 (typically starting at 1 MB) and have independent stack/heap boundaries. Each task has its own 4 KB kernel stack (power-of-2 aligned), with the current task pointer stored at the stack base.

**Task/Process Management**: Each `Task` struct manages a private user-memory slice, kernel stack, page directory, and GDT. User-mode execution uses flat-addressed segments backed by the user memory region. The kernel can load and execute freestanding ELF binaries (ELF32 format) by extracting code and data segments, computing heap and stack boundaries (page-aligned above the program image), and mapping those segments into GDT selectors 0x18 and 0x20 (user code/data, DPL=3).

**Syscall ABI**: User-mode programs support syscalls via `int 0x80` with syscall number in `eax` and arguments in `ebx`, `ecx`, `edx`. Currently implemented syscalls: `write` (1) for console output and `exit` (60) to terminate the task. The kernel's `syscall_dispatch()` routes calls back to appropriate handlers.

**Disk Image Layout**: Sector 0 is the boot sector. Sectors 1–63 are reserved for the stage-2 loader. The custom filesystem begins at sector 64. The filesystem uses a one-sector superblock, an eight-sector flat root directory (64 entries × 64 bytes), and append-only contiguous file extents. Directory slot 0 is reserved for a future bootable kernel file. Files are stored in contiguous extents with metadata (name, state, extent location, timestamps) tracked in the root directory.

**Filesystem**: The ZOD1 filesystem is fixed-layout with extent-based allocation. Files support read, write (create/overwrite), delete, and rename operations. Directory entries track file state (FREE, FILE, RESERVED, DELETED), name (16 bytes max), extent info, and timestamps. Maximum 16-byte filenames and 64 directory entries.

**IDE & Storage**: The kernel uses LBA28 addressing (maximum 128 GB disks) and communicates with the primary IDE bus (I/O base 0x1F0, control base 0x3F6). Sector-level I/O with status polling and error handling (timeout, device fault, controller error).

## Style Guidelines

- Every public Zig function should have at least a one-line doc comment explaining its function.
- Whenever the design of the project changes, keep AGENTS.md up to date!
