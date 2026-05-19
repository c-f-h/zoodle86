const char_device = @import("char_device.zig");
const abi = @import("abi");

pub const NULL_DEVICE_MINOR = 3;

pub fn getMemoryDevice(minor: u8) error{NoDevice}!*char_device.CharDevice {
    switch (minor) {
        NULL_DEVICE_MINOR => return &null_device.char_dev,
        else => return error.NoDevice,
    }
}

pub var null_device: NullDevice = .{};

const NullDevice = struct {
    char_dev: char_device.CharDevice = .{
        .vtable = &vtable,
        .device = abi.Device{
            .major = abi.DeviceMajor.Memory,
            .minor = NULL_DEVICE_MINOR,
        },
    },

    const vtable = char_device.CharDevice.VTable{
        .read = &read,
        .write = &write,
        .ioctl = &ioctl,
        .bufferSize = &bufferSize,
        .size = &size,
        .seekable = &seekable,
    };

    fn read(_: *char_device.CharDevice, _: u32, _: []u8) char_device.CharDeviceError!usize {
        return 0; // always report EOF
    }

    fn write(_: *char_device.CharDevice, _: u32, src: []const u8) char_device.CharDeviceError!usize {
        return src.len;
    }

    fn ioctl(_: *char_device.CharDevice, _: u32, _: u32) char_device.CharDeviceError!u32 {
        return char_device.CharDeviceError.InvalidArgument;
    }

    fn bufferSize(_: *const char_device.CharDevice) usize {
        return 4096;
    }

    fn size(_: *const char_device.CharDevice) u32 {
        return 0;
    }

    fn seekable(_: *const char_device.CharDevice) bool {
        return false;
    }
};
