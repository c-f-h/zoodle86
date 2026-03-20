#ifndef CONSOLE_H
#define CONSOLE_H

#include "types.h"

// Initialize the console state, clear the screen, and enable the cursor.
void console_init(u8 attr);
// Clear the screen and reset the logical cursor to the top-left corner.
void console_clear(void);
// Set the logical and hardware cursor position.
void console_set_cursor(u32 row, u32 col);
// Set the foreground and background attribute to use for any following output.
void console_set_attr(u8 attr);
// Write one character at the current cursor position.
void console_putch(char ch);
// Start a new line.
void console_newline();
// Write a null-terminated string starting at the current cursor position.
void console_puts(const char *s);
// Write an 8-bit value as two hexadecimal digits.
void console_put_hex_u8(u8 value);
// Write a 32-bit value as eight hexadecimal digits.
void console_put_hex_u32(u32 value);
// Write a 32-bit unsigned value in decimal.
void console_put_dec_u32(u32 value);

#endif
