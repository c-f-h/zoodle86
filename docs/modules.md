# Module Reference

Complete listing of every source file and its role.

## Core Kernel Modules

- `common/abi.zig`: shared syscall ABI definitions imported by both kernel and userspace, including syscall numbers, argv/path slice descriptors, stat metadata, fixed-size directory-entry records for `getdents`, spawn fd-remap structs, framebuffer metadata records, and the compact key-event layout.
- `kernel/stage2.zig`: protected-mode half of the minimal stage-2 loader; sets up paging, mounts the filesystem through a loader-only read path, loads the `kernel` ELF binary, and runs it.
- `kernel/kernel.zig`: main kernel entry point: sets up GDT, interrupt handling, memory management, mounts the filesystem, and launches the kernel shell.
- `kernel/gfx/framebuf.zig`: boot framebuffer support; validates stage-2 VBE metadata, maps the linear framebuffer, exposes low-level pixel/fill/text helpers for graphics-mode rendering, and provides a `/dev/fb0` character device for raw byte access.
- `kernel/gfx/window.zig`: instantiable framed console window (`Window` struct): computes window geometry from font and available pixel dimensions, allocates and manages the shadow pixel buffer from the kernel allocator, draws the window chrome (border, title bar), and blits shadow-buffer regions to the framebuffer. Module-level `drawBackground()` fills the full-screen desktop background.
- `kernel/gfx/vconsole.zig`: instantiable framebuffer-backed virtual-console renderer (`VConsole` struct): maps VGA-style character cells through a PSF font and colour palette into the shadow buffer of its `Window`, exposes the full render/scroll/cursor public API consumed by `console.zig`. Multiple independent `VConsole` instances can be live simultaneously for side-by-side console panels.
- `kernel/gfx/psf.zig`: PSF parsing and PSF1 metadata types shared by framebuffer-backed text rendering.
- `kernel/gfx/font8x8.zig`: embedded public-domain 8x8 bitmap fallback wrapped as a PSF1 image for framebuffer text rendering.
- `kernel/allocator.zig`: page-backed kernel heap allocator with power-of-two small-object classes, free-list reuse, a fixed 8 MiB virtual arena, and direct unmapping of large page-backed allocations on free.
- `kernel/paging.zig`: page directory and page table management, recursive page directory mapping, identity mapping setup, virtual address translation.
- `kernel/pageallocator.zig`: page-level bitmap allocator for user processes and kernel structures.
- `kernel/gdt.zig`: Global Descriptor Table structures (segments, TSS, access flags).
- `kernel/idt.zig`: Interrupt Descriptor Table structures and gate types.
- `kernel/pit.zig`: Simple Programmable Interval Timer (PIT) driver.
- `kernel/kprof.zig`: kernel timer-tick profiler that samples interrupted EIP values into page-backed buffers and emits a serial histogram on stop.
- `kernel/acpi.zig`: ACPI table discovery and parsing (RSDP/RSDT/MADT), checksum validation, and ACPI table virtual mapping.
- `kernel/apic.zig`: Local APIC and I/O APIC initialization, MADT APIC-entry parsing, PIC disablement, and IRQ-to-vector routing.
- `kernel/cpuid.zig`: raw CPUID query helper plus vendor/basic-leaf decoding used for clock and feature inspection.
- `kernel/pci.zig`: PCI config-space access and bus enumeration, including multi-host-controller root scanning and PCI-to-PCI bridge traversal.
- `kernel/task.zig`: task/process management with a stack-first per-task kernel stack page, seeded user/kernel resume frames, user memory regions, page directories, file descriptor mappings, and an optional `stdout_console` pointer so processes can be routed to a specific `Console` instance (inherited by spawned children).
- `kernel/interrupt_frame.zig`: stack frame layouts for both normalized user interrupt returns and saved kernel-yield resume points.
- `kernel/taskman.zig`: fixed-size task pool (max 8 tasks) allocated at runtime, with one unmapped guard page immediately before each task and round-robin scheduling over the entry array.
- `kernel/waitqueue.zig`: intrusive singly-linked WaitQueue; tasks blocked on an event are added as heap-allocated nodes and freed when woken via `wakeOne`/`wakeAll`.
- `kernel/filedesc.zig`: global open-file table plus Linux-like `open`/`read`/`write`/`close`/`lseek`/`moveFile` descriptor semantics layered over filesystem files, generic character devices, and pipe endpoints.
- `kernel/tty.zig`: console-backed canonical tty devices with cooked line input, echo/backspace handling, and an embedded `CharDevice` interface for fd I/O.
- `kernel/ansi.zig`: decodes ANSI escape sequences and translates them into console commands.
- `kernel/pipe.zig`: in-memory pipe objects with reader/writer counts and ring-buffer-backed byte transport between file descriptors.
- `kernel/ringbuf.zig`: fixed-capacity byte ring buffer used by the pipe implementation.
- `kernel/syscall.zig`: syscall implementation; dispatches on `int 0x80` calls from user mode.

## Console & Input/Output

- `kernel/console.zig`: instantiable high-level console (`Console` struct) with scrolling, cursor management, hex formatting, memory dumps, a RAM-backed bootstrap buffer for graphics mode, and backend switching between VGA text mode and framebuffer text rendering. Module-level wrapper functions (`console.puts()`, etc.) delegate to the `console.primary` instance so existing callers are undisturbed. Each `Console` holds an optional `vconsole_instance` pointer so multiple independent consoles can render to separate `VConsole`/`Window` panel pairs on the framebuffer.
- `kernel/serial.zig`: COM1 serial driver for debug output and exception logging to the host via Bochs.
- `kernel/vgatext.zig`: low-level VGA 80x25 text-mode driver with cell read/write and hardware cursor control for the text-mode console backend.
- `kernel/keyboard.zig`: scancode-to-keycode conversion, extended key support, modifier tracking, ASCII conversion.
- `kernel/readline.zig`: line editing with cursor navigation, character insertion/deletion, line clearing.

## Storage & Filesystem

- `kernel/block_device.zig`: vtable-based block device abstraction. Block size is fixed at 512 bytes.
- `kernel/char_device.zig`: vtable-based character-device abstraction carrying device IDs plus generic `read`/`write`/`ioctl`/`stat` operations, including optional seekable byte-offset support.
- `kernel/fs/vfs.zig`: virtual filesystem layer providing a unified interface to filesystem operations. Mounts the root filesystem on IDE and forwards operations to the underlying filesystem implementation. Exports public API for path operations, file I/O, directory manipulation, and special-file handling without exposing filesystem-specific details.
- `kernel/fs/zodfs.zig`: inode-based filesystem implementation using block-bitmap allocation. Uses `BlockDevice` abstraction. Implements the ZOD2 format with superblock, block bitmap, inode table, and data region.
- `kernel/elf32.zig`: ELF32 binary format structures (headers, program headers), segment type/flag constants, image extent computation.
- `kernel/ide.zig`: IDE/ATA disk controller with LBA28 addressing, sector-level I/O. Also provides `IdeBlockDevice`, a concrete `BlockDevice` implementation backed by an ATA drive.
- `kernel/io.zig`: low-level port I/O helpers (inb, inw, outb, outw).

## Assembly & Low-Level

- `boot.asm`: real-mode boot sector; gathers the E820 map, loads the flat stage-2 payload, and jumps to its entry point.
- `kernel/stage2_init.asm`: real-mode stage-2 bootstrap; queries VBE modes, switches to the best linear-framebuffer mode, exports boot video metadata, enables A20, enters protected mode, and jumps into `kernel/stage2.zig`.
- `interrupts.asm`: low-level exception/IRQ entry stubs plus the `kernel_yield_trampoline` assembly scheduler bridge that dispatch through `kernel.interrupt_dispatch()` and resume tasks.

## Shell & Applications

- `kernel/app_keylog.zig`: the keylog app state and implementation for real-time keyboard debugging.
- `kernel/app_memmap.zig`: full-screen interactive ASCII viewer for the page directory and page tables.
- `kernel/shell.zig`: command loop and table-driven shell command dispatch (`help`, `write`, `cpuid`, `serial`, `run`, `multirun`, `dumpmem`, `memmap`, `memstat`, `taskswitch`, `ticks`, `profile`, `fontbench`, `keylog`, `shutdown`, `break`). At boot it executes commands from an optional `autoexec` file in the filesystem before entering the interactive prompt.

## Host Tools

- `flatten_elf.zig`: converts the linked ELF stage-2 image into a flat binary plus metadata.
- `file_block_device.zig`: host-side `BlockDevice` implementation backed by a `std.fs.File`. Provides the storage layer for `extract_fs.zig` and `compile_fs.zig` so they can drive `zodfs.zig` directly.
- `extract_fs.zig`: host tool that mounts an existing filesystem image (via `fs.FileSystem.mount()`), extracts regular files/directories to a host directory, and skips special inodes it cannot materialize on the host.
- `compile_fs.zig`: host tool that formats a fresh filesystem image (via `fs.FileSystem.mountOrFormat()`), writes a directory tree of input files into it, and consumes optional root `_special`/`_links` manifests to create device nodes and hard links.

## Userspace

- `userspace/hello.zig`: hello-world/yield smoke-test binary.
- `userspace/busybox.zig`: multi-call binary that dispatches to `cat`, `cp`, `echo`, `find`, `ln`, `ls`, `mkdir`, `mv`, `rm`, `rmdir`, or `stat` based on the basename of `argv[0]`. Installed as `/bin/busybox` and hard-linked to respective tool names.
- `userspace/fib.zig`: CPU-bound Fibonacci demo that prints `pid`-tagged results for a short sequence.
- `userspace/test_fs.zig`: filesystem and descriptor stress test that keeps two file descriptors open, alternates writes, and validates `lseek`, sparse write, `ftruncate`, `getdents`/`readdir`, and pipe semantics.
- `userspace/allocator.zig`: brk-backed `std.mem.Allocator` implementation with free-list reuse for normal Zig heap allocations.
- `userspace/test_alloc.zig`: heap allocator stress test covering allocate/free/realloc behavior.
- `userspace/shell.zig`: interactive userspace shell built on `userspace/readline.zig`; resolves and runs commands from `/bin`, and supports multi-stage pipelines plus left-to-right `<`, `>`, and `>>` redirections.
- `userspace/fbdemo.zig`: userspace framebuffer demo that opens `/dev/fb0`, queries metadata via ioctl, snapshots the device contents, draws a small colour-pattern test image through fd I/O, waits for a keypress, and restores the original pixels.
- `userspace/sys.zig`, `userspace.ld`: userspace syscall wrappers, linker script, and startup entry point `_start` which passes command-line arguments to `main`. Imports the shared ABI definitions from `common/abi.zig`, including `FrameBufInfo`.

## Build Configuration

- `build.zig`: Zig kernel-only build entrypoint for editor tooling and ad hoc builds; assembles `kernel/interrupts.asm`, links `build/kernel.full.elf`, and strips `build/kernel.elf`.
- `stage2.ld`, `userspace.ld`, `kernel.ld`: linker scripts for stage-2, userspace, and the kernel respectively.
- `SConstruct`: SCons build and run entrypoints. Builds `build/fsimage/` from kernel/userspace outputs plus the directory tree copied from `static/`, regenerates `/dev`, and synthesizes `_special`/`_links` manifests for generated device nodes and hard links.
- `build/`: generated objects, binaries, emulator config/output, and `image.img`.
- Bochs serial output is captured to `build/serial.txt` via the generated `build/bochsrc.txt`.

## Build Pipeline Artifacts

- `build/stage2.elf`: linked from `kernel/stage2.zig` and `kernel/stage2_init.asm`.
- `build/stage2.bin`: flattened from `build/stage2.elf` by `flatten_elf.zig`.
- `build/kernel.elf`: the kernel, linked from `kernel/kernel.zig` with `kernel.ld` at `0xC0010000`; copied into the filesystem image as `kernel`.
- The following userspace programs are compiled and copied into the image as `/bin/<basename>`, which is on the shell path:
    - `userspace/hello.zig`
    - `userspace/busybox.zig` → `/bin/busybox` plus hard links `/bin/cat`, `/bin/cp`, `/bin/echo`, `/bin/find`, `/bin/ln`, `/bin/ls`, `/bin/mkdir`, `/bin/mv`, `/bin/rm`, `/bin/rmdir`, `/bin/stat`
    - `userspace/fib.zig`
    - `userspace/test_fs.zig`
    - `userspace/test_alloc.zig`
    - `userspace/fbdemo.zig`
    - `userspace/shell.zig`
- `build/fsimage.img`: filesystem image compiled from `build/fsimage/` by `compile_fs.zig`, including the directory tree copied from `static/`.
- `build/image.img`: final disk image combining boot sector, stage-2 loader, and filesystem.
