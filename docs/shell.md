# Shell Commands

The kernel provides an interactive shell with the following commands:

| Command | Arguments | Description |
|---------|-----------|-------------|
| **help** | (none) | List available commands. |
| **keylog** | (none) | Run the key event logger. |
| **ls** | (none) | List files in the filesystem. |
| **cat** | `<name>` | Print a file's contents. |
| **write** | `<name>` | Write a file from console input. (Single `.` line saves.) |
| **rm** | `<name>` | Delete a file. |
| **mv** | `<old> <new>` | Rename a file. |
| **cpuid** | `[<leaf> [<subleaf>]]` | Show vendor/clock-related CPUID leaves, or dump a specific raw leaf/subleaf. |
| **mkfs** | (none) | Reformat the filesystem. |
| **dumpmem** | `<hex-address>` | Dump memory at a hex address. |
| **memmap** | (none) | Interactive full-screen page directory/table viewer. |
| **memstat** | (none) | Show page allocator memory statistics. |
| **taskswitch** | (none) | Show the number of scheduler task-to-task switches since boot. |
| **ticks** | `[<arg> ...]` | Write current timer ticks to COM1 and append any provided arguments on the same line. |
| **profile** | `<start\|stop>` | Control the kernel timer-tick EIP profiler. `start` begins sampling to page-backed buffers; `stop` writes a descending EIP count histogram to COM1. |
| **fontbench** | `<count>` | Stress framebuffer font rendering without scrollback by drawing 1000 characters, restoring the original cursor position, and repeating the pass `count` times. |
| **serial** | `<on\|off>` | Mirror console output to COM1 (toggle serial logging). |
| **run** | `<executable> [<arg> ...]` | Run an ELF executable with command-line arguments. (argv[0] = executable name, plus optional args.) |
| **multirun** | `<count> <executable> [<arg> ...]` | Run `count` concurrent copies of one ELF executable, forwarding the same argv to each copy. |
| **shutdown** | (none) | Power off Bochs/QEMU. |
| **break** | (none) | Invoke a Bochs magic breakpoint. |

## Startup Script

At boot, the shell executes an optional `autoexec` file from the filesystem before entering the interactive prompt. This allows automation of startup tasks. Inject a custom autoexec via SCons:

```sh
scons run AUTOEXEC="serial on\nrun hello\nshutdown"
```

End scripts with `shutdown` for a clean exit.
