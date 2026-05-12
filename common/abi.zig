const std = @import("std");

/// Stable 32-bit ABI slice representation used for argv passing and syscall arguments.
pub const AbiSlice = extern struct {
    ptr: u32,
    len: u32,

    /// Reinterprets this ABI slice as a typed slice in the current address space.
    pub fn toSlice(slice: *const AbiSlice, comptime T: type) []const T {
        return @as([*]const T, @ptrFromInt(slice.ptr))[0..slice.len];
    }

    /// Encodes a typed slice into the stable ABI representation.
    pub fn fromSlice(comptime T: type, s: []const T) AbiSlice {
        return .{
            .ptr = @intFromPtr(s.ptr),
            .len = @intCast(s.len),
        };
    }
};

/// Maximum number of arguments supported in the argv startup array.
pub const MAX_ARGV_COUNT = 128;
pub const DIRENT_NAME_MAX: usize = 16;

/// Userspace-visible syscall numbers dispatched through int 0x80.
pub const Syscall = enum(u32) {
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Stat = 4,
    Fstat = 5,
    Lseek = 8,
    Brk = 12,
    Pipe = 22,
    Yield = 24,
    DupFd = 33,
    GetPid = 39,
    Exit = 60,
    WaitPid = 61,
    GetDents = 78,
    Mkdir = 83,
    Rmdir = 84,
    Link = 86,
    Unlink = 87,
    Rename = 82,
    Ftruncate = 93,
    Ioctl = 156,
    Spawn = 1001,
    SetChildReap = 1002,
    KShell = 1003,
    GetCursor = 1004,
    _,
};

/// Ioctl request numbers
pub const IOCTL_TTY_SET_MODE: u32 = 1;

pub const TTY_MODE_CANONICAL: u32 = 0;
pub const TTY_MODE_RAW: u32 = 1;

/// Userspace-visible errno values returned in `ecx` after a syscall.
pub const Errno = enum(u32) {
    Success = 0,
    ENOENT = 2,
    EIO = 5,
    E2BIG = 7,
    EBADF = 9,
    EAGAIN = 11,
    ENOMEM = 12,
    EACCES = 13,
    EFAULT = 14,
    EBUSY = 16,
    EEXIST = 17,
    ENOTDIR = 20,
    EISDIR = 21,
    EINVAL = 22,
    ENFILE = 23,
    EMFILE = 24,
    ENOSPC = 28,
    ENOTEMPTY = 39,
    _,
};

/// Selects the access mode encoded in userspace open flags.
pub const FileOpenMode = enum(u2) {
    ReadOnly = 0,
    WriteOnly = 1,
    ReadWrite = 2,
};

/// Encodes the userspace `open` syscall flags in a typed form.
pub const FileOpenFlags = packed struct(u32) {
    open_mode: FileOpenMode = .ReadOnly,
    reserved0: u4 = 0,
    create: bool = false,
    reserved1: u2 = 0,
    truncate: bool = false,
    append: bool = false,
    reserved2: u21 = 0,
};

pub const O_RDONLY: u32 = @intFromEnum(FileOpenMode.ReadOnly);
pub const O_WRONLY: u32 = @intFromEnum(FileOpenMode.WriteOnly);
pub const O_RDWR: u32 = @intFromEnum(FileOpenMode.ReadWrite);
pub const O_ACCMODE: u32 = 0x3;
pub const O_CREAT: u32 = @as(u32, 1) << 6;
pub const O_TRUNC: u32 = @as(u32, 1) << 9;
pub const O_APPEND: u32 = @as(u32, 1) << 10;

/// Selects the reference point used by the `lseek` syscall.
pub const SeekWhence = enum(u32) {
    Set = 0,
    Cur = 1,
    End = 2,
};

pub const SEEK_SET: u32 = @intFromEnum(SeekWhence.Set);
pub const SEEK_CUR: u32 = @intFromEnum(SeekWhence.Cur);
pub const SEEK_END: u32 = @intFromEnum(SeekWhence.End);

/// Categorizes the underlying object described by `Stat`.
pub const InodeKind = enum(u8) {
    Free = 0,
    Regular = 1,
    Directory = 2,
    CharDevice = 3,
    BlockDevice = 4,
    Pipe = 5,
    Symlink = 6,
};

pub const STAT_FLAG_READABLE: u8 = 1 << 0;
pub const STAT_FLAG_WRITABLE: u8 = 1 << 1;
pub const STAT_FLAG_APPEND: u8 = 1 << 2;
pub const STAT_FLAG_SYNTHETIC: u8 = 1 << 3;

pub const DeviceMajor = enum(u8) {
    Unnamed = 0,
    Ide = 3,
    Tty = 4,
};

pub const Device = extern struct {
    major: DeviceMajor = .Unnamed,
    minor: u8 = 0,

    pub fn isEmpty(self: Device) bool {
        return self.major == .Unnamed and self.minor == 0;
    }
};

/// Stable stat-like file metadata returned by `stat` and `fstat`.
pub const Stat = extern struct {
    inode: u32,
    size: u32,
    blocks: u32,
    blksize: u32,
    nlink: u32,
    on_device: Device, // device ID of the filesystem containing this file
    device: Device, // device ID - only valid for character and block devices, otherwise {0, 0}
    kind: InodeKind,
    flags: u8,
};

/// Fixed-size directory entry record returned by the getdents syscall.
pub const DirEntry = extern struct {
    inode: u32,
    size: u32,
    kind: InodeKind,
    name_len: u8,
    reserved: [6]u8 = @splat(0),
    name: [DIRENT_NAME_MAX]u8 = @splat(0),
};

/// A compact key event delivered via the keyboard event pipe. Exactly 4 bytes.
pub const KeyEvent = extern struct {
    keycode: u16,
    modifiers: u8,
    ascii: u8,
};

// Virtual key codes delivered in KeyEvent.keycode.
pub const VK_BACKSPACE: u16 = 0x0E;
pub const VK_TAB: u16 = 0x0F;
pub const VK_ENTER: u16 = 0x1C;
pub const VK_LCTRL: u16 = 0x1D;
pub const VK_LSHIFT: u16 = 0x2A;
pub const VK_RSHIFT: u16 = 0x36;
pub const VK_LALT: u16 = 0x38;
pub const VK_ESC: u16 = 0x01;
pub const VK_SPACE: u16 = 0x39;
pub const VK_A: u16 = 0x1E;
pub const VK_B: u16 = 0x30;
pub const VK_C: u16 = 0x2E;
pub const VK_D: u16 = 0x20;
pub const VK_E: u16 = 0x12;
pub const VK_F: u16 = 0x21;
pub const VK_G: u16 = 0x22;
pub const VK_H: u16 = 0x23;
pub const VK_I: u16 = 0x17;
pub const VK_J: u16 = 0x24;
pub const VK_K: u16 = 0x25;
pub const VK_L: u16 = 0x26;
pub const VK_M: u16 = 0x32;
pub const VK_N: u16 = 0x31;
pub const VK_O: u16 = 0x18;
pub const VK_P: u16 = 0x19;
pub const VK_Q: u16 = 0x10;
pub const VK_R: u16 = 0x13;
pub const VK_S: u16 = 0x1F;
pub const VK_T: u16 = 0x14;
pub const VK_U: u16 = 0x16;
pub const VK_V: u16 = 0x2F;
pub const VK_W: u16 = 0x11;
pub const VK_X: u16 = 0x2D;
pub const VK_Y: u16 = 0x15;
pub const VK_Z: u16 = 0x2C;

// Extended keys (top byte 0xE0).
pub const VK_EXTENDED: u16 = 0xE000;

pub const VK_KEYPAD_ENTER = VK_EXTENDED | 0x1C;
pub const VK_RCTRL = VK_EXTENDED | 0x1D;
pub const VK_KEYPAD_SLASH = VK_EXTENDED | 0x35;
pub const VK_RALT = VK_EXTENDED | 0x38;
pub const VK_HOME: u16 = VK_EXTENDED | 0x47;
pub const VK_UP: u16 = VK_EXTENDED | 0x48;
pub const VK_LEFT: u16 = VK_EXTENDED | 0x4B;
pub const VK_RIGHT: u16 = VK_EXTENDED | 0x4D;
pub const VK_END: u16 = VK_EXTENDED | 0x4F;
pub const VK_DOWN: u16 = VK_EXTENDED | 0x50;
pub const VK_DELETE: u16 = VK_EXTENDED | 0x53;

// Modifier flags in KeyEvent.modifiers.
pub const MOD_SHIFT: u8 = 0x01;
pub const MOD_ALT: u8 = 0x02;
pub const MOD_CTRL: u8 = 0x04;

comptime {
    std.debug.assert(@sizeOf(KeyEvent) == 4);
    std.debug.assert(@sizeOf(DirEntry) == 32);
}

/// A (dst, src) fd-index pair used to remap descriptors during spawn.
pub const FdRemap = extern struct {
    dst: u32,
    src: u32,
};

/// Optional per-spawn options passed through the userspace ABI.
pub const SpawnOpts = extern struct {
    fd_remaps: AbiSlice,
};
