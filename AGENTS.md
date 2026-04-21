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
- `kernel/task.zig`: task/process management with per-task GDT entries, kernel stacks, user memory regions, page directories, and per-task file descriptor mappings. Includes `switchTo()` for low-level context switching and `terminate()` for freeing task resources.
- `kernel/taskman.zig`: fixed-size task pool (max 8 tasks) with round-robin scheduler; `getNextActiveTask()` finds the next runnable task for cooperative scheduling.
- `kernel/filedesc.zig`: global open-file table plus Linux-like `open`/`read`/`write`/`close`/`lseek` descriptor semantics layered over the filesystem and console streams.
- `kernel/syscall.zig`: syscall number enum and dispatch entry point; routes `int 0x80` calls from user mode into kernel handlers for stdout, file descriptors, process control, and scheduling.

### Console & Input/Output
- `kernel/console.zig`: high-level console output with scrolling, cursor management, hex formatting, and memory dumps.
- `kernel/serial.zig`: COM1 serial driver for debug output and exception logging to the host via Bochs.
- `kernel/vgatext.zig`: low-level VGA 80x25 text-mode driver with cell read/write, cursor control.
- `kernel/keyboard.zig`: scancode-to-keycode conversion, extended key support, modifier tracking, ASCII conversion.
- `kernel/readline.zig`: line editing with cursor navigation, character insertion/deletion, line clearing.

### Storage & Filesystem
- `kernel/block_device.zig`: vtable-based block device abstraction. Block size is fixed at 512 bytes.
- `kernel/fs.zig`: extent-based filesystem with mount, format, whole-file helpers, offset-based entry I/O, reusable contiguous extent allocation, delete, and rename operations. Uses `BlockDevice` abstraction.
- `kernel/fs_defs.zig`: filesystem constants, superblock and directory entry structures, fixed layout definitions.
- `kernel/elf32.zig`: ELF32 binary format structures (headers, program headers), segment type/flag constants, image extent computation.
- `kernel/ide.zig`: IDE/ATA disk controller with LBA28 addressing, sector-level I/O. Also provides `IdeBlockDevice`, a concrete `BlockDevice` implementation backed by an ATA drive.
- `kernel/io.zig`: low-level port I/O helpers (inb, inw, outb, outw).

### Assembly & Low-Level
- `boot.asm`: boot sector and stage-2 loader.
- `interrupts.asm`: low-level exception/IRQ entry points, scancode buffering, interrupt statistics.

### Applications & Tools
- `kernel/app_keylog.zig`: the keylog app state and implementation for real-time keyboard debugging.
- `kernel/shell.zig`: command loop and table-driven shell command dispatch (help, ls, cat, write, rm, mv, serial, run, mkfs, dumpmem, memstat, keylog, shutdown, break). At boot it also executes commands from an optional `autoexec` file in the filesystem before entering the interactive prompt.
- `flatten_elf.zig`: converts the linked ELF stage-2 image into a flat binary plus metadata.
- `file_block_device.zig`: host-side `BlockDevice` implementation backed by a `std.Io.File`. Provides the storage layer for `extract_fs.zig` and `compile_fs.zig` so they can drive `kernel/fs.zig` directly.
- `extract_fs.zig`: host tool that mounts an existing filesystem image (via `fs.FileSystem.mount()`) and extracts all files to a directory.
- `compile_fs.zig`: host tool that formats a fresh filesystem image (via `fs.FileSystem.mountOrFormat()`) and writes a directory of input files into it using `fs.FileSystem.writeFile()`.
- `userspace/hello.zig`: freestanding userspace hello-world/yield smoke-test binary.
- `userspace/fs_stress.zig`: freestanding userspace filesystem stress test that keeps two file descriptors open, alternates writes, and validates `lseek` semantics.
- `userspace/sys.zig`, `userspace.ld`: shared userspace syscall ABI helpers and linker script.

### Build Configuration
- `stage2.ld`, `userspace.ld`: linker scripts for stage-2 and userspace.
- `SConstruct`: SCons build and run entrypoints.
- `build/`: generated objects, binaries, emulator config/output, and `image.img`.
- Bochs serial output is captured to `build/serial.txt` via the generated `build/bochsrc.txt`.

## Build, Test, and Development Commands

- `scons`: build the boot sector, stage-2 payload, userspace ELFs, filesystem image, and final `build/image.img`.
- `scons run`: build and run the image in Bochs.
- `scons debug`: build and run the image in Bochs with the debugger attached.
- `scons qemu`: build and run the image in QEMU.
- Add `AUTOEXEC="serial on\nrun hello"` to any of the above SCons commands to inject a one-off `autoexec` file into the filesystem image for that build.

Build pipeline overview:
- `build/stage2.elf`: linked from `kernel/kernel.zig` and `interrupts.asm`.
- `build/stage2.bin`: flattened from `build/stage2.elf` by `flatten_elf.zig`.
- `build/hello.elf`: linked from `userspace/hello.zig` and copied into the filesystem image as `hello`.
- `build/fs_stress.elf`: linked from `userspace/fs_stress.zig` and copied into the filesystem image as `fs_stress`.
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
| 0x10000000 - 0x40000000 | ~768 MB | User-mode rodata/data/heap (per-process) |
| 0x40000000 - 0x70000000 | ~768 MB | Unused |
| 0x70000000 - 0x80000000 | 256 MB | User-mode stack reservation (per-process, grows downward from 0x80000000; top page mapped initially) |
| 0x80000000 - 0xC0000000 | 1 GB | Unused |
| 0xC0008000 - 0xC0200000 | ~2 MB | Kernel code and data (stage-2) |
| 0xE0000000 - 0xE0400000 | 4 MB | Kernel heap (fixed-buffer allocator) |
| 0xFFC00000 - 0xFFFFF000 | ~4 MB | Recursively mapped page tables (PD[1023] entry points to PD) |
| 0xFFFFF000 - 0x100000000 | 4 KB | Recursively mapped page directory |

**Paging Implementation**: The kernel initially maps only the first 1 MB of physical RAM (both at 0x0 and 0xC0000000 for higher-half transition). Virtual-to-physical address translation uses recursive mapping tricks. Both page tables and user memory are allocated on-demand via the page allocator.

**Protected Mode & Segmentation**: The kernel initializes a GDT with kernel code/data segments (DPL 0), user code/data segments (DPL 3), and per-task Task State Segment (TSS) descriptors for ring transitions. Interrupts and exceptions load a 256-entry IDT with gate types for task gates and 16/32-bit interrupt/trap gates.

**Exception Handling**: The kernel handles multiple exception types including Page Fault (0x0E), General Protection Fault (0x0D), and others. User-mode faults (such as page faults) terminate the offending task without crashing the kernel.

**Serial Debug Output**: The kernel initializes COM1 early in boot and writes exception and panic diagnostics to the serial port. Bochs is configured with `com1: enabled=1, mode=file` so this output is captured in `build/serial.txt` on the host.

**Memory Management**: The kernel allocates a 4 MB kernel data region (1024 pages at 0xE000_0000) as a fixed-buffer allocator for all kernel-mode dynamic allocations. User processes are allocated private memory slices from the largest contiguous usable RAM region reported by E820 (typically starting at 1 MB) and have independent stack/heap boundaries. Each task has its own 4 KB kernel stack (power-of-2 aligned), with the current task pointer stored at the stack base. User-mode stacks live in a fixed reservation from 0x7000_0000 to 0x8000_0000 with the top page mapped initially and additional pages faulted in on demand within that window.

**Task/Process Management**: Each `Task` struct holds a 4 KB kernel stack (first word stores a pointer back to the `Task` for `getCurrentTask()`), a 4 KB per-task page directory, a unique PID, a saved `kernel_esp` (0 = free slot), user-mode stack/heap bounds, and a small per-task fd table (with stdio preinstalled plus mappings into the kernel global open-file table). User-mode execution uses flat-addressed segments backed by the user memory region. The kernel can load and execute freestanding ELF binaries (ELF32 format) by extracting code and data segments, computing heap and stack boundaries (page-aligned above the program image), and mapping those segments into GDT selectors 0x18 and 0x20 (user code/data, DPL=3). A fixed pool of 8 task slots is managed by `taskman.zig`.

**Cooperative Multitasking**: The kernel implements cooperative (non-preemptive) multitasking. Tasks voluntarily yield control via the `yield` syscall (24) or implicitly on `exit` (60) or a user-mode fault. The scheduler (`kernel.reschedule()`) uses `taskman.getNextActiveTask()` to perform round-robin selection over active slots. If no other task is runnable, the kernel reloads its own page directory and returns to the shell via `kernel_reenter()`. There is no timer-based preemption — tasks run until they yield.

Context switch flow (user → kernel → user):
1. User executes `int 0x80`; hardware loads kernel SS/ESP from TSS.
2. `syscall_isr` (in `interrupts.asm`) saves the kernel ESP into the current `Task.kernel_esp` via `save_kernel_stack_ptr()`.
3. `syscall_dispatch()` handles the call; for Exit/Yield it calls `reschedule()` (does not return).
4. `reschedule()` calls `next_task.switchTo(&tss_cpu0)` which runs inline assembly: loads the new page directory into CR3, places the new task's `kernel_esp` in EAX, and jumps to `task_switch`.
5. `task_switch` restores the stack pointer then falls through to `return_to_userspace` which executes `popad / pop es / pop ds / iretd` to resume user code.

**Syscall ABI**: User-mode programs invoke syscalls via `int 0x80` with the syscall number in `eax` and up to three arguments in `ebx`, `ecx`, `edx`. The return value is placed in `eax`. On failure, syscalls return `FAIL = 0xFFFFFFFF`.

| Syscall | Number | Arguments | Returns | Notes |
|---------|--------|-----------|---------|-------|
| `read` | 0 | fd, buf_offset, count | bytes read or `FAIL` | Reads from filesystem-backed fds |
| `write` | 1 | fd, buf_offset, count | bytes written or `FAIL` | Writes to stdout/stderr or filesystem-backed fds |
| `open` | 2 | path_offset, path_len, flags | fd or `FAIL` | Supports `O_CREAT`, `O_TRUNC`, and `O_APPEND` |
| `close` | 3 | fd | 0 or `FAIL` | Closes stdio or filesystem-backed fds |
| `lseek` | 8 | fd, signed_offset, whence | new offset or `FAIL` | Supports `SEEK_SET`, `SEEK_CUR`, and `SEEK_END`; may seek past EOF |
| `yield` | 24 | — | — | Voluntarily reschedule; does not return to caller directly |
| `getpid` | 39 | — | PID | Returns `getCurrentTask().pid` |
| `exit` | 60 | — | — | Terminates task, closes descriptors, and reschedules; does not return |
| `unlink` | 87 | path_offset, path_len | 0 or `FAIL` | Removes a filesystem entry; fails if the file is still open by any task |

**Disk Image Layout**: Sector 0 is the boot sector. Sectors 1–63 are reserved for the stage-2 loader. The custom filesystem begins at sector 64. The filesystem uses a one-sector superblock, an eight-sector flat root directory (64 entries × 64 bytes), and contiguous file extents allocated from reusable gaps with a first-fit scan. Directory slot 0 is reserved for a future bootable kernel file. Files are stored in contiguous extents with metadata (name, state, extent location, timestamps) tracked in the root directory.

**Filesystem**: The ZOD1 filesystem is fixed-layout with extent-based allocation. Files support read, write (create/overwrite), offset-based descriptor I/O, delete, rename, and userspace `unlink` operations. Writes still rewrite whole contiguous extents under the hood, but allocation can now reuse gaps left by deleted or superseded extents. Because open descriptors currently track directory-entry indices directly, `unlink` rejects files that are still open rather than emulating POSIX delete-on-last-close semantics. Directory entries track file state (FREE, FILE, RESERVED, DELETED), name (16 bytes max), extent info, and timestamps. Maximum 16-byte filenames and 64 directory entries.

**IDE & Storage**: The kernel uses LBA28 addressing (maximum 128 GB disks) and communicates with the primary IDE bus (I/O base 0x1F0, control base 0x3F6). Sector-level I/O with status polling and error handling (timeout, device fault, controller error).

## General Guidelines

- Use Zig 0.16.
- Every public Zig function should have at least a one-line doc comment explaining its function.
- Debugging tips:
  - Use `objdump -S` to disassemble the kernel binary for resolving crash addresses
  - For startup commands, use `scons run AUTOEXEC="..."` / `scons debug AUTOEXEC="..."`
  - Make use the the Bochs serial output logging to `build/serial.txt` for tracing exceptions and program state. Use the `serial on` shell command to mirror console output to the serial output.
- Whenever the design of the project changes, keep AGENTS.md up to date!
