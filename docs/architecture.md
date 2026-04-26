# Architecture

## Boot & Real-Mode Setup

The boot sector collects the BIOS E820 memory map at `0x7E00`, loads a flat stage-2 image at `0x8000`, and switches to 32-bit protected mode before jumping into Zig code. On hard-disk boots it uses BIOS extended LBA reads for stage 2; the older CHS path is only used for floppy-style boots.

## Kernel Loading

During boot, `stage2` reads the `"kernel"` ELF file from the filesystem, parses its program headers, allocates physical pages for each PT_LOAD segment at the virtual addresses specified by the ELF, copies the segment data, and jumps to the entry point directly in kernel mode (ring 0). The kernel is loaded as a single monolithic ELF binary and execution continues from its entry point. This is distinct from userspace ELF loading, which is handled separately by the kernel's syscall handler when user processes are spawned.

## Virtual Memory Layout

The kernel uses a higher-half design with paging enabled. The first 1 MB of physical RAM is identity-mapped at both 0x0 (for boot compatibility) and 0xC0000000+ (for kernel code/data). A recursive page directory entry at PD[1023] → PD allows the kernel to calculate physical addresses and manipulate page tables without additional data structures. User-mode code and data execute in the lower half (0x0–0x3FFFFFFF) with dedicated per-process page directories.

| Virtual Address | Size | Purpose |
|---|---|---|
| 0x0000_0000 - 0x0010_0000 | 1 MB | Identity-mapped low memory (boot, real-mode data) |
| 0x0040_0000 - 0x1000_0000 | ~252 MB | User-mode text (code) |
| 0x1000_0000 - 0x4000_0000 | ~768 MB | User-mode rodata/data/heap (per-process) |
| 0x4000_0000 - 0x7000_0000 | ~768 MB | Unused |
| 0x7000_0000 - 0x8000_0000 | 256 MB | User-mode stack reservation (grows downward from 0x80000000) |
| 0x8000_0000 - 0xC000_0000 | 1 GB | Unused |
| 0xC000_8000 - 0xC020_0000 | ~2 MB | Kernel code and data (stage-2) |
| 0xC030_0000 - 0xC040_0000 | 1 MB | Kernel module (`kernel.elf`), loaded from FS at boot |
| 0xE000_0000 - 0xE040_0000 | 4 MB | Kernel heap (fixed-buffer allocator) |
| 0xE040_0000 - 0xE050_0000 | 1 MB | Runtime-allocated task pool (`TaskmanEntry` array with one guard page per task) |
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
