/// POC kernel module.
/// This is a minimal proof-of-concept that demonstrates a separately-compiled
/// kernel module being loaded from the filesystem and called by the stage2 loader.
/// Returns a known magic value so the caller can confirm it executed correctly.
pub export fn kernel_init() callconv(.c) u32 {
    return 0x200D1E86;
}
