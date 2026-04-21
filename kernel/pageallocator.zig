var first_page: usize = 0;
var free_end: usize = 0;

const PAGE_SIZE = 0x1000;
const PAGE_MASK: usize = ~(@as(usize, PAGE_SIZE - 1));
const BITS_PER_WORD = @bitSizeOf(u32);

var page_bitmap_storage: []u32 = undefined;
var page_bitmap: []u32 = undefined;
var cur_word_index: usize = 0;

pub fn init(bitmap_va: []u32) void {
    page_bitmap_storage = bitmap_va;
}

pub fn setPhysicalMemoryRange(start: usize, end: usize) void {
    first_page = PAGE_MASK & (start + PAGE_SIZE - 1); // round up to next page
    free_end = PAGE_MASK & end; // round down to next page
    initBitmap(first_page, free_end);
    cur_word_index = 0;
}

fn initBitmap(start: usize, end: usize) void {
    const num_pages = (end - start) / PAGE_SIZE;
    const bitmap_size_words = @divFloor(num_pages + BITS_PER_WORD - 1, BITS_PER_WORD);
    if (bitmap_size_words > page_bitmap_storage.len) {
        @panic("Not enough space in bitmap");
    }
    page_bitmap = page_bitmap_storage[0..bitmap_size_words];
    @memset(page_bitmap, 0xFFFF_FFFF); // mark all pages as free

    // clear bits for pages after the end address (last word only)
    if (bitmap_size_words > 0) {
        const last_word_bits = @mod(num_pages, BITS_PER_WORD);
        // If the bitmap doesn't perfectly fit the number of pages, mark the extra bits in the last word as used
        if (last_word_bits != 0) {
            page_bitmap[bitmap_size_words - 1] = (@as(u32, 1) << @intCast(last_word_bits)) - 1;
        }
    }
}

fn findNextFreePage() usize {
    const start_index = cur_word_index;
    while (true) {
        if (page_bitmap[cur_word_index] != 0) {
            const bit_index = @ctz(page_bitmap[cur_word_index]); // index of least significant set bit
            return first_page + @as(usize, cur_word_index * BITS_PER_WORD + bit_index) * PAGE_SIZE;
        }
        cur_word_index += 1;
        if (cur_word_index == page_bitmap.len) {
            cur_word_index = 0; // wrap around to start
        }
        if (cur_word_index == start_index) {
            @panic("No free pages available");
        }
    }
}

pub fn allocPage() usize {
    const page = findNextFreePage();

    const index = (page - first_page) / PAGE_SIZE;
    const word_index = index / BITS_PER_WORD;
    const bit_index = index % BITS_PER_WORD;

    if ((page_bitmap[word_index] & (@as(u32, 1) << @intCast(bit_index))) == 0) {
        @panic("Page already allocated");
    }
    page_bitmap[word_index] &= ~(@as(u32, 1) << @intCast(bit_index));

    return page;
}

pub fn freePage(page: usize) void {
    if (page < first_page or page >= free_end or (page & (PAGE_SIZE - 1)) != 0) {
        @panic("Invalid page to free");
    }
    const index = (page - first_page) / PAGE_SIZE;
    const word_index = index / BITS_PER_WORD;
    const bit_index = index % BITS_PER_WORD;
    if ((page_bitmap[word_index] & (@as(u32, 1) << @intCast(bit_index))) != 0) {
        @panic("Page already free");
    }
    page_bitmap[word_index] |= (@as(u32, 1) << @intCast(bit_index));
}
