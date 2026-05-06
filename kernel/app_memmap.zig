/// Interactive full-screen ASCII viewer for the kernel page directory and page tables.
/// Shows all 1024 PDEs (or PTEs) in a 64-column × 16-row grid.
/// '#' = present, '.' = absent, cursor highlighted in blue.
const std = @import("std");
const kernel = @import("kernel.zig");
const keyboard = @import("keyboard.zig");
const paging = @import("paging.zig");
const console = @import("console.zig");

// VGA attribute bytes: bits 6-4 = background colour, bits 3-0 = foreground colour.
const ATTR_HEADER: u8 = 0x1F; // bright white on blue
const ATTR_PRESENT_KERN: u8 = 0x0A; // bright green on black (kernel)
const ATTR_PRESENT_USER: u8 = 0x0E; // bright yellow on black (user)
const ATTR_ABSENT_KERN: u8 = 0x08; // dark gray on black (kernel)
const ATTR_ABSENT_USER: u8 = 0x0C; // dark magenta on black (user)
const ATTR_CURSOR_PRESENT_KERN: u8 = 0x1A; // bright green on blue
const ATTR_CURSOR_PRESENT_USER: u8 = 0x1E; // bright yellow on blue
const ATTR_CURSOR_ABSENT_KERN: u8 = 0x17; // light gray on blue
const ATTR_CURSOR_ABSENT_USER: u8 = 0x1C; // dark magenta on blue
const ATTR_STATUS: u8 = 0x07; // light gray on black
const ATTR_STATUS_HL: u8 = 0x0F; // bright white on black (highlighted values in status bar)
const ATTR_DIM: u8 = 0x08; // dark gray on black

const ENTRIES_PER_ROW = 64; // entries shown per grid row (64 × 16 = 1024)
const GRID_ROWS = 16;
const GRID_START_ROW = 2; // first grid row on screen
const GRID_START_COL = 4; // grid column offset (after "xxx " row label)
const SUMMARY_COL = GRID_START_COL + ENTRIES_PER_ROW + 1;
const SEP_ROW = GRID_START_ROW + GRID_ROWS; // separator row 18
const STATUS_ROW = SEP_ROW + 1; // status bar row 19
const WINDOW_WIDTH = 80;
const WINDOW_HEIGHT = STATUS_ROW + 1;

const View = enum { pd, pt };

// Saved cells for the fixed memmap sub-window.
const ScreenBuffer = [WINDOW_WIDTH * WINDOW_HEIGHT]u16;

/// Interactive full-screen page directory / page table ASCII viewer.
pub const Memmap = struct {
    console: *console.Console,
    done: bool = false,
    view: View = .pd,
    cursor: u16 = 0,
    /// PDE index in scope when the PT view is active.
    pdi: u10 = 0,
    /// Saved screen state to restore on exit
    saved_screen: ScreenBuffer = undefined,

    /// Save the current screen, register the keyboard handler and paint the initial screen.
    pub fn init(self: *Memmap) void {
        self.done = false;
        self.view = .pd;
        self.cursor = 0;
        self.pdi = 0;
        saveScreen(self, &self.saved_screen);
        kernel.setKeyboardHandler(keyHandler, self);
        drawAll(self);
    }

    /// Restore the saved screen and unregister the keyboard handler.
    pub fn deinit(self: *Memmap) void {
        kernel.clearKeyboardHandler();
        restoreScreen(self, &self.saved_screen);
    }
};

// ---------------------------------------------------------------------------
// Full-screen redraw
// ---------------------------------------------------------------------------

fn drawAll(self: *Memmap) void {
    clearWindow(self, ATTR_STATUS);
    drawHeader(self);
    drawRuler(self);
    drawGrid(self);
    drawSummary(self);
    drawSep(self);
    drawStatus(self);
}

fn drawHeader(self: *Memmap) void {
    clearRow(self, 0, ATTR_HEADER);
    if (self.view == .pd) {
        putStrAt(self, 0, 1, "Page Directory Map", ATTR_HEADER);
        putStrAt(self, 0, 47, "ESC=quit  Enter=zoom  Arrows=move", ATTR_HEADER);
    } else {
        putStrAt(self, 0, 1, "Page Table for PDE 0x", ATTR_HEADER);
        putHex3At(self, 0, 22, self.pdi, ATTR_HEADER);
        putStrAt(self, 0, 25, "  VA 0x", ATTR_HEADER);
        putHex8At(self, 0, 32, @as(u32, self.pdi) << 22, ATTR_HEADER);
        putStrAt(self, 0, 41, "  ESC=back  Arrows=move", ATTR_HEADER);
    }
}

fn drawRuler(self: *Memmap) void {
    clearRow(self, 1, ATTR_DIM);
    putStrAt(self, 1, 0, "idx", ATTR_DIM);
    // One hex digit every 16 columns as a position guide
    var i: u32 = 0;
    while (i < ENTRIES_PER_ROW) : (i += 1) {
        const ch: u8 = if (i % 16 == 0) "0123456789ABCDEF"[i / 16] else '-';
        self.console.putCharAt(1, GRID_START_COL + i, ch, ATTR_DIM);
    }
}

fn drawGrid(self: *Memmap) void {
    const pd = paging.getMappedPageDirectory();
    var row: u32 = 0;
    while (row < GRID_ROWS) : (row += 1) {
        const row_base: u16 = @intCast(row * ENTRIES_PER_ROW);
        // Row label: 3-digit hex index of the first entry in this row
        putHex3At(self, GRID_START_ROW + row, 0, @intCast(row_base), ATTR_DIM);
        self.console.putCharAt(GRID_START_ROW + row, 3, ' ', ATTR_DIM);
        var col: u32 = 0;
        while (col < ENTRIES_PER_ROW) : (col += 1) {
            const idx: u16 = row_base + @as(u16, @intCast(col));
            drawCell(self, GRID_START_ROW + row, GRID_START_COL + col, idx, pd);
        }
    }
}

fn drawCell(self: *Memmap, row: u32, col: u32, idx: u16, pd: *const paging.PageDirectory) void {
    const entry_idx: u10 = @intCast(idx);
    const is_cursor = idx == self.cursor;

    var present = false;
    var is_user = false;
    switch (self.view) {
        .pd => {
            const pde = pd[entry_idx];
            present = pde.present;
            is_user = pde.user;
        },
        .pt => {
            const pte = paging.getMappedPageTable(self.pdi)[entry_idx];
            present = pte.present;
            is_user = pte.user;
        },
    }

    const ch: u8 = if (present) '#' else '.';
    const attr: u8 =
        if (is_cursor)
            if (is_user)
                if (present) ATTR_CURSOR_PRESENT_USER else ATTR_CURSOR_ABSENT_USER
            else if (present) ATTR_CURSOR_PRESENT_KERN else ATTR_CURSOR_ABSENT_KERN
        else if (is_user)
            if (present) ATTR_PRESENT_USER else ATTR_ABSENT_USER
        else if (present) ATTR_PRESENT_KERN else ATTR_ABSENT_KERN;
    self.console.putCharAt(row, col, ch, attr);
}

fn drawSep(self: *Memmap) void {
    var col: u32 = 0;
    while (col < visibleWindowWidth(self.console)) : (col += 1) {
        self.console.putCharAt(SEP_ROW, col, '-', ATTR_DIM);
    }
}

fn drawSummary(self: *Memmap) void {
    const mapped_pages = switch (self.view) {
        .pd => countMappedPagesInDirectory(paging.getMappedPageDirectory()),
        .pt => countMappedPagesInTable(paging.getMappedPageTable(self.pdi)),
    };

    putStrAt(self, GRID_START_ROW + 1, SUMMARY_COL, "mapped", ATTR_DIM);
    putDecU32At(self, GRID_START_ROW + 2, SUMMARY_COL, mapped_pages, ATTR_STATUS_HL);
    putStrAt(self, GRID_START_ROW + 3, SUMMARY_COL, "pages", ATTR_STATUS);
    putDecMiBAt(self, GRID_START_ROW + 5, SUMMARY_COL, mapped_pages, ATTR_STATUS_HL);
    putStrAt(self, GRID_START_ROW + 6, SUMMARY_COL, "MB", ATTR_STATUS);
}

fn drawStatus(self: *Memmap) void {
    clearRow(self, STATUS_ROW, ATTR_STATUS);
    const pd = paging.getMappedPageDirectory();
    switch (self.view) {
        .pd => {
            const pdi: u10 = @intCast(self.cursor);
            const pde = pd[pdi];
            putStrAt(self, STATUS_ROW, 0, "PDE 0x", ATTR_STATUS);
            putHex3At(self, STATUS_ROW, 6, pdi, ATTR_STATUS_HL);
            putStrAt(self, STATUS_ROW, 9, "  VA 0x", ATTR_STATUS);
            putHex8At(self, STATUS_ROW, 16, @as(u32, pdi) << 22, ATTR_STATUS_HL);
            putStrAt(self, STATUS_ROW, 24, "-0x", ATTR_STATUS);
            putHex8At(self, STATUS_ROW, 27, (@as(u32, pdi) << 22) | 0x3FFFFF, ATTR_STATUS_HL);
            if (pde.present) {
                putStrAt(self, STATUS_ROW, 35, "  present", if (pde.user) ATTR_PRESENT_USER else ATTR_PRESENT_KERN);
                putStrAt(self, STATUS_ROW, 44, if (pde.user) "  user" else "  kern", ATTR_STATUS);
                putStrAt(self, STATUS_ROW, 50, if (pde.writable) "  RW" else "  RO", ATTR_STATUS);
            } else {
                putStrAt(self, STATUS_ROW, 35, "  not present", ATTR_ABSENT_KERN);
            }
        },
        .pt => {
            const pti: u10 = @intCast(self.cursor);
            const pte = paging.getMappedPageTable(self.pdi)[pti];
            const va: u32 = (@as(u32, self.pdi) << 22) | (@as(u32, pti) << 12);
            putStrAt(self, STATUS_ROW, 0, "PTE 0x", ATTR_STATUS);
            putHex3At(self, STATUS_ROW, 6, pti, ATTR_STATUS_HL);
            putStrAt(self, STATUS_ROW, 9, "  VA 0x", ATTR_STATUS);
            putHex8At(self, STATUS_ROW, 16, va, ATTR_STATUS_HL);
            if (pte.present) {
                putStrAt(self, STATUS_ROW, 24, "  phys 0x", ATTR_STATUS);
                putHex8At(self, STATUS_ROW, 33, pte.getPhysicalPageAddress(), ATTR_STATUS_HL);
                putStrAt(self, STATUS_ROW, 41, if (pte.user) "  user" else "  kern", ATTR_STATUS);
                putStrAt(self, STATUS_ROW, 47, if (pte.writable) "  RW" else "  RO", ATTR_STATUS);
            } else {
                putStrAt(self, STATUS_ROW, 24, "  not present", ATTR_ABSENT_KERN);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Incremental update helpers (avoid full redraws on cursor movement)
// ---------------------------------------------------------------------------

fn redrawCell(self: *Memmap, idx: u16) void {
    const row = GRID_START_ROW + @as(u32, idx) / ENTRIES_PER_ROW;
    const col = GRID_START_COL + @as(u32, idx) % ENTRIES_PER_ROW;
    const pd = paging.getMappedPageDirectory();
    drawCell(self, row, col, idx, pd);
}

// ---------------------------------------------------------------------------
// Navigation actions
// ---------------------------------------------------------------------------

fn moveCursor(self: *Memmap, delta: i32) void {
    const old = self.cursor;
    const new_val: i32 = @as(i32, self.cursor) + delta;
    if (new_val < 0 or new_val >= 1024) return;
    self.cursor = @intCast(new_val);
    redrawCell(self, old);
    redrawCell(self, self.cursor);
    drawStatus(self);
}

fn enterPtView(self: *Memmap) void {
    const pd = paging.getMappedPageDirectory();
    const pdi: u10 = @intCast(self.cursor);
    if (!pd[pdi].present) return; // only zoom into mapped PDEs
    self.pdi = pdi;
    self.view = .pt;
    self.cursor = 0;
    drawAll(self);
}

fn exitPtView(self: *Memmap) void {
    self.view = .pd;
    self.cursor = @as(u16, self.pdi);
    drawAll(self);
}

// ---------------------------------------------------------------------------
// Keyboard handler (called from keyboard ISR polling loop)
// ---------------------------------------------------------------------------

fn keyHandler(ctx: ?*anyopaque, ev: *const keyboard.KeyEvent) u32 {
    const self: *Memmap = @ptrCast(@alignCast(ctx.?));
    if (ev.pressed == 0) return 0;
    switch (self.view) {
        .pd => switch (ev.keycode) {
            keyboard.VK_ESC => self.done = true,
            keyboard.VK_UP => moveCursor(self, -ENTRIES_PER_ROW),
            keyboard.VK_DOWN => moveCursor(self, ENTRIES_PER_ROW),
            keyboard.VK_LEFT => moveCursor(self, -1),
            keyboard.VK_RIGHT => moveCursor(self, 1),
            keyboard.VK_ENTER, keyboard.VK_KEYPAD_ENTER, keyboard.VK_SPACE => enterPtView(self),
            else => {},
        },
        .pt => switch (ev.keycode) {
            keyboard.VK_ESC, keyboard.VK_BACKSPACE => exitPtView(self),
            keyboard.VK_UP => moveCursor(self, -ENTRIES_PER_ROW),
            keyboard.VK_DOWN => moveCursor(self, ENTRIES_PER_ROW),
            keyboard.VK_LEFT => moveCursor(self, -1),
            keyboard.VK_RIGHT => moveCursor(self, 1),
            else => {},
        },
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Low-level VGA position helpers (bypass console state entirely)
// ---------------------------------------------------------------------------

fn visibleWindowWidth(con: *console.Console) u32 {
    return @min(WINDOW_WIDTH, con.width);
}

fn visibleWindowHeight(con: *console.Console) u32 {
    return @min(WINDOW_HEIGHT, con.height);
}

fn clearWindow(self: *Memmap, attr: u8) void {
    var row: u32 = 0;
    while (row < visibleWindowHeight(self.console)) : (row += 1) {
        clearRow(self, row, attr);
    }
}

fn clearRow(self: *Memmap, row: u32, attr: u8) void {
    var col: u32 = 0;
    while (col < visibleWindowWidth(self.console)) : (col += 1) {
        self.console.putCharAt(row, col, ' ', attr);
    }
}

fn putStrAt(self: *Memmap, row: u32, col: u32, str: []const u8, attr: u8) void {
    var c: u32 = col;
    for (str) |ch| {
        self.console.putCharAt(row, c, ch, attr);
        c += 1;
    }
}

/// Write a 32-bit value as 8 uppercase hex digits starting at (row, col).
fn putHex8At(self: *Memmap, row: u32, col: u32, value: u32, attr: u8) void {
    const hex = "0123456789ABCDEF";
    self.console.putCharAt(row, col + 0, hex[(value >> 28) & 0xF], attr);
    self.console.putCharAt(row, col + 1, hex[(value >> 24) & 0xF], attr);
    self.console.putCharAt(row, col + 2, hex[(value >> 20) & 0xF], attr);
    self.console.putCharAt(row, col + 3, hex[(value >> 16) & 0xF], attr);
    self.console.putCharAt(row, col + 4, hex[(value >> 12) & 0xF], attr);
    self.console.putCharAt(row, col + 5, hex[(value >> 8) & 0xF], attr);
    self.console.putCharAt(row, col + 6, hex[(value >> 4) & 0xF], attr);
    self.console.putCharAt(row, col + 7, hex[(value >> 0) & 0xF], attr);
}

/// Write a 10-bit value (0x000–0x3FF) as 3 uppercase hex digits starting at (row, col).
fn putHex3At(self: *Memmap, row: u32, col: u32, value: u10, attr: u8) void {
    const hex = "0123456789ABCDEF";
    self.console.putCharAt(row, col + 0, hex[@as(u32, value >> 8)], attr);
    self.console.putCharAt(row, col + 1, hex[@as(u32, (value >> 4) & 0xF)], attr);
    self.console.putCharAt(row, col + 2, hex[@as(u32, value & 0xF)], attr);
}

fn putDecU32At(self: *Memmap, row: u32, col: u32, value: u32, attr: u8) void {
    var buf: [10]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{}", .{value}) catch unreachable;
    putStrAt(self, row, col, text, attr);
}

fn putDecMiBAt(self: *Memmap, row: u32, col: u32, page_count: u32, attr: u8) void {
    const milli_mib = (page_count * 1000 + 128) / 256;
    const whole = milli_mib / 1000;
    const frac = milli_mib % 1000;
    var buf: [10]u8 = undefined;
    const whole_text = std.fmt.bufPrint(&buf, "{}", .{whole}) catch unreachable;
    putStrAt(self, row, col, whole_text, attr);
    const frac_col = col + @as(u32, @intCast(whole_text.len));
    self.console.putCharAt(row, frac_col + 0, '.', attr);
    self.console.putCharAt(row, frac_col + 1, @intCast('0' + (frac / 100) % 10), attr);
    self.console.putCharAt(row, frac_col + 2, @intCast('0' + (frac / 10) % 10), attr);
    self.console.putCharAt(row, frac_col + 3, @intCast('0' + frac % 10), attr);
}

fn countMappedPagesInDirectory(pd: *const paging.PageDirectory) u32 {
    var mapped_pages: u32 = 0;
    for (0..pd.len) |i| {
        const pdi: u10 = @intCast(i);
        if (!pd[pdi].present) continue;
        mapped_pages += countMappedPagesInTable(paging.getMappedPageTable(pdi));
    }
    return mapped_pages;
}

fn countMappedPagesInTable(pt: *const paging.PageTable) u32 {
    var mapped_pages: u32 = 0;
    for (pt) |pte| {
        if (pte.present) mapped_pages += 1;
    }
    return mapped_pages;
}

// ---------------------------------------------------------------------------
// Screen save/restore
// ---------------------------------------------------------------------------

fn saveScreen(self: *Memmap, buf: *ScreenBuffer) void {
    var row: u32 = 0;
    while (row < visibleWindowHeight(self.console)) : (row += 1) {
        var col: u32 = 0;
        while (col < visibleWindowWidth(self.console)) : (col += 1) {
            buf[row * WINDOW_WIDTH + col] = self.console.readCell(row, col);
        }
    }
}

fn restoreScreen(self: *Memmap, buf: *const ScreenBuffer) void {
    var row: u32 = 0;
    while (row < visibleWindowHeight(self.console)) : (row += 1) {
        var col: u32 = 0;
        while (col < visibleWindowWidth(self.console)) : (col += 1) {
            const cell = buf[row * WINDOW_WIDTH + col];
            self.console.putCharAt(row, col, @truncate(cell & 0xFF), @truncate((cell >> 8) & 0xFF));
        }
    }
}
