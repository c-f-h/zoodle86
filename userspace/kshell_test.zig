const sys = @import("sys.zig");

/// Entry point that tests the kshell syscall with several commands.
pub fn main(_: []const []const u8) !void {
    const stdout = sys.STDOUT;

    _ = sys.write(stdout, "=== KShell Syscall Test ===\n");

    // Test 1: Execute help command
    _ = sys.write(stdout, "Executing 'help' command...\n");
    _ = sys.kshell("help");

    // Test 2: Execute memstat command
    _ = sys.write(stdout, "\nExecuting 'memstat' command...\n");
    _ = sys.kshell("memstat");

    // Test 3: Execute memmap command
    _ = sys.write(stdout, "\nExecuting 'memmap' command...\n");
    _ = sys.kshell("memmap");

    _ = sys.write(stdout, "\n=== Test Complete ===\n");
}

comptime {
    _ = sys._start;
}
