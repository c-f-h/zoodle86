/// Saved general-purpose register state in the order produced by `pushad`.
pub const GeneralRegisters = extern struct {
    edi: u32 = 0,
    esi: u32 = 0,
    ebp: u32 = 0,
    esp: u32 = 0,
    ebx: u32 = 0,
    edx: u32 = 0,
    ecx: u32 = 0,
    eax: u32 = 0,
};

/// Normalized interrupt/trap frame prefix built by low-level entry stubs.
/// It always includes a vector number and an error-code slot (0 when synthetic).
pub const InterruptFrame = extern struct {
    regs: GeneralRegisters,
    es: u32,
    ds: u32,
    vector: u32,
    error_code: u32,
    // Everything below here is consumed by iretd to return to the interrupted context
    // If cs comes from user mode, also the UserStackTail is consumed to restore the user mode stack.
    eip: u32,
    cs: u32,
    eflags: u32,

    /// Returns whether the interrupted context was user mode.
    pub fn fromUserMode(frame: *const InterruptFrame) bool {
        return (frame.cs & 3) == 3;
    }
};

/// Optional hardware-pushed tail present when the CPU switched privilege levels.
pub const UserStackTail = extern struct {
    user_esp: u32,
    user_ss: u32,
};

/// Full user-mode return frame used for syscalls, task startup, and task resume.
pub const UserInterruptFrame = extern struct {
    interrupt: InterruptFrame,
    user: UserStackTail,

    /// Writes the userspace return value that will be restored into EAX.
    pub fn setReturnValue(frame: *UserInterruptFrame, value: u32) void {
        frame.interrupt.regs.eax = value;
    }
};

/// Frame used to resume a sleeping task in kernel_yield_trampoline. Pointed to by Task.kernel_esp.
pub const KernelFrame = extern struct {
    regs: GeneralRegisters,
    kernel_eip: u32,
};
