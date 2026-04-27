/// Raw register output of a CPUID query.
pub const Result = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Basic CPUID vendor information reported by leaf 0.
pub const VendorInfo = struct {
    max_basic_leaf: u32,
    vendor: [12]u8,
};

// From interrupts.asm
extern fn cpuid_query(leaf: u32, subleaf: u32, out: *Result) callconv(.c) void;

/// Execute the CPUID instruction for the requested leaf and subleaf.
pub fn query(leaf: u32, subleaf: u32) Result {
    var result: Result = undefined;

    cpuid_query(leaf, subleaf, &result);
    return result;
}

/// Return the maximum basic CPUID leaf together with the 12-byte vendor string.
pub fn vendorInfo() VendorInfo {
    const regs = query(0, 0);
    var info = VendorInfo{
        .max_basic_leaf = regs.eax,
        .vendor = undefined,
    };

    storeU32LE(info.vendor[0..4], regs.ebx);
    storeU32LE(info.vendor[4..8], regs.edx);
    storeU32LE(info.vendor[8..12], regs.ecx);
    return info;
}

/// Return the maximum extended CPUID leaf, or 0 if extended leaves are unavailable.
pub fn maxExtendedLeaf() u32 {
    return query(0x8000_0000, 0).eax;
}

fn storeU32LE(dest: []u8, value: u32) void {
    dest[0] = @truncate(value & 0xFF);
    dest[1] = @truncate((value >> 8) & 0xFF);
    dest[2] = @truncate((value >> 16) & 0xFF);
    dest[3] = @truncate((value >> 24) & 0xFF);
}
