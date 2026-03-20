# Project Overview

This is a tiny x86 boot loader/kernel toy project.

## Project Structure & Module Organization
This repository builds a bootable x86 floppy image with a tiny freestanding kernel.

- `boot.asm`: boot sector and stage-2 loader.
- `interrupts.asm`: low-level IRQ and interrupt entry code.
- `kernel.c`: kernel entrypoint and main event loop.
- `SConstruct`: build and run entrypoints.
- `build/`: generated objects, binaries, Bochs config, and `floppy.img`.

## Build, Test, and Development Commands
- `scons`: build the boot sector, stage-2 binary, and `build/floppy.img`.
- `scons run`: build and run Bochs directly through SCons.

Build pipeline details:
- NASM assembles `interrupts.asm` into `build/interrupts.o` and later assembles `boot.asm` into the final 512-byte boot sector.
- TinyCC (`tcc`) compiles each C translation unit into a separate object file under `build/`.
- TinyCC links the C objects plus the interrupt object into `build/stage2.exe` as a PE32 image with image base `0x8000`.
- The SCons pipeline flattens that PE image into a raw stage-2 binary, writes metadata with the entry offset and sector count, then rebuilds `boot.asm` with those values injected as NASM defines.
- `build/floppy.img` is produced by packing the boot sector into sector 0 and the flattened stage-2 payload immediately after it.

There is no separate unit-test suite yet. A successful build is the current baseline check.

## Architecture Notes

The boot sector loads a flat stage-2 image at `0x8000`. `kernel.c` initializes
the text console, enables interrupts through the assembly IRQ layer, and
updates screen state from keyboard interrupt data.

## Style Guidelines

- When adding or modifying a C header file, all functions should have, at the least, a one-line comment explaining their function.
