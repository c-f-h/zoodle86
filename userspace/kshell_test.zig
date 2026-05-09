//! Test program for the kshell syscall.
//! Demonstrates executing kernel shell commands from userspace.

const sys = @import("sys.zig");

/// Entry point that tests the kshell syscall with several commands.
pub fn main() void {
    const stdout = sys.STDOUT;
    
    _ = sys.write(stdout, "=== KShell Syscall Test ===\n");
    
    // Test 1: Execute help command
    _ = sys.write(stdout, "Executing 'help' command...\n");
    _ = sys.kshell("help");
    
    // Test 2: Execute memstat command
    _ = sys.write(stdout, "\nExecuting 'memstat' command...\n");
    _ = sys.kshell("memstat");
    
    // Test 3: Execute ps command
    _ = sys.write(stdout, "\nExecuting 'ps' command...\n");
    _ = sys.kshell("ps");
    
    _ = sys.write(stdout, "\n=== Test Complete ===\n");
}
