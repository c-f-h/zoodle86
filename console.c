#include "console.h"
#include "vgatext.h"

static u32 console_row = 0;
static u32 console_col = 0;
static u8 console_attr = 0x07;

static void console_sync_cursor(void) {
    vga_set_cursor_pos(console_row, console_col);
}

static void console_scroll_if_needed(void) {
    u32 row;
    u32 col;

    if (console_row < VGA_TEXT_HEIGHT) {
        return;
    }

    for (row = 1; row < VGA_TEXT_HEIGHT; ++row) {
        for (col = 0; col < VGA_TEXT_WIDTH; ++col) {
            u16 cell = vga_read_cell(row, col);
            vga_put_char_at(row - 1u, col, (char)(cell & 0x00FFu), (u8)(cell >> 8));
        }
    }

    for (col = 0; col < VGA_TEXT_WIDTH; ++col) {
        vga_put_char_at(VGA_TEXT_HEIGHT - 1u, col, ' ', console_attr);
    }

    console_row = VGA_TEXT_HEIGHT - 1u;
}

static void console_advance_line(void) {
    console_col = 0;
    ++console_row;
    console_scroll_if_needed();
}

void console_clear(void) {
    vga_clear(console_attr);
    console_row = 0;
    console_col = 0;
    console_sync_cursor();
}

void console_set_cursor(u32 row, u32 col) {
    if (row >= VGA_TEXT_HEIGHT) {
        row = VGA_TEXT_HEIGHT - 1u;
    }

    if (col >= VGA_TEXT_WIDTH) {
        col = VGA_TEXT_WIDTH - 1u;
    }

    console_row = row;
    console_col = col;
    console_sync_cursor();
}

void console_set_attr(u8 attr)
{
    console_attr = attr;
}

void console_putch(char ch) {
    if (ch == '\n') {
        console_newline();
        return;
    }

    if (ch == '\r') {
        console_col = 0;
        console_sync_cursor();
        return;
    }

    vga_put_char_at(console_row, console_col, ch, console_attr);
    ++console_col;

    if (console_col >= VGA_TEXT_WIDTH) {
        console_advance_line();
    }

    console_sync_cursor();
}

void console_newline()
{
    console_advance_line();
    console_sync_cursor();
}

void console_puts(const char *s) {
    while (*s) {
        console_putch(*s);
        ++s;
    }
}

void console_put_hex_u8(u8 value) {
    static const char hex[] = "0123456789ABCDEF";

    console_putch(hex[(value >> 4) & 0x0Fu]);
    console_putch(hex[value & 0x0Fu]);
}

void console_put_hex_u32(u32 value) {
    int shift;

    for (shift = 28; shift >= 0; shift -= 4) {
        static const char hex[] = "0123456789ABCDEF";
        console_putch(hex[(value >> shift) & 0x0Fu]);
    }
}

void console_put_dec_u32(u32 value) {
    char digits[10];
    u32 count = 0;

    if (value == 0u) {
        console_putch('0');
        return;
    }

    while (value > 0u) {
        digits[count] = (char)('0' + (value % 10u));
        value /= 10u;
        ++count;
    }

    while (count > 0u) {
        --count;
        console_putch(digits[count]);
    }
}
