# Syscall ABI

User-mode programs invoke syscalls via `int 0x80` with the syscall number in `eax` and up to three arguments in `ebx`, `ecx`, `edx`. The return value is placed in `eax`. On failure, syscalls return `FAIL = 0xFFFFFFFF`.

| Syscall | Number | Arguments | Returns | Notes |
|---------|--------|-----------|---------|-------|
| `read` | 0 | fd, buf_offset, count | bytes read or `FAIL` | Reads from filesystem-backed fds |
| `write` | 1 | fd, buf_offset, count | bytes written or `FAIL` | Writes to stdout/stderr or filesystem-backed fds |
| `open` | 2 | path_offset, path_len, flags | fd or `FAIL` | Supports `O_CREAT`, `O_TRUNC`, and `O_APPEND` |
| `close` | 3 | fd | 0 or `FAIL` | Closes stdio or filesystem-backed fds |
| `lseek` | 8 | fd, signed_offset, whence | new offset or `FAIL` | Supports `SEEK_SET`, `SEEK_CUR`, and `SEEK_END`; may seek past EOF |
| `brk` | 12 | addr | new break or `FAIL` | Gets heap break if addr=0; sets break to addr if valid; validates bounds and grows/shrinks data memory |
| `yield` | 24 | — | — | Voluntarily reschedule; does not return to caller directly |
| `getpid` | 39 | — | PID | Returns `getCurrentTask().pid` |
| `exit` | 60 | exit_code | — | Terminates task with the given exit code, closes descriptors, and reschedules; does not return |
| `waitpid` | 61 | pid | exit_status or `FAIL` | Blocks until the child with the given PID exits; returns its exit status. Returns `FAIL` if PID is not a direct child. |
| `unlink` | 87 | path_offset, path_len | 0 or `FAIL` | Removes a filesystem entry; fails if the file is still open by any task |
| `spawn` | 1001 | argv_slice_ptr | child PID or `FAIL` | Reads a userspace `AbiSlice` describing the full argv array; `argv[0]` names the executable |
| `set_child_reap` | 1002 | — | 0 | Marks the calling task so all its children auto-reap on exit instead of becoming zombies (analogous to `SIGCHLD = SIG_IGN` on Linux) |
