# Processes & Scheduling

## Task/Process Management

Each `Task` struct starts with a 4 KB kernel stack page (its first word stores a pointer back to the `Task` for `getCurrentTask()`), followed by a 4 KB per-task page directory, a unique PID, a saved `kernel_esp`, user-mode stack/heap bounds, and a small per-task fd table (with stdio preinstalled plus mappings into the kernel global open-file table). `kernel_esp` points at a normalized userspace return frame defined in `interrupt_frame.zig`. Each task also carries a `TaskState` (`.free`, `.active`, `.waiting`, `.zombie`), a `parent_pid` (0 for shell-spawned tasks), a `reap_children` flag, an `exit_status`, and a `waiting_for_pid` for the blocked-waitpid case.

User-mode execution uses flat-addressed segments backed by the user memory region. The kernel can load and execute freestanding ELF binaries (ELF32 format) by extracting code and data segments, computing heap and stack boundaries (page-aligned above the program image), and mapping those segments into GDT selectors 0x18 and 0x20 (user code/data, DPL=3). `taskman.zig` allocates a fixed pool of 8 `TaskmanEntry` slots at runtime, each laid out as `[guard page][Task]`.

## Argv ABI

Command-line arguments are passed to a new process via `Task.setArgs(args)` and written into the userspace stack. `_start` (naked) pushes ESP and calls `argvStartup`, which reconstructs `[]const []const u8` from the ABI layout and passes it to `main(argv)`. The `run <executable> [<arg>...]` shell command launches a program with arguments (argv[0] = executable name); `multirun` launches several executables with no arguments.

## Scheduling & Preemption

The scheduler (`kernel.reschedule()`) performs round-robin selection over `.active` slots using `taskman.getNextActiveTask()`. The PIT is programmed for 100 Hz, so the nominal userspace timeslice is 10 ms. Each timer interrupt that arrives while running user code updates the tick counter and immediately calls `reschedule()`, which preempts CPU-bound userspace tasks even if they never invoke `yield`.

Preemption is currently limited to userspace. `interrupt_dispatch()` saves the current task's user return frame on every entry from ring 3, but the timer path only calls `reschedule()` when the interrupted frame came from user mode. If the timer fires while the kernel is already handling a syscall, filesystem work, or another exception, the interrupt is serviced and execution returns to that same kernel path without switching tasks. In other words: userspace is timer-preemptive, kernel execution remains non-preemptive.

Explicit scheduling points still matter. The `yield` syscall, blocking `waitpid`, task exit, and fatal user-mode faults all hand control to the scheduler. If no other runnable task is found and the current task is still `.active`, the scheduler resumes it immediately; if the current task exited or blocked and no runnable task remains, the kernel reloads its own page directory and re-enters the shell on a dedicated kernel-only stack via `kernel_reenter()`.

## Process Lifecycle & Zombie Reaping

When a task exits (via `exit` syscall or a fault), it first orphans any children (setting their `parent_pid = 0` and freeing any zombie children immediately). The task then releases its files and memory. Whether it becomes a zombie or is freed immediately depends on: (1) if `parent_pid == 0` (shell-spawned) or the parent has `reap_children = true`, the slot is freed at once; (2) if the parent is already blocked in `waitpid`, it is woken immediately and the slot freed; (3) otherwise the slot transitions to `.zombie` state, holding only the PID and exit status until the parent collects it via `waitpid`. This matches POSIX semantics: `set_child_reap` (syscall 1002) is the equivalent of `SIGCHLD = SIG_IGN`.

## Context Switch Flow (user → kernel → user)

1. User executes `int 0x80` or is interrupted in ring 3 by the timer, keyboard, or an exception; hardware loads kernel SS/ESP from the TSS and pushes the user return context.
2. The low-level stub in `interrupts.asm` pushes a normalized `vector/error_code` pair and then enters `generic_handler`.
3. `generic_handler` saves general-purpose registers plus `ds`/`es`, switches to the kernel data selector, and calls `interrupt_dispatch()` with a pointer to the normalized interrupt frame.
4. For every ring-3 entry, `interrupt_dispatch()` calls `task.saveReturnFrame()`, so `Task.kernel_esp` points at a full `UserInterruptFrame` that can later be resumed with `iretd`.
5. Vector-specific code runs: timer IRQs update the tick count and reschedule only when they interrupted user mode; syscalls may also reschedule on `yield`, `waitpid`, or `exit`; fatal user-mode faults terminate the task and reschedule.
6. `reschedule()` picks the next `.active` task in round-robin order. If another runnable task exists, `next_task.switchTo(&tss_cpu0)` loads its page directory into CR3, restores that task's saved `kernel_esp` into ESP, and jumps to `return_to_userspace`.
7. `return_to_userspace` executes `popad / pop es / pop ds`, drops the normalized `vector/error_code` pair, and finishes with `iretd` to resume the selected task's user code.
