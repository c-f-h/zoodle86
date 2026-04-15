// Identity-mapped paging module.
// Provides minimal static page directory and pre-allocated page tables for identity mapping.
// 32 page tables cover ~128MB of physical RAM.

/// Page Directory Entry (32 bits) - each one points to 1024 Page Table Entries (or is 0)
pub const PDE = packed struct {
    present: bool = true,
    writable: bool,
    user: bool,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    _reserved: u1 = 0,
    page_size: bool = false, // 0 = 4KB pages, 1 = 4MB pages
    _ignored: u4 = 0,
    page_table_addr: u20, // physical address of page table >> 12
};

/// Page Table Entry (32 bits)
pub const PTE = packed struct {
    present: bool = true,
    writable: bool,
    user: bool,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    page_size: bool = false, // true enables 4 MiB pages
    global: bool = false,
    _ignored: u3 = 0,
    page_addr: u20, // physical address >> 12
};

pub const PageTable = [1024]PTE; // 4 KiB - covers 4 MiB of RAM
pub const PageDirectory = [1024]PDE; // 4 KiB - covers the whole 4 GiB address space

// Fixed virtual memory locations for recursively mapped PageDirectory (PDE[1023] -> PD)
const mapped_pd = @as(*PageDirectory, @ptrFromInt(0xFFFFF000));
const mapped_pts = @as(*[1024]PageTable, @ptrFromInt(0xFFC00000));

// Assumes that the current PD is recursively mapped.
// Gets a pointer to the PTE within whose frame the given virtual address lives.
fn getPte(va: u32) *PTE {
    // virtual address: [ table (10 bits) | page (10 bits) | offset (12 bits) ]
    const pd_index = (va >> 22) & 0x3FF;
    const pt_index = (va >> 12) & 0x3FF;
    return &mapped_pts[pd_index][pt_index];
}

/// Enable paging. page_dir_phys is the physical address of the Page Directory
pub inline fn enable(page_dir_phys: u32) void {
    asm volatile (
        \\ mov %[pdir], %%cr3     // enable paging
        \\ mov %%cr0, %%eax
        \\ or $0x80000000, %%eax
        \\ mov %%eax, %%cr0
        :
        : [pdir] "r" (page_dir_phys),
        : .{ .eax = true });
}

/// 32 static 4KB-aligned page tables covering ~128 MB
//var page_tables: [32]PageTable align(4096) = undefined; // 128 KiB

/// Initialize identity mapping: all physical addresses map 1:1 to virtual addresses.
/// max_addr is the highest physical address to map (in bytes).
/// Returns the physical address of the page directory.
pub inline fn initIdentityPaging(page_dir: *PageDirectory, tables: *[32]PageTable, max_addr: u32) void {
    const page_dir_size = 4 * 1024 * 1024; // 4MiB covered per page directory
    // number of tables required to cover the desired physical memory space
    const num_tables: u32 = @min((max_addr + page_dir_size - 1) / page_dir_size, tables.len);

    // Initialize page directory: each entry points to a page table
    for (0..1024) |i| {
        if (i < num_tables) {
            const pt_phys = @intFromPtr(&tables[i]); // physical page table address
            page_dir[i] = PDE{
                .writable = true,
                .user = false,
                .page_table_addr = @truncate(pt_phys >> 12),
            };
        } else if (i >= 3 * 256 and i < 3 * 256 + num_tables) {
            // second mapping from 0xC0000000 (virtual) -> 0 (physical)
            page_dir[i] = page_dir[i - 3 * 256];
        } else {
            page_dir[i] = @bitCast(@as(u32, 0));
        }
        // Recursive mapping (exploits identical layout of PDE and PTE):
        // - i-th page table is accessible at 0xFFC00000 + i * 0x1000 (last 4 MiB of address space)
        // - page directory itself is in the last slot at 0xFFFFF000
        page_dir[1023] = PDE{
            .writable = true,
            .user = false,
            .page_table_addr = @truncate(@intFromPtr(page_dir) >> 12),
        };
    }

    // Initialize page tables: each entry maps a 4KiB page identity
    for (0..num_tables) |t| {
        for (0..1024) |p| {
            const page_index = t * 1024 + p;
            const phys_addr = page_index * 4096;

            if (phys_addr < max_addr) {
                tables[t][p] = PTE{
                    .writable = true,
                    .user = false,
                    .page_addr = @truncate(phys_addr >> 12),
                };
            } else {
                tables[t][p] = @bitCast(@as(u32, 0));
            }
        }
    }
}

/// Mark a physical memory range as user-accessible by setting the user bit (U/S) in both
/// page directory entries and page table entries.
pub fn markUserAccessible(page_dir: *PageDirectory, tables: *[32]PageTable, start_addr: u32, end_addr: u32) void {
    const start_page = start_addr >> 12;
    const end_page = (end_addr + 4095) >> 12;

    var marked_pde_indices = [1]bool{false} ** 32;

    // Mark PTEs and track which PDEs we need to mark
    for (start_page..end_page) |page_index| {
        const table_index = page_index / 1024;
        const entry_index = page_index % 1024;

        if (table_index < tables.len) {
            tables[table_index][entry_index].user = true;
            marked_pde_indices[table_index] = true;
        }
    }

    // Mark the corresponding PDEs as user-accessible
    for (0..tables.len) |table_index| {
        if (marked_pde_indices[table_index]) {
            page_dir[table_index].user = true;
        }
    }
}

/// Simple page fault handler: print faulting address and error code, then halt.
pub export fn page_fault_handler(vector: u8, errcode: u32, eip: u32, cs: u16) callconv(.c) noreturn {
    _ = vector;
    _ = cs;
    _ = eip;

    const console = @import("console.zig");
    console.puts("\n!!! PAGE FAULT !!!\n");
    console.puts("Error code: ");
    console.putHexU32(errcode);
    console.puts("\n");

    // Read CR2 to get faulting address
    const cr2 = asm volatile ("mov %%cr2, %%eax"
        : [ret] "={eax}" (-> u32),
    );
    console.puts("Faulting address: ");
    console.putHexU32(cr2);
    console.puts("\n");

    console.puts("Halting.\n");
    while (true) {
        asm volatile ("hlt");
    }
}
