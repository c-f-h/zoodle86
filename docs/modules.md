# Module Reference

Complete listing of every source file and its role.

## Core Kernel Modules

- `common/abi.zig`: shared syscall ABI definitions imported by both kernel and userspace, including syscall numbers, argv/path slice descriptors, stat metadata, fixed-size directory-entry records for `getdents`, spawn fd-remap structs, and the compact stdin key-event layout.
- `kernel/stage2.zig`: minimal loader which loads the `kernel` ELF binary from the filesystem and runs it.
- `kernel/kernel.zig`: main kernel entry point: sets up GDT, interrupt handling, memory management, mounts the filesystem, and launches the kernel shell.
- `kernel/gfx/framebuf.zig`: boot framebuffer support; validates stage-2 VBE metadata, maps the linear framebuffer, and exposes low-level pixel, fill, and text helpers for graphics-mode rendering.
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
- `kernel/filedesc.zig`: global open-file table plus Linux-like `open`/`read`/`write`/`close`/`lseek` descriptor semantics layered over filesystem files, console streams, and pipe endpoints.
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
- `kernel/fs.zig`: inode-based filesystem implementation using block-bitmap allocation. Uses `BlockDevice` abstraction.
- `kernel/elf32.zig`: ELF32 binary format structures (headers, program headers), segment type/flag constants, image extent computation.
- `kernel/ide.zig`: IDE/ATA disk controller with LBA28 addressing, sector-level I/O. Also provides `IdeBlockDevice`, a concrete `BlockDevice` implementation backed by an ATA drive.
- `kernel/io.zig`: low-level port I/O helpers (inb, inw, outb, outw).

## Assembly & Low-Level

- `boot.asm`: boot sector and stage-2 loader.
- `kernel/stage2_video_rm.asm`: real-mode thunk used by stage 2 to query VBE modes, switch to the best linear-framebuffer mode, and export boot video metadata.
- `interrupts.asm`: low-level exception/IRQ entry stubs plus the `kernel_yield_trampoline` assembly scheduler bridge that dispatch through `kernel.interrupt_dispatch()` and resume tasks.

## Shell & Applications

- `kernel/app_keylog.zig`: the keylog app state and implementation for real-time keyboard debugging.
- `kernel/app_memmap.zig`: full-screen interactive ASCII viewer for the page directory and page tables.
- `kernel/shell.zig`: command loop and table-driven shell command dispatch (`help`, `ls`, `write`, `rm`, `mv`, `cpuid`, `serial`, `run`, `multirun`, `mkfs`, `dumpmem`, `memmap`, `memstat`, `taskswitch`, `ticks`, `profile`, `fontbench`, `keylog`, `shutdown`, `break`). The `run` command also parses basic `>` stdout redirection and `|` stdout-to-stdin pipelines. At boot it executes commands from an optional `autoexec` file in the filesystem before entering the interactive prompt.

## Host Tools

- `flatten_elf.zig`: converts the linked ELF stage-2 image into a flat binary plus metadata.
- `file_block_device.zig`: host-side `BlockDevice` implementation backed by a `std.fs.File`. Provides the storage layer for `extract_fs.zig` and `compile_fs.zig` so they can drive `kernel/fs.zig` directly.
- `extract_fs.zig`: host tool that mounts an existing filesystem image (via `fs.FileSystem.mount()`) and extracts all files to a directory.
- `compile_fs.zig`: host tool that formats a fresh filesystem image (via `fs.FileSystem.mountOrFormat()`) and writes a directory of input files into it using `fs.FileSystem.writeFile()`.

## Userspace

- `userspace/hello.zig`: hello-world/yield smoke-test binary.
- `userspace/cat.zig`: stdin-to-stdout copier and simple file-printing utility used both directly and in shell pipelines.
- `userspace/ln.zig`: small hard-link utility that calls the `link` syscall for `ln <existing> <new>`.
- `userspace/fib.zig`: CPU-bound Fibonacci demo that prints `pid`-tagged results for a short sequence.
- `userspace/fs_stress.zig`: filesystem and descriptor stress test that keeps two file descriptors open, alternates writes, and validates `lseek`, sparse write, `ftruncate`, `getdents`/`readdir`, and pipe semantics.
- `userspace/allocator.zig`: brk-backed `std.mem.Allocator` implementation with free-list reuse for normal Zig heap allocations.
- `userspace/alloc_stress.zig`: heap allocator stress test covering allocate/free/realloc behavior.
- `userspace/ls.zig`: userspace directory lister built on the fixed-size `getdents`/`readdir` syscall wrapper.
- `userspace/shell.zig`: interactive userspace shell built on `userspace/readline.zig`; resolves and runs commands from `/bin`, and supports basic redirection.
- `userspace/sys.zig`, `userspace.ld`: userspace syscall wrappers, linker script, and startup entry point `_start` which passes command-line arguments to `main`. Imports the shared ABI definitions from `common/abi.zig`.

## Build Configuration

- `build.zig`: Zig kernel-only build entrypoint for editor tooling and ad hoc builds; assembles `kernel/interrupts.asm`, links `build/kernel.full.elf`, and strips `build/kernel.elf`.
- `stage2.ld`, `userspace.ld`, `kernel.ld`: linker scripts for stage-2, userspace, and the kernel respectively.
- `SConstruct`: SCons build and run entrypoints. Builds `build/fsimage/` from kernel/userspace outputs plus the directory tree copied from `static/`.
- `build/`: generated objects, binaries, emulator config/output, and `image.img`.
- Bochs serial output is captured to `build/serial.txt` via the generated `build/bochsrc.txt`.

## Build Pipeline Artifacts

- `build/stage2.elf`: linked from `kernel/stage2.zig` and `kernel/stage2_video_rm.asm`.
- `build/stage2.bin`: flattened from `build/stage2.elf` by `flatten_elf.zig`.
- `build/kernel.elf`: the kernel, linked from `kernel/kernel.zig` with `kernel.ld` at `0xC0010000`; copied into the filesystem image as `kernel`.
- The following userspace programs are compiled and copied into the image as `/bin/<basename>`, which is on the shell path:
    - `userspace/hello.zig`
    - `userspace/cat.zig`
    - `userspace/ln.zig`
    - `userspace/fib.zig`
    - `userspace/fs_stress.zig`
    - `userspace/alloc_stress.zig`
    - `userspace/ls.zig`
    - `userspace/shell.zig`
- `build/fsimage.img`: filesystem image compiled from `build/fsimage/` by `compile_fs.zig`, including the directory tree copied from `static/`.
- `build/image.img`: final disk image combining boot sector, stage-2 loader, and filesystem.
