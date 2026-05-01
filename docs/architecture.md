# Architecture

## Boot & Real-Mode Setup

The boot sector collects the BIOS E820 memory map at `0x7E00`, loads a flat stage-2 image at `0x8000`, and switches to 32-bit protected mode before jumping into Zig code. On hard-disk boots it uses BIOS extended LBA reads for stage 2; the older CHS path is only used for floppy-style boots.

## Kernel Loading

During boot, `stage2` reads the `"kernel"` ELF file from the filesystem, parses its program headers, allocates physical pages for each PT_LOAD segment at the virtual addresses specified by the ELF, copies the segment data, and jumps to the entry point directly in kernel mode (ring 0). The kernel is loaded as a single monolithic ELF binary and execution continues from its entry point. This is distinct from userspace ELF loading, which is handled separately by the kernel's syscall handler when user processes are spawned.

## Graphical subsystem

Before enabling paging, stage 2 can temporarily thunk back to real mode to scan VBE modes, switch to the best linear-framebuffer, sub-1000 rows mode it finds, and write boot video metadata at physical `0x0600` for the kernel. It also passes the physical address of the boot video metadata block so `kernel/gfx/framebuf.zig` can validate the chosen VBE mode and map the framebuffer if one is available, while `kernel/console.zig` buffers early kernel text in RAM and `kernel/gfx/vconsole.zig` later renders that framebuffer-backed text console.

In graphics mode the screen is split into two side-by-side panels. Each panel is backed by an independent `VConsole`/`Window` pair; the `Window` allocates its shadow pixel buffer from the kernel heap (`0xE000_0000` fixed-buffer allocator). The left panel hosts the primary kernel shell (`console.primary`); the right panel hosts a secondary `Console` instance whose `stdout` is bound to the `hello` process that is launched at boot before the interactive shell starts. Each panel draws a framed pane with a title bar around the largest console grid that fits the active font and half the framebuffer width. The kernel first calls `window.drawBackground()` to paint the full-screen desktop background, then calls `VConsole.drawFrame()` for each panel independently. The console grid size is therefore variable: it depends on the VBE resolution and the loaded PSF font. The kernel attempts to load `cp850-8x14.psf` from the filesystem; `font8x8.zig` provides an embedded 8×8 PSF1 fallback so the graphical console can always render text.

## Virtual Memory Layout

The kernel uses paging with 1 MB of identity mapping at both 0x0 (low memory) and 0xC0000000+ (higher half). Stage 2 runs at low memory (VA/physical 0x8000) and loads the kernel into the higher half (VA 0xC0010000, physical 0x10000). A recursive page directory entry at PD[1023] → PD allows the kernel to calculate physical addresses and manipulate page tables directly. User-mode code and data execute in the lower half (0x0–0x3FFFFFFF) with dedicated per-process page directories.

| Virtual Address | Size | Purpose |
|---|---|---|
| 0x0000_0000 - 0x0010_0000 | 1 MB | Identity-mapped low memory (boot, real-mode data, stage2) |
| 0x0040_0000 - 0x1000_0000 | ~252 MB | User-mode text (code) |
| 0x1000_0000 - 0x4000_0000 | ~768 MB | User-mode rodata/data/heap (per-process) |
| 0x4000_0000 - 0x7000_0000 | ~768 MB | Unused |
| 0x7000_0000 - 0x8000_0000 | 256 MB | User-mode stack reservation (grows downward from 0x80000000) |
| 0x8000_0000 - 0xC000_0000 | 1 GB | Unused |
| 0xC000_8000 - 0xC000_A200 | ~8 KB | Stage-2 loader (VA), physically at 0x8000 |
| 0xC001_0000 - 0xC002_0000 | 64 KB | Kernel module (`kernel.elf`), physically at 0x10000 |
| 0xC004_0000 - 0xC004_2000 | 8 KB | Bootstrap page directory + first page table (physical 0x40000-0x42000) |
| 0xD000_0000 - dynamic | dynamic | Early framebuffer mapping window used by `kernel/gfx/framebuf.zig` |
| 0xE000_0000 - 0xE040_0000 | 4 MB | Kernel heap (fixed-buffer allocator) |
| 0xE040_0000 - 0xE050_0000 | 1 MB | Runtime-allocated task pool (`TaskmanEntry` array with one guard page per task) |
| 0xE100_0000 - dynamic | up to 4 MB | Profiler sample pages (dynamically allocated by `kprof` while running) |
| 0xFC00_0000 - 0xFE00_0000 | 32 MB | Mapped ACPI tables |
| 0xFEC0_0000 - 0xFEC0_1000 | 4 KB | Memory-mapped APIC I/O (base GSI 0) |
| 0xFEE0_0000 - 0xFEE0_1000 | 4 KB | Memory-mapped Local APIC |
| 0xFFC0_0000 - 0xFFFF_F000 | ~4 MB | Recursively mapped page tables (PD[1023] entry points to PD) |
| 0xFFFF_F000 - 0xFFFF_FFFF | 4 KB | Recursively mapped page directory |

## Paging Implementation

The kernel initially maps only the first 1 MB of physical RAM (both at 0x0 and 0xC0000000 for higher-half transition). Virtual-to-physical address translation uses recursive mapping tricks. Both page tables and user memory are allocated on-demand via the page allocator.

## Memory Management

The kernel allocates a 4 MB kernel data region (1024 pages at 0xE000_0000) as a fixed-buffer allocator for all kernel-mode dynamic allocations, then allocates the fixed-size task pool at 0xE040_0000. User processes are allocated private memory slices from the largest contiguous usable RAM region reported by E820 (typically starting at 1 MB) and have independent stack/heap boundaries. Each task has a 4 KB kernel stack page as the first page of its `Task` object, with the current task pointer stored at the stack base; `taskman` leaves one unmapped guard page immediately before that stack page so kernel-stack overflow faults instead of corrupting adjacent task state. User-mode stacks live in a fixed reservation from 0x7000_0000 to 0x8000_0000 with the top page mapped initially and additional pages faulted in on demand within that window.

## Userspace Heap Allocation

Userspace can grow its heap through syscall `brk` and the shared helper `userspace/sys.zig:changeHeapSize()`. `userspace/allocator.zig` builds a reusable single-threaded `std.mem.Allocator` on top of that interface using power-of-two size classes plus free-list reuse, so userspace programs can use normal Zig heap APIs such as `alloc`, `realloc`, `free`, and `std.fmt.allocPrint()`.

## Serial Debug Output

The kernel initializes COM1 early in boot and writes exception and panic diagnostics to the serial port. Bochs is configured with `com1: enabled=1, mode=file` so this output is captured in `build/serial.txt` on the host.
