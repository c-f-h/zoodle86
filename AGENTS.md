# `zoodle86` - Project Overview

This is a tiny x86 boot loader/OS kernel (32-bit protected mode) toy project in Zig.

## Project Structure & Module Organization

This repository builds a bootable x86 disk image with a tiny freestanding kernel and a small command-driven text UI.

- `boot.asm`: boot sector and stage-2 loader.
- `interrupts.asm`: low-level IRQ and interrupt entry code plus a freestanding memcpy symbol.
- `kernel.zig`: kernel entrypoint, memory setup, and shell startup.
- `shell.zig`: command loop and table-driven shell command dispatch.
- `console.zig`, `vgatext.zig`: VGA text-mode output.
- `keyboard.zig`, `readline.zig`: keyboard input and line editing.
- `app.zig`, `app_keylog.zig`: app state and the keylog app.
- `fs.zig`: fixed-layout extent-based filesystem for persistent whole-file storage.
- `ide.zig`, `io.zig`: low-level IDE and port I/O helpers.
- `flatten_elf.zig`: converts the linked ELF stage-2 image into a flat binary plus metadata.
- `stage2.ld`: linker script for the stage-2 image.
- `SConstruct`: build and run entrypoints.
- `build/`: generated objects, binaries, emulator config/output, and `image.img`.

## Build, Test, and Development Commands

- `scons`: build the boot sector, stage-2 payload, and `build/image.img`.
- `scons run`: build and run the image in Bochs.
- `scons qemu`: build and run the image in QEMU.

Build pipeline details:
- NASM assembles `interrupts.asm` into `build/interrupts.o` and later assembles `boot.asm` into the final 512-byte boot sector.
- Zig compiles `kernel.zig` into an object file `build/kernel.o` (single compilation unit).
- Zig links the Zig object plus the interrupt object into `build/stage2.elf` as an ELF image with image base `0x8000`.
- `flatten_elf.zig` flattens that ELF into `build/stage2.bin` and writes metadata with the entry offset and sector count to `build/stage2.meta`.
- SCons rebuilds `boot.asm` with those values injected as NASM defines.
- `build/image.img` is produced by packing the boot sector into sector 0, reserving sectors 1-63 for stage 2, and leaving the filesystem region at sector 33 and beyond intact across rebuilds.
- SCons also generates `build/bochsrc.txt` and logs Bochs output to `build/bochsout.txt`.

There is no separate unit-test suite yet. A successful build is the current baseline check.

## Architecture Notes

The boot sector collects the BIOS E820 memory map at `0x7E00`, loads a flat stage-2 image at `0x8000`, and switches to 32-bit protected mode before jumping into Zig code. On hard-disk boots it uses BIOS extended LBA reads for stage 2; the older CHS path is only used for floppy-style boots.

The disk image uses a fixed layout: sector 0 is the boot sector, sectors 1-63 are reserved for stage 2, and the custom filesystem starts at sector 33. The filesystem uses a one-sector superblock, an eight-sector flat root directory, and append-only contiguous file extents. Directory slot 0 is reserved for a future bootable kernel file.

`kernel.zig` initializes the interrupt layer, sets up the VGA text console, builds a fixed-buffer allocator from the largest usable RAM region reported by E820, mounts the filesystem, and then starts the shell. `shell.zig` owns the table-driven command loop and dispatches built-in commands including `ls`, `cat <name>`, `write <name>`, `rm <name>`, `mv <old> <new>`, `mkfs`, `keylog`, `dumpmem <hex-address>`, and `shutdown`.

## Style Guidelines

- Every public Zig function should have at least a one-line doc comment explaining its function.
- Whenever the design of the project changes, keep AGENTS.md up to date!
