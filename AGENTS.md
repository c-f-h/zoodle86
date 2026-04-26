# `zoodle86` - Project Overview

A tiny x86 boot loader/OS kernel (32-bit protected mode) toy project in Zig. Builds a bootable disk image with a freestanding kernel and a small command-driven text UI. Supports virtual memory paging, cooperative multitasking, a simple inode-based custom filesystem, and basic ACPI functionality.

## Documentation

- [docs/modules.md](docs/modules.md) — Every source file and its role
- [docs/architecture.md](docs/architecture.md) — Boot, paging, virtual memory layout, memory management
- [docs/interrupts.md](docs/interrupts.md) — GDT/IDT, ACPI/APIC initialization, exception handling
- [docs/processes.md](docs/processes.md) — Tasks, cooperative scheduling, context switch flow, process lifecycle
- [docs/syscalls.md](docs/syscalls.md) — Syscall ABI reference table
- [docs/storage.md](docs/storage.md) — Disk image layout, ZOD2 filesystem, IDE driver, build artifacts
- [docs/shell.md](docs/shell.md) — Available kernel shell commands and startup script injection

## Build & Run

```sh
scons               # build everything → build/image.img
scons run           # build + run in Bochs
scons debug         # build + run in Bochs with debugger
scons qemu          # build + run in QEMU
```

Inject a one-off `autoexec` script (do **not** use an environment variable):
```sh
scons run AUTOEXEC="serial on\nrun hello\nshutdown"
```

There is no separate unit-test suite. A successful build is the current baseline check. Running the `hello 3 3` (PID, spawning, basic syscalls), `fs_stress` (syscall-heavy file operations), and `alloc_stress` (userspace memory manipulation) programs can serve as additional checks.

## Debugging

- Serial output is captured to `build/serial.txt`. Use `serial on` inside the shell to mirror console output there.
- Use `objdump` to disassemble the kernel binary for resolving crash addresses.
- Prefix any `scons run`/`scons debug` invocation with `AUTOEXEC="..."` to inject startup commands. End scripts with `shutdown` for a clean exit.

## General Guidelines

- Use Zig 0.16.
- Every public Zig function should have at least a one-line doc comment.
- Debugging tips:
  - Use `objdump` to disassemble the kernel binary for resolving crash addresses
  - For startup commands, use `scons run AUTOEXEC="..."` / `scons debug AUTOEXEC="..."`. Do **not** use an environment variable for this. End with `shutdown` to terminate cleanly.
  - Make use of serial output logging to `build/serial.txt` for tracing exceptions and program state. Use the `serial on` shell command to mirror console output to the serial output.
- Whenever the design of the project changes, keep AGENTS.md up to date!
