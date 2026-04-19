const filedesc = @import("filedesc.zig");
const kernel = @import("kernel.zig");
const task = @import("task.zig");

const Syscall = enum(u32) {
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Lseek = 8,
    Yield = 24,
    GetPid = 39,
    Exit = 60,
    Unlink = 87,
    _,
};

const ERRNO_EIO: u32 = 5;
const ERRNO_ENOENT: u32 = 2;
const ERRNO_ENOMEM: u32 = 12;
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
        error.BadFd => ERRNO_EBADF,
        error.FileInUse => ERRNO_EBUSY,
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
    const path = task.getCurrentTask().getUserMem(path_ofs, path_len);
    return filedesc.openFile(kernel.getFileSystem(), task.getCurrentTask(), path, flags) catch |err| mapError(err);
}

fn sys_close(fd: u32) u32 {
    filedesc.closeFile(task.getCurrentTask(), fd) catch |err| return mapError(err);
    return 0;
}

fn sys_unlink(path_ofs: u32, path_len: u32) u32 {
    const path = task.getCurrentTask().getUserMem(path_ofs, path_len);
    filedesc.unlinkFile(kernel.getFileSystem(), path) catch |err| return mapError(err);
    return 0;
}

fn sys_read(fd: u32, ofs: u32, count: u32) u32 {
    const dest = task.getCurrentTask().getUserMem(ofs, count);
    return @intCast(filedesc.readFile(kernel.getFileSystem(), task.getCurrentTask(), fd, dest) catch |err| return mapError(err));
}

fn sys_write(fd: u32, ofs: u32, count: u32) u32 {
    const data = task.getCurrentTask().getUserMem(ofs, count);
    return @intCast(filedesc.writeFile(kernel.getFileSystem(), kernel.getAllocator(), task.getCurrentTask(), fd, data) catch |err| return mapError(err));
}

fn sys_lseek(fd: u32, offset_bits: u32, whence: u32) u32 {
    const offset: i32 = @bitCast(offset_bits);
    return filedesc.seekFile(kernel.getFileSystem(), task.getCurrentTask(), fd, offset, whence) catch |err| mapError(err);
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
        .Open => sys_open(arg1, arg2, arg3),
        .Read => sys_read(arg1, arg2, arg3),
        .Write => sys_write(arg1, arg2, arg3),
        .Unlink => sys_unlink(arg1, arg2),
        .Yield => kernel.reschedule(),
        else => errnoResult(ERRNO_EINVAL),
    };
}
