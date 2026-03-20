#include "vgatext.h"

static volatile u16 *const VGA = (volatile u16 *)0xB8000;
static const u16 VGA_CRTC_INDEX = 0x3D4;
static const u16 VGA_CRTC_DATA = 0x3D5;

static void outb(u16 port, u8 value) {
    __asm__ __volatile__("outb %0, %1" : : "a"(value), "Nd"(port));
}

static u8 inb(u16 port) {
    u8 value;
    __asm__ __volatile__("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

void vga_put_char_at(u32 row, u32 col, char ch, u8 attr) {
    VGA[row * VGA_TEXT_WIDTH + col] = ((u16)attr << 8) | (u8)ch;
}

u16 vga_read_cell(u32 row, u32 col) {
    return VGA[row * VGA_TEXT_WIDTH + col];
}

void vga_clear(u8 attr) {
    u32 i;
    u16 blank = ((u16)attr << 8) | (u8)' ';

    for (i = 0; i < VGA_TEXT_WIDTH * VGA_TEXT_HEIGHT; ++i) {
        VGA[i] = blank;
    }
}

void vga_enable_cursor(void) {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, (u8)(~0x20u & inb(VGA_CRTC_DATA)));
}

void vga_disable_cursor(void) {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, (u8)(0x20u | inb(VGA_CRTC_DATA)));
}

void vga_set_cursor_size(u8 cursor_start, u8 cursor_end) {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, cursor_start);

    outb(VGA_CRTC_INDEX, 0x0B);
    outb(VGA_CRTC_DATA, cursor_end);
}

void vga_set_cursor_pos(u32 row, u32 col) {
    u16 pos = (u16)(row * VGA_TEXT_WIDTH + col);
    outb(VGA_CRTC_INDEX, 0x0E);
    outb(VGA_CRTC_DATA, (u8)(pos >> 8));
    outb(VGA_CRTC_INDEX, 0x0F);
    outb(VGA_CRTC_DATA, (u8)(pos & 0xFFu));
}
