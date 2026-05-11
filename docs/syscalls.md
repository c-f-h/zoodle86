# Syscall ABI

User-mode programs invoke syscalls via `int 0x80` with the syscall number in `eax` and up to three arguments in `ebx`, `ecx`, `edx`. On return, `eax` holds the syscall return value and `ecx` holds the errno value (`0` on success).

Syscall numbers are either the same as that of a Linux syscall which is similar in name and functionality, or > 1000 for project-native ones which have no direct Linux equivalent.

| Syscall | Number | Arguments | Returns | Notes |
|---------|--------|-----------|---------|-------|
| `read` | 0 | fd, buf_offset, count | bytes read | Reads from filesystem-backed, pipe, or tty fds |
| `write` | 1 | fd, buf_offset, count | bytes written | Writes to tty-backed stdio, filesystem-backed, pipe, or tty fds |
| `open` | 2 | path_offset, path_len, flags | fd | Supports `O_CREAT`, `O_TRUNC`, and `O_APPEND` |
| `close` | 3 | fd | 0 | Closes stdio, pipe, or filesystem-backed fds |
| `stat` | 4 | path_offset, path_len, stat_out_offset | 0 | Fills a writable userspace `Stat` buffer for an inode-backed path |
| `fstat` | 5 | fd, stat_out_offset | 0 | Fills a writable userspace `Stat` buffer for an open fd; supports files, directories, stdio, pipes, and tty devices |
| `lseek` | 8 | fd, signed_offset, whence | new offset | Supports `SEEK_SET`, `SEEK_CUR`, and `SEEK_END`; may seek past EOF |
| `brk` | 12 | addr | new break | Gets heap break if addr=0; sets break to addr if valid; validates bounds and grows/shrinks data memory |
| `pipe` | 22 | fds_slice_ptr | 0 | Expects an `AbiSlice` describing a writable 2-element `u32` buffer and fills it with `{ read_fd, write_fd }` |
| `yield` | 24 | — | — | Voluntarily reschedule; does not return to caller directly |
| `dupfd` | 33 | old_fd, new_fd | new fd | Duplicates file descriptor `old_fd` to `new_fd`; if new_fd is -1, uses lowest available fd |
| `getpid` | 39 | — | PID | Returns `getCurrentTask().pid` |
| `exit` | 60 | exit_code | — | Terminates task with the given exit code, closes descriptors, and reschedules; does not return |
| `waitpid` | 61 | pid | exit_status | Blocks until the child with the given PID exits; returns its exit status. Returns `EINVAL` in `ecx` if PID is not a direct child. |
| `getdents` | 78 | fd, dirent_slice_ptr | entry count | Expects an `AbiSlice` describing a writable `DirEntry` buffer; returns the number of entries written, or 0 at end-of-directory. |
| `mkdir` | 83 | path_slice | 0 | Creates a directory; path_slice is a userspace address pointing to an `AbiSlice` describing the path |
| `rmdir` | 84 | path_offset, path_len | 0 | Removes a directory; fails if not empty or in use |
| `link` | 86 | old_path_slice, new_path_slice | 0 | Creates a hard link from `new_path` to the existing regular file at `old_path` |
| `rename` | 82 | old_path_slice, new_path_slice | 0 | Atomically moves `old_path` to `new_path`; replaces any existing regular file at `new_path`. |
| `unlink` | 87 | path_offset, path_len | 0 | Removes a filesystem entry; fails if the file is still open by any task |
| `ftruncate` | 93 | fd, length | 0 | Resizes a filesystem-backed fd; zero-fills when extending and requires write access |
| `ioctl` | 156 | fd, command, arg | device-specific | Currently supports tty mode switching via `IOCTL_TTY_SET_MODE` with `TTY_MODE_CANONICAL`/`TTY_MODE_RAW`. |
| `spawn` | 1001 | argv_slice_ptr, opts_ptr | child PID | Reads a userspace `AbiSlice` describing the full argv array; `argv[0]` names the executable. `opts_ptr` is 0 (no options) or a pointer to a `SpawnOpts` struct whose `fd_remaps` field is an `AbiSlice` of `(dst_u32, src_u32)` pairs; for each pair the child's `fd[dst]` is set to a copy of the parent's `fd[src]` |
| `set_child_reap` | 1002 | — | 0 | Marks the calling task so all its children auto-reap on exit instead of becoming zombies (analogous to `SIGCHLD = SIG_IGN` on Linux) |
| `kshell` | 1003 | cmdline_slice_ptr | 0 | Executes a kernel shell command string. |
| `get_cursor` | 1004 | — | `(row << 16) \| col` | Returns the stdout console cursor position (both 0-indexed) packed into a single u32. |

Common errno values currently returned in `ecx` include `ENOENT`, `EIO`, `E2BIG`, `EBADF`, `EAGAIN`, `ENOMEM`, `EACCES`, `EFAULT`, `EBUSY`, `EEXIST`, `ENOTDIR`, `EINVAL`, `ENFILE`, `EMFILE`, `ENOSPC`, and `ENOTEMPTY`.
