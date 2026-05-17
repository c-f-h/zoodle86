# Shell Commands

The kernel provides an interactive shell with the following commands:

| Command | Arguments | Description |
|---------|-----------|-------------|
| **help** | (none) | List available commands. |
| **keylog** | (none) | Run the key event logger. |
| **write** | `<name>` | Write a file from console input. (Single `.` line saves.) |
| **cpuid** | `[<leaf> [<subleaf>]]` | Show vendor/clock-related CPUID leaves, or dump a specific raw leaf/subleaf. |
| **dumpmem** | `<hex-address>` | Dump memory at a hex address. |
| **memmap** | (none) | Interactive full-screen page directory/table viewer. |
| **memstat** | (none) | Show page allocator memory statistics. |
| **taskswitch** | (none) | Show the number of scheduler task-to-task switches since boot. |
| **ticks** | `[<arg> ...]` | Write current timer ticks to COM1 and append any provided arguments on the same line. |
| **profile** | `<start\|stop>` | Control the kernel timer-tick EIP profiler. `start` begins sampling to page-backed buffers; `stop` writes a descending EIP count histogram to COM1. |
| **fontbench** | `<count>` | Stress framebuffer font rendering without scrollback by drawing 1000 characters, restoring the original cursor position, and repeating the pass `count` times. |
| **serial** | `<on\|off>` | Mirror console output to COM1 (toggle serial logging). |
| **run** | `<executable> [<arg> ...]` | Run an ELF executable with optional command-line arguments. Bare names are resolved through the shell path, currently `/bin`. |
| **multirun** | `<count> <executable> [<arg> ...]` | Run `count` concurrent copies of one ELF executable, forwarding the same argv to each copy. Bare names are resolved through the shell path, currently `/bin`. |
| **ps** | (none) | List all active tasks with their PID, state, and parent PID. |
| **shutdown** | (none) | Power off Bochs/QEMU. |
| **break** | (none) | Invoke a Bochs magic breakpoint. |

## Startup Script

At boot, the shell executes an optional `autoexec` file from the filesystem before entering the interactive prompt. This allows automation of startup tasks. Inject a custom autoexec via SCons:

```sh
scons run AUTOEXEC="serial on\nrun hello\nshutdown"
```

The default value for `AUTOEXEC` is `run shell\nshutdown`.

End scripts with `shutdown` for a clean exit.

## Userspace Shell

The `/bin/shell` userspace program provides an interactive prompt built on the userspace readline library. Every non-empty line is parsed as a pipeline of one or more command stages. Each stage resolves bare program names through `/bin` and supports shell-style left-to-right redirections with `<`, `>`, and `>>`.

- `hello 4` runs `/bin/hello 4`.
- `ls /bin > list.txt` redirects stdout to a file using spawn-time fd remapping.
- `echo hello >> log.txt` appends stdout to an existing file or creates it if needed.
- `cat < log.txt | cat > copy.txt` combines input redirection, a pipe, and output redirection in one command line.
- `echo one > out.txt >> log.txt` follows shell-style left-to-right semantics: both redirections are opened in order, and the later one becomes the command's final stdout target.

Kernel shell commands can be invoked by prefixing with a `!`, e.g., `!memmap`.
