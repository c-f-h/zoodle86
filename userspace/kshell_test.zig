const sys = @import("sys.zig");

/// Entry point that tests the kshell syscall with several commands.
pub fn main(_: []const []const u8) !void {
    const stdout = sys.STDOUT;

    _ = try sys.write(stdout, "=== KShell Syscall Test ===\n");

    // Test 1: Execute help command
    _ = try sys.write(stdout, "Executing 'help' command...\n");
    try sys.kshell("help");

    // Test 2: Execute memstat command
    _ = try sys.write(stdout, "\nExecuting 'memstat' command...\n");
    try sys.kshell("memstat");

    // Test 3: Execute memmap command
    _ = try sys.write(stdout, "\nExecuting 'memmap' command...\n");
    try sys.kshell("memmap");

    _ = try sys.write(stdout, "\n=== Test Complete ===\n");
}

comptime {
    _ = sys._start;
}
