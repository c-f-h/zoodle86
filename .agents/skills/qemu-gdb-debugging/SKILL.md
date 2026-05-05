---
name: qemu-gdb-debugging
description: Debug the kernel using QEMU and GDB. Use for tricky bugs when serial output is not enough.
---

# QEMU + GDB debugging

Use this skill when a bug reproduces in QEMU and serial output is not enough.

## Purpose

This project can be debugged effectively by running QEMU with a GDB stub and attaching `gdb.exe` to `build/kernel.full.elf`.

This is especially useful for:

- early boot faults
- page faults before the shell is usable
- validating the exact instruction and register state behind a serial crash
- tracing repeated low-level events such as page-table writes

## Required artifacts

- Build first with `scons`
- Use `build/kernel.full.elf` for symbols
- Use `build/kernel.disasm` to map raw EIPs to code quickly

## Working QEMU invocation on Windows

Start QEMU directly instead of relying on `scons qemu` when you need GDB:

```powershell
& 'C:\Program Files\qemu\qemu-system-i386.exe' `
  -m 32 `
  -boot order=ac `
  -drive file=<path>\zoodle86\build\image.img,if=ide,format=raw `
  -serial file=<path>\zoodle86\build\serial-gdb-PORT.txt `
  -display none `
  -no-reboot `
  -no-shutdown `
  -S `
  -gdb tcp::PORT
```

### Notes

- `-S` starts QEMU paused so GDB can attach before execution.
- `-gdb tcp::PORT` exposes the stub on the selected TCP port.
- `-display none` avoids GUI noise for debugging sessions.
- `-no-reboot -no-shutdown` keeps the VM from disappearing immediately after faults.
- Always use **absolute paths** for the disk image and serial file.
- Make sure to terminate the QEMU process after a debugging session to free the TCP port and unlock the serial file.

## Working GDB invocation on Windows

Use MinGW GDB in batch mode:

```powershell
& 'C:\Program Files\mingw64\bin\gdb.exe' `
  -q -batch build\kernel.full.elf `
  -ex "set pagination off" `
  -ex "set confirm off" `
  -ex "set architecture i386" `
  -ex "target remote localhost:PORT"
```

### Notes

- `target remote localhost:PORT` worked. Using `:PORT` did **not** work reliably on Windows here.
- `set architecture i386` is needed for sane x86 32-bit disassembly/register output.
- Batch mode is much easier than interactive GDB inside this environment.

## What worked

### 1. Map serial crash EIPs to code first

For a serial crash like:

```text
eip: C0018CC9
```

use:

```powershell
rg "c0018cc9" build\kernel.disasm -n -C 8
```

This can quickly identify the exact faulting instruction location.

### 2. Break on raw addresses

Local Zig symbols were not always easy to break on by name, but raw addresses worked:

```powershell
-ex "b *0xC0018CC9"
```

This was the most reliable way to stop in optimized kernel code.

### 3. Use `objdump -t` for local/static symbols

When GDB could not resolve a function name directly, this worked:

```powershell
objdump -t build\kernel.full.elf | Select-String -Pattern 'page_fault|mapContiguousRangeAt|acpi\.mapTable'
```

That gave usable addresses for local functions and optimized code paths.

### 4. Use batch GDB scripts for repeated breakpoints

For trace-heavy debugging, a `.gdb` script worked better than a long inline command.

Example pattern:

```gdb
set pagination off
set confirm off
set architecture i386
target remote localhost:1244

b *0xC0018CC9
commands
silent
printf "HIT eip=%#x edi=%#x eax=%#x ecx=%#x edx=%#x cr3=%#x\n", $eip, $edi, $eax, $ecx, $edx, $cr3
continue
end

b *0xC00196A3
continue
info registers eax ebx ecx edx esi edi ebp esp eip cr2 cr3
bt
quit
```

This was effective for tracing repeated page-table writes until the eventual page fault.

### 5. QEMU reproduced faults differently from Bochs, but still usefully

Bochs showed one startup fault shape, while QEMU reproduced the issue as:

```text
Error code: 00000002
Address:    FFC00000
eip:        C0018CC9
```

That difference was still valuable because QEMU + GDB exposed the underlying corruption much more clearly.

## What did not work

### 1. Detached QEMU sessions were unreliable for GDB work

Starting QEMU as a detached process often exited immediately or lost the expected working-directory/file behavior.

Prefer a normal async/background session that stays attached to the shell session.

### 2. Lingering QEMU processes locked the serial file and TCP port

QEMU failed with errors like:

```text
open ...serial-gdb.txt failed
could not connect serial device to character backend
```

Make sure the previous QEMU process is terminated before starting a new session.

### 3. Relative paths were fragile

Detached/background QEMU launches did not reliably open relative paths like:

- `build\image.img`
- `build\serial.txt`

Use absolute paths instead.

### 4. Named breakpoints were unreliable for local Zig functions

`b page_fault_handler` failed even though the code existed. Breaking by address was more reliable than relying on symbol names for local/static functions.

### 5. Reading recursive paging memory after the recursive mapping was corrupted was not useful

Once the fault had already damaged the recursive page-table mapping, reads like:

- `x/8wx 0xFFFFF000`
- `x/8wx 0xFFC00000`

failed because the mapping itself was gone. In that case, break **before** the faulting write or trace the writes leading up to it.

## Project-specific lessons from this repository

### Serial + disassembly + GDB is the best escalation path

Use this order:

1. reproduce with serial output
2. map EIP with `build/kernel.disasm`
3. reproduce in QEMU
4. attach GDB to `build/kernel.full.elf`
5. break on raw addresses or trace repeated hits with a GDB script
