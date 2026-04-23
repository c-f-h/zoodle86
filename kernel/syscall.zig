const filedesc = @import("filedesc.zig");
const kernel = @import("kernel.zig");
const paging = @import("paging.zig");
const task = @import("task.zig");
const std = @import("std");

const Syscall = enum(u32) {
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Lseek = 8,
    Brk = 12, // change program heap size
    Yield = 24,
    GetPid = 39,
    Exit = 60,
    Unlink = 87,
    Spawn = 1001,
    _,
};

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
        error.FileExists => ERRNO_EEXIST,
        error.FileNotFound => ERRNO_ENOENT,
        error.InvalidFlags => ERRNO_EINVAL,
        error.InvalidLba => ERRNO_EIO,
        error.InvalidName => ERRNO_EINVAL,
        error.InvalidSeek => ERRNO_EINVAL,
        error.InvalidSuperblock => ERRNO_EIO,
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

fn sys_open(path_ofs: u32, path_len: u32, flags: u32) u32 {
    const path = task.getCurrentTask().getUserMem(path_ofs, path_len) catch |err| return mapError(err);
    return filedesc.openFile(kernel.getFileSystem(), task.getCurrentTask(), path, flags) catch |err| mapError(err);
}

fn sys_close(fd: u32) u32 {
    filedesc.closeFile(task.getCurrentTask(), fd) catch |err| return mapError(err);
    return 0;
}

fn sys_unlink(path_ofs: u32, path_len: u32) u32 {
    const path = task.getCurrentTask().getUserMem(path_ofs, path_len) catch |err| return mapError(err);
    filedesc.unlinkFile(kernel.getFileSystem(), path) catch |err| return mapError(err);
    return 0;
}

fn sys_read(fd: u32, ofs: u32, count: u32) u32 {
    const dest = task.getCurrentTask().getUserMem(ofs, count) catch |err| return mapError(err);
    return @intCast(filedesc.readFile(kernel.getFileSystem(), task.getCurrentTask(), fd, dest) catch |err| return mapError(err));
}

fn sys_write(fd: u32, ofs: u32, count: u32) u32 {
    const data = task.getCurrentTask().getUserMem(ofs, count) catch |err| return mapError(err);
    return @intCast(filedesc.writeFile(kernel.getFileSystem(), kernel.getAllocator(), task.getCurrentTask(), fd, data) catch |err| return mapError(err));
}

fn sys_lseek(fd: u32, offset_bits: u32, whence: u32) u32 {
    const offset: i32 = @bitCast(offset_bits);
    return filedesc.seekFile(kernel.getFileSystem(), task.getCurrentTask(), fd, offset, whence) catch |err| mapError(err);
}

fn sys_brk(addr: u32) u32 {
    const ptask = task.getCurrentTask();
    if (addr == 0) {
        return ptask.heap_brk;
    }
    if (addr < ptask.heap_start) {
        return errnoResult(ERRNO_EINVAL);
    }
    if (addr > ptask.stack_bottom) {
        return errnoResult(ERRNO_ENOMEM);
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

fn sys_spawn(argv_desc_ofs: u32) u32 {
    const current_task = task.getCurrentTask();

    // read argv slice from userspace memory
    const argv_desc = current_task.getUserPtr(task.AbiSlice, argv_desc_ofs) catch |err| return mapError(err);
    const argc: usize = @intCast(argv_desc.len);
    if (argc == 0 or argc > task.MAX_ARGV_COUNT) {
        return errnoResult(ERRNO_EINVAL);
    }

    const arg_slices = current_task.getUserSlice(task.AbiSlice, argv_desc.ptr, argv_desc.len) catch |err| return mapError(err);

    // count total bytes in argument strings for a single allocation
    var string_bytes: usize = 0;
    for (arg_slices, 0..) |arg_desc, i| {
        if (i == 0 and arg_desc.len == 0) return errnoResult(ERRNO_EINVAL); // command must not be empty
        string_bytes += arg_desc.len;
    }

    // allocate buffers for the string storage and the slice objects
    const allocator = kernel.getAllocator();

    const arg_storage = allocator.alloc(u8, string_bytes) catch |err| return mapError(err);
    defer allocator.free(arg_storage);

    const argv_buf = allocator.alloc([]const u8, argc) catch |err| return mapError(err);
    defer allocator.free(argv_buf);

    // copy argv strings from userspace and store their slices in the argv_buf
    var cursor: usize = 0;
    for (arg_slices, 0..) |arg_desc, i| {
        const len: usize = @intCast(arg_desc.len);
        if (len == 0) {
            argv_buf[i] = arg_storage[cursor..cursor]; // empty slice
        } else {
            const arg_bytes = current_task.getUserMem(arg_desc.ptr, arg_desc.len) catch |err| return mapError(err);
            const dest = arg_storage[cursor .. cursor + len];
            @memcpy(dest, arg_bytes);
            argv_buf[i] = dest;
            cursor += len;
        }
    }

    defer current_task.loadPageDir(); // make sure to return to the correct page directory
    const child = kernel.loadUserspaceElf(argv_buf[0], argv_buf) catch |err| return mapError(err);
    return child.pid;
}

/// Dispatches the int 0x80 syscall ABI invoked by user-mode executables.
pub export fn syscall_dispatch(nr: Syscall, arg1: u32, arg2: u32, arg3: u32) callconv(.c) u32 {
    return switch (nr) {
        .Close => sys_close(arg1),
        .Exit => {
            task.getCurrentTask().terminate();
            kernel.reschedule();
        },
        .GetPid => task.getCurrentTask().pid,
        .Lseek => sys_lseek(arg1, arg2, arg3),
        .Brk => sys_brk(arg1),
        .Open => sys_open(arg1, arg2, arg3),
        .Read => sys_read(arg1, arg2, arg3),
        .Write => sys_write(arg1, arg2, arg3),
        .Unlink => sys_unlink(arg1, arg2),
        .Yield => kernel.reschedule(),
        .Spawn => sys_spawn(arg1),
        else => errnoResult(ERRNO_EINVAL),
    };
}
