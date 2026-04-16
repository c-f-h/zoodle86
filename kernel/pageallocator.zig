var next_page: usize = 0;
var free_end: usize = 0;

const PAGE_SIZE = 0x1000;
const PAGE_MASK: usize = ~(@as(usize, PAGE_SIZE - 1));

pub fn addMemory(start: usize, end: usize) void {
    next_page = PAGE_MASK & (start + PAGE_SIZE - 1); // round up to next page
    free_end = PAGE_MASK & end; // round down to next page
}

pub fn allocPage() usize {
    const page = next_page;
    next_page += PAGE_SIZE;
    if (next_page > free_end)
        @panic("Ran out of allocable pages");
    return page;
}
