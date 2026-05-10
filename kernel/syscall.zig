const filedesc = @import("filedesc.zig");
const interrupt_frame = @import("interrupt_frame.zig");
const kernel = @import("kernel.zig");
const paging = @import("paging.zig");
const shell = @import("shell.zig");
const task = @import("task.zig");
const taskman = @import("taskman.zig");
const console = @import("console.zig");
const abi = @import("abi");
const std = @import("std");

const Syscall = abi.Syscall;

const ERRNO_E2BIG: u32 = 7;
const ERRNO_EAGAIN: u32 = 11;
const ERRNO_EIO: u32 = 5;
const ERRNO_ENOENT: u32 = 2;
const ERRNO_ENOMEM: u32 = 12;
const ERRNO_EFAULT: u32 = 14;
const ERRNO_EACCES: u32 = 13;
const ERRNO_EEXIST: u32 = 17;
const ERRNO_ENFILE: u32 = 23;
const ERRNO_EMFILE: u32 = 24;
const ERRNO_EBADF: u32 = 9;
const ERRNO_EBUSY: u32 = 16;
const ERRNO_EINVAL: u32 = 22;
const ERRNO_ENOSPC: u32 = 28;
const ERRNO_ENOTEMPTY: u32 = 39;

fn errnoResult(errno: u32) u32 {
    _ = errno;
    // TODO: set errno
    return 0xFFFF_FFFF;
}

fn mapError(err: anyerror) u32 {
    return errnoResult(switch (err) {
        error.AccessDenied => ERRNO_EACCES,
        error.ArgsTooLarge => ERRNO_E2BIG,
        error.BadFd => ERRNO_EBADF,
        error.FileInUse => ERRNO_EBUSY,
        error.AccessViolation => ERRNO_EFAULT,
        error.ControllerError => ERRNO_EIO,
        error.Corrupt => ERRNO_EIO,
        error.DeviceFault => ERRNO_EIO,
        error.DirectoryFull => ERRNO_ENOSPC,
        error.DirNotEmpty => ERRNO_ENOTEMPTY,
        error.FileExists => ERRNO_EEXIST,
        error.FileNotFound => ERRNO_ENOENT,
        error.InvalidArgument => ERRNO_EINVAL,
        error.InvalidFlags => ERRNO_EINVAL,
        error.InvalidLba => ERRNO_EIO,
        error.InvalidName => ERRNO_EINVAL,
        error.InvalidSeek => ERRNO_EINVAL,
        error.InvalidSuperblock => ERRNO_EIO,
        error.NotADirectory => ERRNO_EINVAL,
        error.NotARegularFile => ERRNO_EINVAL,
        error.NoDevice => ERRNO_EIO,
        error.NoTaskSlots => ERRNO_EAGAIN,
        error.NoSpace => ERRNO_ENOSPC,
        error.NotAtaDevice => ERRNO_EIO,
        error.OutOfMemory => ERRNO_ENOMEM,
        error.ProcessFileTableFull => ERRNO_EMFILE,
        error.SystemFileTableFull => ERRNO_ENFILE,
        error.Timeout => ERRNO_EIO,
        else => ERRNO_EIO,
    });
}

fn sys_open(path_ofs: u32, path_len: u32, flags: u32) !u32 {
    const path = try task.getCurrentTask().getUserMem(path_ofs, path_len);
    return try filedesc.openFile(kernel.getFileSystem(), task.getCurrentTask(), path, flags);
}

fn sys_close(fd: u32) !u32 {
    try filedesc.closeFile(task.getCurrentTask(), fd);
    return 0;
}

fn sys_stat(path_slice_va: u32, stat_ofs: u32) !u32 {
    const current_task = task.getCurrentTask();
    const path = try current_task.readUserSlice(u8, path_slice_va);
    const stat = try filedesc.statPath(kernel.getFileSystem(), path);
    const out = try current_task.getUserMem(stat_ofs, @sizeOf(filedesc.Stat));
    @memcpy(out, std.mem.asBytes(&stat));
    return 0;
}

fn sys_fstat(fd: u32, stat_ofs: u32) !u32 {
    const current_task = task.getCurrentTask();
    const stat = try filedesc.statFd(current_task, fd);
    const out = try current_task.getUserMem(stat_ofs, @sizeOf(filedesc.Stat));
    @memcpy(out, std.mem.asBytes(&stat));
    return 0;
}

fn sys_unlink(path_ofs: u32, path_len: u32) !u32 {
    const path = try task.getCurrentTask().getUserMem(path_ofs, path_len);
    try filedesc.unlinkFile(kernel.getFileSystem(), path);
    return 0;
}

fn sys_read(fd: u32, ofs: u32, count: u32) !u32 {
    const dest = try task.getCurrentTask().getUserMem(ofs, count);
    return @intCast(try filedesc.readFromFd(task.getCurrentTask(), fd, dest));
}

fn sys_write(fd: u32, ofs: u32, count: u32) !u32 {
    const data = try task.getCurrentTask().getUserMem(ofs, count);
    return @intCast(try filedesc.writeToFd(task.getCurrentTask(), fd, data));
}

fn sys_lseek(fd: u32, offset_bits: u32, whence: u32) !u32 {
    const offset: i32 = @bitCast(offset_bits);
    return try filedesc.seekFile(kernel.getFileSystem(), task.getCurrentTask(), fd, offset, whence);
}

fn sys_ftruncate(fd: u32, size: u32) !u32 {
    try filedesc.truncateFile(kernel.getFileSystem(), task.getCurrentTask(), fd, size);
    return 0;
}

fn sys_brk(addr: u32) !u32 {
    const ptask = task.getCurrentTask();
    if (addr == 0) {
        return ptask.heap_brk;
    }
    if (addr < ptask.heap_start) {
        return error.InvalidArgument;
    }
    if (addr > ptask.stack_bottom) {
        return error.OutOfMemory;
    }

    const new_total_pages = paging.numPagesBetween(ptask.data_mem.base, addr);
    if (new_total_pages > ptask.data_mem.num_pages) {
        const additional_pages = new_total_pages - ptask.data_mem.num_pages;
        ptask.data_mem.growUp(additional_pages);
    } else if (new_total_pages < ptask.data_mem.num_pages) {
        const fewer_pages = ptask.data_mem.num_pages - new_total_pages;
        ptask.data_mem.shrinkFromEnd(fewer_pages);
    }

    ptask.heap_brk = addr;
    return addr;
}

fn sys_pipe(fds_slice_va: u32, _: u32) !u32 {
    const fds_slice = try task.getCurrentTask().readUserSlice(u32, fds_slice_va);
    if (fds_slice.len != 2) return error.InvalidArgument;

    const ptask = task.getCurrentTask();
    // Allocate fds first so failure can't leak an already created pipe later
    const read_fd, const write_fd = ptask.findFreeFdPair() orelse return error.ProcessFileTableFull;

    const pipe_fds = try filedesc.makePipe();

    ptask.setFdSlot(read_fd, pipe_fds.@"0");
    ptask.setFdSlot(write_fd, pipe_fds.@"1");

    fds_slice[0] = read_fd;
    fds_slice[1] = write_fd;
    return 0;
}

const FdRemap = abi.FdRemap;
const SpawnOpts = abi.SpawnOpts;

fn sys_spawn(argv_desc_ofs: u32, opts_ptr: u32) !u32 {
    const current_task = task.getCurrentTask();

    // read argv slice from userspace memory
    const argv_desc = try current_task.getUserPtr(abi.AbiSlice, argv_desc_ofs);
    const argc: usize = @intCast(argv_desc.len);
    if (argc == 0 or argc > abi.MAX_ARGV_COUNT) {
        return error.InvalidArgument;
    }

    const arg_slices = try current_task.getUserSlice(abi.AbiSlice, argv_desc.ptr, argv_desc.len);

    // count total bytes in argument strings for a single allocation
    var string_bytes: usize = 0;
    for (arg_slices, 0..) |arg_desc, i| {
        if (i == 0 and arg_desc.len == 0) return error.InvalidArgument; // command must not be empty
        string_bytes += arg_desc.len;
    }

    // Read fd remaps from userspace BEFORE loadUserspaceElf (while the parent page dir is active).
    // We copy them into a fixed kernel-side buffer so we can apply them after the ELF is loaded.
    var remap_buf: [filedesc.MAX_OPEN_FILES]FdRemap = undefined;
    var remap_count: usize = 0;
    if (opts_ptr != 0) {
        const opts = try current_task.getUserPtr(SpawnOpts, opts_ptr);
        if (opts.fd_remaps.len > remap_buf.len) return error.InvalidArgument;
        remap_count = @intCast(opts.fd_remaps.len);
        if (remap_count > 0) {
            const remaps = try current_task.getUserSlice(FdRemap, opts.fd_remaps.ptr, opts.fd_remaps.len);
            @memcpy(remap_buf[0..remap_count], remaps);
        }
    }

    // allocate buffers for the string storage and the slice objects
    const allocator = kernel.getAllocator();

    const arg_storage = try allocator.alloc(u8, string_bytes);
    defer allocator.free(arg_storage);

    const argv_buf = try allocator.alloc([]const u8, argc);
    defer allocator.free(argv_buf);

    // copy argv strings from userspace and store their slices in the argv_buf
    var cursor: usize = 0;
    for (arg_slices, 0..) |arg_desc, i| {
        const len: usize = @intCast(arg_desc.len);
        if (len == 0) {
            argv_buf[i] = arg_storage[cursor..cursor]; // empty slice
        } else {
            const arg_bytes = try current_task.getUserMem(arg_desc.ptr, arg_desc.len);
            const dest = arg_storage[cursor .. cursor + len];
            @memcpy(dest, arg_bytes);
            argv_buf[i] = dest;
            cursor += len;
        }
    }

    defer current_task.loadPageDir(); // make sure to return to the correct page directory
    const child = try kernel.loadUserspaceElf(argv_buf[0], argv_buf);
    child.parent_pid = current_task.pid;
    child.stdout_console = current_task.stdout_console;

    // Apply fd remaps: dupe each requested parent fd into the child's fd table.
    // Both fd tables are kernel memory; no page directory switch needed here.
    for (remap_buf[0..remap_count]) |remap| {
        const src_slot = current_task.getFdSlot(remap.src) orelse {
            child.terminate();
            return error.BadFd;
        };
        if (src_slot.* == .empty) {
            child.terminate();
            return error.BadFd;
        }
        const child_slot = child.getFdSlot(remap.dst) orelse {
            child.terminate();
            return error.BadFd;
        };
        child_slot.closeIfOpen();
        child_slot.* = src_slot.dupe();
    }

    return child.pid;
}

/// Blocks the calling task until the child with the given PID exits, then returns its exit status.
/// Returns InvalidArgument when the PID does not exist or is not a child of the caller.
fn sys_waitpid(pid: u32) !u32 {
    const current = task.getCurrentTask();
    const child = taskman.findTask(pid) orelse return error.InvalidArgument;
    if (child.parent_pid != current.pid) return error.InvalidArgument;

    if (child.state == .zombie) {
        // Child already exited; collect status and free slot.
        const status = child.exit_status;
        child.state = .free;
        child.pid = 0;
        return status;
    }

    // Child is still running; block until its exit handler wakes us.
    try current.waitInQueue(&child.waiters_for_pid);
    return kernel.kernel_yield();
}

fn sys_mkdir(path_slice_va: u32) !u32 {
    const path = try task.getCurrentTask().readUserSlice(u8, path_slice_va);
    return try kernel.getFileSystem().createDirectory(path);
}

fn sys_rmdir(path_slice_va: u32) !u32 {
    const path = try task.getCurrentTask().readUserSlice(u8, path_slice_va);
    try filedesc.removeDirectory(kernel.getFileSystem(), path);
    return 0;
}

fn sys_link(old_path_slice_va: u32, new_path_slice_va: u32) !u32 {
    const current_task = task.getCurrentTask();
    const old_path = try current_task.readUserSlice(u8, old_path_slice_va);
    const new_path = try current_task.readUserSlice(u8, new_path_slice_va);
    try filedesc.linkFile(kernel.getFileSystem(), old_path, new_path);
    return 0;
}

/// Marks the current task so that all its children are auto-reaped on exit
/// rather than becoming zombies. Analogous to ignoring SIGCHLD on Linux.
fn sys_set_child_reap() !u32 {
    task.getCurrentTask().reap_children = true;
    return 0;
}

/// Executes a kernel shell command using the calling task's console.
/// Accepts a userspace pointer to an AbiSlice describing the command string.
fn sys_kshell(cmdline_slice_va: u32) !u32 {
    const current = task.getCurrentTask();
    const cmdline = try current.readUserSlice(u8, cmdline_slice_va);

    // Get the task's console or use the primary console as fallback
    const task_console = current.stdout_console orelse &@import("console.zig").primary;

    // Create a shell instance with the task's console
    var kshell = shell.Shell{
        .alloc = kernel.getAllocator(),
        .disk_fs = kernel.getFileSystem(),
        .console = task_console,
    };

    // Execute the command
    try shell.handleCommand(&kshell, cmdline);

    return 0;
}

/// Returns the console cursor position of the calling task packed as (row<<16)|col.
fn sys_getcursor() u32 {
    const cur = task.getCurrentTask();
    const con = cur.stdout_console orelse &console.primary;
    return (con.row << 16) | con.col;
}

fn sys_yield() u32 {
    _ = kernel.kernel_yield();
    return 0;
}

/// Dispatches the int 0x80 syscall ABI invoked by user-mode executables.
pub fn syscall_dispatch(frame: *interrupt_frame.UserInterruptFrame) void {
    const nr: Syscall = @enumFromInt(frame.interrupt.regs.eax);
    const arg1 = frame.interrupt.regs.ebx;
    const arg2 = frame.interrupt.regs.ecx;
    const arg3 = frame.interrupt.regs.edx;
    const retval = (switch (nr) {
        .Close => sys_close(arg1),
        .Exit => kernel.exitCurrentTask(arg1),
        .Stat => sys_stat(arg1, arg2),
        .Fstat => sys_fstat(arg1, arg2),
        .GetPid => task.getCurrentTask().pid,
        .Lseek => sys_lseek(arg1, arg2, arg3),
        .Brk => sys_brk(arg1),
        .Pipe => sys_pipe(arg1, arg2),
        .Open => sys_open(arg1, arg2, arg3),
        .Read => sys_read(arg1, arg2, arg3),
        .Write => sys_write(arg1, arg2, arg3),
        .Unlink => sys_unlink(arg1, arg2),
        .Ftruncate => sys_ftruncate(arg1, arg2),
        .WaitPid => sys_waitpid(arg1),
        .Mkdir => sys_mkdir(arg1),
        .Rmdir => sys_rmdir(arg1),
        .Link => sys_link(arg1, arg2),
        .SetChildReap => sys_set_child_reap(),
        .Yield => sys_yield(),
        .Spawn => sys_spawn(arg1, arg2),
        .KShell => sys_kshell(arg1),
        .GetCursor => sys_getcursor(),
        else => error.InvalidArgument,
    }) catch |err| mapError(err);
    frame.setReturnValue(retval);
}
