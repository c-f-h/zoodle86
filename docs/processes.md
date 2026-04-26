# Processes & Scheduling

## Task/Process Management

Each `Task` struct starts with a 4 KB kernel stack page (its first word stores a pointer back to the `Task` for `getCurrentTask()`), followed by a 4 KB per-task page directory, a unique PID, a saved `kernel_esp`, user-mode stack/heap bounds, and a small per-task fd table (with stdio preinstalled plus mappings into the kernel global open-file table). `kernel_esp` points at a normalized userspace return frame defined in `interrupt_frame.zig`. Each task also carries a `TaskState` (`.free`, `.active`, `.waiting`, `.zombie`), a `parent_pid` (0 for shell-spawned tasks), a `reap_children` flag, an `exit_status`, and a `waiting_for_pid` for the blocked-waitpid case.

User-mode execution uses flat-addressed segments backed by the user memory region. The kernel can load and execute freestanding ELF binaries (ELF32 format) by extracting code and data segments, computing heap and stack boundaries (page-aligned above the program image), and mapping those segments into GDT selectors 0x18 and 0x20 (user code/data, DPL=3). `taskman.zig` allocates a fixed pool of 8 `TaskmanEntry` slots at runtime, each laid out as `[guard page][Task]`.

## Argv ABI

Command-line arguments are passed to a new process via `Task.setArgs(args)` and written into the userspace stack. `_start` (naked) pushes ESP and calls `argvStartup`, which reconstructs `[]const []const u8` from the ABI layout and passes it to `main(argv)`. The `run <executable> [<arg>...]` shell command launches a program with arguments (argv[0] = executable name); `multirun` launches several executables with no arguments.

## Cooperative Multitasking

The kernel implements cooperative (non-preemptive) multitasking. Tasks voluntarily yield control via the `yield` syscall (24) or implicitly on `exit` (60) or a user-mode fault. The scheduler (`kernel.reschedule()`) uses `taskman.getNextActiveTask()` to perform round-robin selection over `.active` slots. If no runnable task is found and the current task is no longer active (exited or blocked), the kernel reloads its own page directory and re-enters the shell on a dedicated kernel-only stack via `kernel_reenter()`. There is no timer-based preemption — tasks run until they yield.

## Process Lifecycle & Zombie Reaping

When a task exits (via `exit` syscall or a fault), it first orphans any children (setting their `parent_pid = 0` and freeing any zombie children immediately). The task then releases its files and memory. Whether it becomes a zombie or is freed immediately depends on: (1) if `parent_pid == 0` (shell-spawned) or the parent has `reap_children = true`, the slot is freed at once; (2) if the parent is already blocked in `waitpid`, it is woken immediately and the slot freed; (3) otherwise the slot transitions to `.zombie` state, holding only the PID and exit status until the parent collects it via `waitpid`. This matches POSIX semantics: `set_child_reap` (syscall 1002) is the equivalent of `SIGCHLD = SIG_IGN`.

## Context Switch Flow (user → kernel → user)

1. User executes `int 0x80`; hardware loads kernel SS/ESP from TSS and pushes return context.
2. `syscall_isr` (in `interrupts.asm`) pushes the vector and error code, then jumps to `generic_handler`.
3. `generic_handler` (in `interrupts.asm`) saves registers, loads kernel data selector, calls `interrupt_dispatch()` with a pointer to the `InterruptFrame`, and restores.
4. `interrupt_dispatch()` (in `kernel.zig`) recognizes VECTOR_SYSCALL, calls `task.saveKernelStackPtr()` to store the frame pointer into `Task.kernel_esp`, and dispatches to `syscall_dispatch()`.
5. `syscall_dispatch()` handles the call; for Exit/Yield it calls `reschedule()` (does not return).
6. `reschedule()` calls `next_task.switchTo(&tss_cpu0)` which loads the new page directory into CR3, restores the new task's `kernel_esp` into ESP, and jumps to `return_to_userspace`.
7. `return_to_userspace` executes `popad / pop es / pop ds`, drops the normalized `vector/error_code` pair, and finishes with `iretd` to resume user code.
