const std = @import("std");

pub const OptResult = union(enum) {
    Bool: *bool,
    UInt32: *u32,
};

pub const OptSpec = struct {
    short: ?u8 = null,
    long: ?[]const u8 = null,
    result: OptResult,
};

/// Parse command-line options from argv according to the given specifications.
/// Returns the index of the first non-option argument, or error.InvalidArgs if parsing fails.
pub noinline fn parseOpts(argv: []const []const u8, specs: []const OptSpec) error{InvalidArgs}!u32 {
    // Must be noinline for now because of a Zig codegen issue:
    // https://codeberg.org/ziglang/zig/issues/35560
    var i: u32 = 1;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg.len < 2 or arg[0] != '-') break;

        var matched = false;
        for (specs) |spec| {
            const is_match =
                (if (spec.short) |short|
                    arg.len == 2 and arg[1] == short
                else
                    false) or
                (if (spec.long) |long|
                    arg.len > 2 and arg[0] == '-' and arg[1] == '-' and
                        std.mem.eql(u8, arg[2..], long)
                else
                    false);
            if (is_match) {
                switch (spec.result) {
                    .Bool => |ptr| {
                        ptr.* = true;
                        matched = true;
                    },
                    .UInt32 => |ptr| {
                        i += 1;
                        if (i >= argv.len) return error.InvalidArgs;
                        ptr.* = std.fmt.parseUnsigned(u32, argv[i], 10) catch return error.InvalidArgs;
                        matched = true;
                    },
                }
            }
        }

        if (!matched) return error.InvalidArgs;
        i += 1;
    }
    return i;
}
