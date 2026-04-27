# Module Reference

Complete listing of every source file and its role.

## Core Kernel Modules

- `kernel/stage2.zig`: minimal loader which loads the `kernel` ELF binary from the filesystem and runs it.
- `kernel/kernel.zig`: main kernel entry point: sets up GDT, interrupt handling, memory management, mounts the filesystem, and launches the kernel shell.
- `kernel/paging.zig`: page directory and page table management, recursive page directory mapping, identity mapping setup, virtual address translation.
- `kernel/pageallocator.zig`: page-level bitmap allocator for user processes and kernel structures.
- `kernel/gdt.zig`: Global Descriptor Table structures (segments, TSS, access flags).
- `kernel/idt.zig`: Interrupt Descriptor Table structures and gate types.
- `kernel/pit.zig`: Simple Programmable Interval Timer (PIT) driver.
- `kernel/acpi.zig`: ACPI table discovery and parsing (RSDP/RSDT/MADT), checksum validation, and ACPI table virtual mapping.
- `kernel/apic.zig`: Local APIC and I/O APIC initialization, MADT APIC-entry parsing, PIC disablement, and IRQ-to-vector routing.
- `kernel/cpuid.zig`: raw CPUID query helper plus vendor/basic-leaf decoding used for clock and feature inspection.
- `kernel/task.zig`: task/process management with a stack-first per-task kernel stack page, user memory regions, page directories, and file descriptor mappings.
- `kernel/interrupt_frame.zig`: standard stack frame layout used when entering the kernel.
- `kernel/taskman.zig`: fixed-size task pool (max 8 tasks) allocated at runtime, with one unmapped guard page immediately before each task and round-robin scheduling over the entry array.
- `kernel/filedesc.zig`: global open-file table plus Linux-like `open`/`read`/`write`/`close`/`lseek` descriptor semantics layered over the filesystem and console streams.
- `kernel/syscall.zig`: syscall implementation; dispatches on `int 0x80` calls from user mode.

## Console & Input/Output

- `kernel/console.zig`: high-level console output with scrolling, cursor management, hex formatting, and memory dumps.
- `kernel/serial.zig`: COM1 serial driver for debug output and exception logging to the host via Bochs.
- `kernel/vgatext.zig`: low-level VGA 80x25 text-mode driver with cell read/write, cursor control.
- `kernel/keyboard.zig`: scancode-to-keycode conversion, extended key support, modifier tracking, ASCII conversion.
- `kernel/readline.zig`: line editing with cursor navigation, character insertion/deletion, line clearing.

## Storage & Filesystem

- `kernel/block_device.zig`: vtable-based block device abstraction. Block size is fixed at 512 bytes.
- `kernel/fs.zig`: inode-based filesystem implementation using block-bitmap allocation. Uses `BlockDevice` abstraction.
- `kernel/elf32.zig`: ELF32 binary format structures (headers, program headers), segment type/flag constants, image extent computation.
- `kernel/ide.zig`: IDE/ATA disk controller with LBA28 addressing, sector-level I/O. Also provides `IdeBlockDevice`, a concrete `BlockDevice` implementation backed by an ATA drive.
- `kernel/io.zig`: low-level port I/O helpers (inb, inw, outb, outw).

## Assembly & Low-Level

- `boot.asm`: boot sector and stage-2 loader.
- `interrupts.asm`: low-level exception/IRQ entry stubs that dispatch through `kernel.interrupt_dispatch()`.

## Shell & Applications

- `kernel/app_keylog.zig`: the keylog app state and implementation for real-time keyboard debugging.
- `kernel/app_memmap.zig`: full-screen interactive ASCII viewer for the page directory and page tables.
- `kernel/shell.zig`: command loop and table-driven shell command dispatch (`help`, `ls`, `cat`, `write`, `rm`, `mv`, `cpuid`, `serial`, `run`, `multirun`, `mkfs`, `dumpmem`, `memmap`, `memstat`, `taskswitch`, `keylog`, `shutdown`, `break`). At boot it also executes commands from an optional `autoexec` file in the filesystem before entering the interactive prompt.

## Host Tools

- `flatten_elf.zig`: converts the linked ELF stage-2 image into a flat binary plus metadata.
- `file_block_device.zig`: host-side `BlockDevice` implementation backed by a `std.fs.File`. Provides the storage layer for `extract_fs.zig` and `compile_fs.zig` so they can drive `kernel/fs.zig` directly.
- `extract_fs.zig`: host tool that mounts an existing filesystem image (via `fs.FileSystem.mount()`) and extracts all files to a directory.
- `compile_fs.zig`: host tool that formats a fresh filesystem image (via `fs.FileSystem.mountOrFormat()`) and writes a directory of input files into it using `fs.FileSystem.writeFile()`.

## Userspace

- `userspace/hello.zig`: hello-world/yield smoke-test binary.
- `userspace/fib.zig`: CPU-bound Fibonacci demo that prints `pid`-tagged results for a short sequence.
- `userspace/fs_stress.zig`: filesystem stress test that keeps two file descriptors open, alternates writes, and validates `lseek` semantics.
- `userspace/allocator.zig`: brk-backed `std.mem.Allocator` implementation with free-list reuse for normal Zig heap allocations.
- `userspace/alloc_stress.zig`: heap allocator stress test covering allocate/free/realloc behavior.
- `userspace/sys.zig`, `userspace.ld`: shared syscall ABI helpers, linker script, and startup entry point `_start` which passes command-line arguments to `main`.

## Build Configuration

- `stage2.ld`, `userspace.ld`, `kernel.ld`: linker scripts for stage-2, userspace, and the kernel respectively.
- `SConstruct`: SCons build and run entrypoints.
- `build/`: generated objects, binaries, emulator config/output, and `image.img`.
- Bochs serial output is captured to `build/serial.txt` via the generated `build/bochsrc.txt`.

## Build Pipeline Artifacts

- `build/stage2.elf`: linked from `kernel/stage2.zig` and `interrupts.asm`.
- `build/stage2.bin`: flattened from `build/stage2.elf` by `flatten_elf.zig`.
- `build/kernel.elf`: the kernel, linked from `kernel/kernel.zig` with `kernel.ld` at `0xC0010000`; copied into the filesystem image as `kernel`.
- `build/hello.elf`: linked from `userspace/hello.zig` and copied into the filesystem image as `hello`.
- `build/fib.elf`: linked from `userspace/fib.zig` and copied into the filesystem image as `fib`.
- `build/fs_stress.elf`: linked from `userspace/fs_stress.zig` and copied into the filesystem image as `fs_stress`.
- `build/alloc_stress.elf`: linked from `userspace/alloc_stress.zig` and copied into the filesystem image as `alloc_stress`.
- `build/fsimage.img`: filesystem image compiled from `build/fsimage/` by `compile_fs.zig`.
- `build/image.img`: final disk image combining boot sector, stage-2 loader, and filesystem.
