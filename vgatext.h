#ifndef VGATEXT_H
#define VGATEXT_H

#include "types.h"

#define VGA_TEXT_WIDTH 80u
#define VGA_TEXT_HEIGHT 25u

// Write a character and attribute to a specific VGA text cell.
void vga_put_char_at(u32 row, u32 col, char ch, u8 attr);
// Read the raw VGA text cell contents at a specific position.
u16 vga_read_cell(u32 row, u32 col);
// Fill the entire VGA text buffer with spaces using the given attribute.
void vga_clear(u8 attr);

// Enable the hardware text cursor.
void vga_enable_cursor(void);
// Disable the hardware text cursor.
void vga_disable_cursor(void);
// Configure the hardware cursor scanline start and end.
void vga_set_cursor_size(u8 cursor_start, u8 cursor_end);
// Move the hardware cursor to the given row and column.
void vga_set_cursor_pos(u32 row, u32 col);

#endif
