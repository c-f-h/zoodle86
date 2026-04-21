const pageallocator = @import("pageallocator.zig");
const serial = @import("serial.zig");
const task = @import("task.zig");

// Identity-mapped paging module.
// Provides minimal static page directory and pre-allocated page tables for identity mapping.

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

    pub inline fn getPhysicalTableAddress(self: *const PDE) u32 {
        return @as(u32, self.page_table_addr) << 12;
    }
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

    pub inline fn getPhysicalPageAddress(self: *const PTE) u32 {
        return @as(u32, self.page_addr) << 12;
    }
};

// One page directory covers the whole 4 GiB address space, and
// each page table covers 4 MiB of that space (1024 entries * 4 KiB pages).
// The page directory and page tables are sparse, i.e., some of their entries may be unused (0).
//
// virtual address = [ page table index (10 bits) | page index (10 bits) | offset (12 bits) ]

pub const PageTable = [1024]PTE; // 4 KiB - covers 4 MiB of RAM
pub const PageDirectory = [1024]PDE; // 4 KiB - covers the whole 4 GiB address space

// Fixed virtual memory locations for recursively mapped PageDirectory (PDE[1023] -> PD)
const mapped_pd = @as(*PageDirectory, @ptrFromInt(0xFFFFF000));
const mapped_pts = @as(*[1024]PageTable, @ptrFromInt(0xFFC00000));

/// Set the i-th entry of the Page Directory. This entry will point to the page table for the 4 MiB
/// area starting at 0x400000 * i.
pub fn setPde(i: u10, pde: PDE) void {
    mapped_pd[i] = pde;
}

/// Index of the page table in which the given address lies (0-1023)
inline fn pageTableIndex(va: u32) u10 {
    return @truncate((va >> 22) & 0x3FF);
}

/// Index of the page within the page table (0-1023)
inline fn pageIndex(va: u32) u10 {
    return @truncate((va >> 12) & 0x3FF);
}

/// Offset within the page (0-4095)
inline fn offset(va: u32) u12 {
    return @truncate(va & 0xFFF);
}

/// Assumes that the current PD is recursively mapped.
/// Gets a pointer to the PTE within whose frame the given virtual address lives.
pub fn getPte(va: u32) *PTE {
    return &mapped_pts[pageTableIndex(va)][pageIndex(va)];
}

/// Get the physical address which the given (virtual) pointer points to.
/// Uses the recursively mapped page directory.
pub fn virtualToPhysical(ptr: *anyopaque) u32 {
    const va = @intFromPtr(ptr);
    return (@as(u32, getPte(va).page_addr) << 12) + offset(va);
}

/// Return a pointer to the currently recursively mapped Page Directory
pub fn getMappedPageDirectory() *PageDirectory {
    return mapped_pd;
}

/// Enable paging and write-protect flags
pub inline fn enable() void {
    asm volatile (
        \\ mov %%cr0, %%eax
        \\ or $(1 << 31 | 1 << 16), %%eax   // enable paging and write-protect flags
        \\ mov %%eax, %%cr0
        ::: .{ .eax = true });
}

/// Load the page directory at the given physical address
pub inline fn loadPageDir(page_dir_phys: u32) void {
    asm volatile (
        \\ mov %[pdir], %%cr3     // enable paging
        :
        : [pdir] "r" (page_dir_phys),
    );
}

/// Initialize identity mapping: physical addresses map 1:1 to virtual addresses.
/// max_addr is the highest physical address to map (in bytes).
/// tables must have sufficient space to fit all required page tables
/// A second, duplicate mapping is made from C0000000 (virtual) to 0..max_phys
pub inline fn initIdentityPaging(page_dir: *PageDirectory, tables: [*]PageTable, max_addr: u32) void {
    const page_dir_size = 4 * 1024 * 1024; // 4MiB covered per page directory
    // number of tables required to cover the desired physical memory space
    const num_tables: u32 = (max_addr + page_dir_size - 1) / page_dir_size;

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

pub fn invlpg(addr: usize) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

fn allocatePageTableAt(pti: u10, user: bool) void {
    const pt_addr = pageallocator.allocPage(); // Page Table - storage for 1024 PTEs
    // PDEs are always set to writable so that our recursive mapping stays modifiable
    setPde(pti, .{ .user = user, .writable = true, .page_table_addr = @truncate(pt_addr >> 12) });
    // zero out the new page table
    @memset(&mapped_pts[pti], @bitCast(@as(u32, 0)));
}

// Allocate a number of pages within an already allocated page table.
fn allocatePagesAt(pti: u10, start_pg: u10, num_pages: u32, user: bool, writable: bool) void {
    const pt = &mapped_pts[pti];
    for (0..num_pages) |i| {
        pt[start_pg + i] = .{ .user = user, .writable = writable, .page_addr = @truncate(pageallocator.allocPage() >> 12) };
    }
}

/// Allocate a number of pages at the given virtual address. Must fit into a single, 4MB aligned page table.
/// Does not check for existing allocations at that location.
pub fn allocateMemoryAt(addr: usize, num_pages: u32, user: bool, writable: bool) []u8 {
    const pti = pageTableIndex(addr);
    const start_pg: u32 = pageIndex(addr);
    if (start_pg + num_pages > 1024) {
        @panic("Virtual range crosses page-table boundary");
    }

    allocatePageTableAt(pti, user);
    allocatePagesAt(pti, @truncate(start_pg), num_pages, user, writable);

    const page_start: [*]u8 = @ptrFromInt(addr);
    return page_start[0 .. num_pages * PAGE];
}

fn handlePageFault(va: usize, errcode: u32) bool {
    if (errcode != 6) {
        // 6 = page not present, write access, user mode - for stack growth
        return false;
    }
    const ptask = task.getCurrentTask();
    if (roundDown(va, PAGE) == ptask.stack_mem.base - PAGE) {
        // Accessing one page below the current stack base - grow the stack by one page
        ptask.stack_mem.growDown(1);
        return true;
    }
    return false;
}

/// Simple page fault handler: print faulting address and error code, then halt.
pub export fn page_fault_handler(vector: u8, errcode: u32, eip: u32, cs: u16) callconv(.c) void {
    _ = vector;
    _ = cs;

    // Read CR2 to get faulting address
    const fault_va = asm volatile ("mov %%cr2, %%eax"
        : [ret] "={eax}" (-> u32),
    );

    if (handlePageFault(fault_va, errcode))
        return;

    const console = @import("console.zig");

    serial.puts("\n!!! PAGE FAULT !!!\nError code: ");
    serial.putHexU32(errcode);
    serial.puts("\nAddress:    ");
    serial.putHexU32(fault_va);
    serial.puts("\neip:        ");
    serial.putHexU32(eip);
    serial.puts("\nHalting.\n");

    console.put(.{
        "\n!!! PAGE FAULT !!!\nError code: ", errcode,
        "\nAddress:    ",                     fault_va,
        "\neip:        ",                     eip,
        "\nHalting.\n",
    });

    while (true) {
        asm volatile ("hlt");
    }
}

pub const PAGE = 4096;

pub inline fn roundDown(p: u32, comptime size: u32) u32 {
    return p & (~(size - 1));
}
pub inline fn roundToNext(p: u32, comptime size: u32) u32 {
    return (p + size - 1) & (~(size - 1));
}

fn numPagesBetween(va0: usize, va1: usize) u32 {
    const va_begin = roundDown(va0, PAGE);
    const va_end = roundToNext(va1, PAGE);
    return @divExact(va_end - va_begin, PAGE);
}

/// Convenience struct to allocate/modify/free a contiguous range of virtual memory pages.
pub const VMemRange = struct {
    base: u32 = 0,
    num_pages: u32 = 0,
    user: bool = false,
    writable: bool = false,

    /// Initialize the struct and allocate a contiguous range of virtual memory pages starting at the given virtual address.
    pub fn allocate(range: *VMemRange, va: u32, va_end: u32, is_user: bool, is_writable: bool) []u8 {
        if (va & 0xFFF != 0) {
            @panic("Virtual address must be page-aligned");
        }
        range.base = va;
        const num_pages = numPagesBetween(va, va_end);
        range.num_pages = num_pages;
        range.user = is_user;
        range.writable = is_writable;
        const mem = allocateMemoryAt(va, num_pages, is_user, is_writable);
        @memset(mem, 0x00);
        return mem;
    }

    /// Change the user/supervisor and read/write permissions for this range.
    pub fn changePermissions(range: *VMemRange, user: bool, writable: bool) void {
        for (0..range.num_pages) |i| {
            const va = range.base + i * 0x1000;
            const pte = getPte(va);
            pte.user = user;
            pte.writable = writable;
            invlpg(va);
        }
    }

    pub fn growDown(range: *VMemRange, additional_pages: u32) void {
        if (additional_pages == 0) return;
        if (additional_pages > 1024) {
            @panic("Cannot grow more than one page table at a time");
        }

        const new_base = range.base - additional_pages * PAGE;
        const new_pti = pageTableIndex(new_base);
        if (new_pti != pageTableIndex(range.base)) {
            // entered a new page table - need to allocate it first
            allocatePageTableAt(new_pti, range.user);
        }
        allocatePagesAt(new_pti, pageIndex(new_base), additional_pages, range.user, range.writable);
        range.base = new_base;
        range.num_pages += additional_pages;
    }

    /// Free all pages allocated by this range and clear the corresponding page directory/table entries.
    pub fn freePages(range: *VMemRange) void {
        for (0..range.num_pages) |i| {
            const va = range.base + i * 0x1000;
            const pte = getPte(va);
            pageallocator.freePage(pte.getPhysicalPageAddress());
            pte.* = @bitCast(@as(u32, 0));
            invlpg(va);

            // After the last page in a table or the range is freed, deallocate the page table itself.
            const page_idx = pageIndex(va);
            if (page_idx == 1023 or i == range.num_pages - 1) {
                // Deallocate the full page table.
                // NB: This makes the assumption that every page table is owned by a single VMemRange.
                const pde = &mapped_pd[pageTableIndex(va)];
                pageallocator.freePage(pde.getPhysicalTableAddress());
                pde.* = @bitCast(@as(u32, 0));
            }
        }
        range.* = .{};
    }
};
