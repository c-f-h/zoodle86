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
| **mkfs** | (none) | Reformat the filesystem. |
| **dumpmem** | `<hex-address>` | Dump memory at a hex address. |
| **memstat** | (none) | Show page allocator memory statistics. |
| **serial** | `<on\|off>` | Mirror console output to COM1 (toggle serial logging). |
| **run** | `<executable> [<arg> ...]` | Run an ELF executable with command-line arguments. (argv[0] = executable name, plus optional args.) |
| **multirun** | `<executable> [<executable> ...]` | Load and execute several ELF executables concurrently. |
| **shutdown** | (none) | Power off Bochs/QEMU. |
| **break** | (none) | Invoke a Bochs magic breakpoint. |

## Startup Script

At boot, the shell executes an optional `autoexec` file from the filesystem before entering the interactive prompt. This allows automation of startup tasks. Inject a custom autoexec via SCons:

```sh
scons run AUTOEXEC="serial on\nrun hello\nshutdown"
```

End scripts with `shutdown` for a clean exit.
