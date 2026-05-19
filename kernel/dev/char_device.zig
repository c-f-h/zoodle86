const abi = @import("abi");

/// Generic errors surfaced by character-device operations.
pub const CharDeviceError = error{
    AccessViolation,
    InvalidArgument,
    InvalidSeek,
    NoDevice,
    OutOfMemory,
};

/// Abstract character device.
///
/// Concrete implementations embed this struct as a field named `char_dev` and
/// recover the parent struct from vtable callbacks via `@fieldParentPtr`.
pub const CharDevice = struct {
    vtable: *const VTable,
    device: abi.Device,

    pub const VTable = struct {
        read: *const fn (self: *CharDevice, offset: u32, dest: []u8) CharDeviceError!usize,
        write: *const fn (self: *CharDevice, offset: u32, src: []const u8) CharDeviceError!usize,
        ioctl: *const fn (self: *CharDevice, command: u32, arg: u32) CharDeviceError!u32,
        bufferSize: *const fn (self: *const CharDevice) usize,
        size: *const fn (self: *const CharDevice) u32,
        seekable: *const fn (self: *const CharDevice) bool,
    };

    /// Read bytes from the device into `dest`.
    pub fn read(self: *CharDevice, offset: u32, dest: []u8) CharDeviceError!usize {
        return self.vtable.read(self, offset, dest);
    }

    /// Write bytes from `src` to the device.
    pub fn write(self: *CharDevice, offset: u32, src: []const u8) CharDeviceError!usize {
        return self.vtable.write(self, offset, src);
    }

    /// Apply a device-specific ioctl command.
    pub fn ioctl(self: *CharDevice, command: u32, arg: u32) CharDeviceError!u32 {
        return self.vtable.ioctl(self, command, arg);
    }

    /// Return the preferred block size reported by `stat`.
    pub fn bufferSize(self: *const CharDevice) usize {
        return self.vtable.bufferSize(self);
    }

    /// Return the total byte size reported by this device.
    pub fn size(self: *const CharDevice) u32 {
        return self.vtable.size(self);
    }

    /// Return whether this device supports descriptor-local seek offsets.
    pub fn seekable(self: *const CharDevice) bool {
        return self.vtable.seekable(self);
    }
};
