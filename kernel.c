typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

static volatile u16 *const VGA = (volatile u16 *)0xB8000;
static const u8 VGA_ATTR = 0x1F;
static const u16 VGA_CRTC_INDEX = 0x3D4;
static const u16 VGA_CRTC_DATA = 0x3D5;

extern volatile u8 keyboard_irq_count;
extern volatile u8 keyboard_last_scancode;
extern volatile u8 keyboard_raw_scancode;
extern volatile u8 keyboard_event_pending;

extern void interrupts_init(void);

void outb(u16 port, u8 value) {
    __asm__ __volatile__("outb %0, %1" : : "a"(value), "Nd"(port));
}

u8 inb(u16 port) {
    u8 value;
    __asm__ __volatile__("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

static void vga_put_char(u32 row, u32 col, char ch, u8 attr) {
    VGA[row * 80u + col] = ((u16)attr << 8) | (u8)ch;
}

static void vga_clear(void) {
    u32 i;
    for (i = 0; i < 80u * 25u; ++i) {
        VGA[i] = 0;
    }
}

static void vga_write_string(u32 row, u32 col, const char *s, u8 attr) {
    while (*s) {
        vga_put_char(row, col, *s, attr);
        ++s;
        ++col;
    }
}

static void vga_write_hex_byte(u32 row, u32 col, u8 value, u8 attr) {
    static const char hex[] = "0123456789ABCDEF";
    vga_put_char(row, col + 0u, hex[(value >> 4) & 0x0Fu], attr);
    vga_put_char(row, col + 1u, hex[value & 0x0Fu], attr);
}

// Enable the VGA hardware cursor.
void vga_enable_cursor(void) {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, ~0x20 & inb(VGA_CRTC_DATA));
}

// Disable the VGA hardware cursor.
void vga_disable_cursor(void) {
    outb(VGA_CRTC_INDEX, 0x0A);
    outb(VGA_CRTC_DATA, 0x20 | inb(VGA_CRTC_DATA));
}

// Enable the VGA hardware cursor and set its size.
// Start and end are scanlines in [0..15].
void vga_set_cursor_size(u8 cursor_start, u8 cursor_end)
{
	outb(VGA_CRTC_INDEX, 0x0A);
	outb(VGA_CRTC_DATA, cursor_start);

	outb(VGA_CRTC_INDEX, 0x0B);
	outb(VGA_CRTC_DATA, cursor_end);
}

// Set the position of the VGA hardware cursor.
void vga_set_cursor_pos(u32 row, u32 col) {
    u16 pos = (u16)(row * 80u + col);
    outb(VGA_CRTC_INDEX, 0x0E);
    outb(VGA_CRTC_DATA, (u8)(pos >> 8));
    outb(VGA_CRTC_INDEX, 0x0F);
    outb(VGA_CRTC_DATA, (u8)(pos & 0xFFu));
}

void _start(void) {
    vga_clear();
    vga_write_string(0, 0, "Hello from freestanding C.", VGA_ATTR);
    vga_write_string(1, 0, "Boot sector did the mode switch.", VGA_ATTR);
    vga_write_string(2, 0, "Stage 2 is C plus a linked IRQ module.", VGA_ATTR);
    vga_write_string(4, 0, "Press a key.", VGA_ATTR);
    vga_write_string(6, 0, "Scancode: 0x", VGA_ATTR);
    vga_write_string(7, 0, "Raw IRQ:  0x", VGA_ATTR);
    vga_write_string(8, 0, "IRQ count: 0x", VGA_ATTR);
    vga_set_cursor_pos(9, 0);

    interrupts_init();

    while (1) {
        /* Protect the shared event flag while deciding whether to sleep. The
           'sti; hlt' pair is the classic race-free idle sequence: if IRQ1 is
           already pending, HLT wakes immediately; otherwise the CPU sleeps
           until the next keyboard interrupt arrives. */
        __asm__("cli");
        if (!keyboard_event_pending) {
            __asm__("sti\nhlt\ncli");
        }

        if (keyboard_event_pending) {
            keyboard_event_pending = 0;
            vga_write_hex_byte(6, 12, keyboard_last_scancode, VGA_ATTR);
        }

        vga_write_hex_byte(7, 12, keyboard_raw_scancode, VGA_ATTR);
        vga_write_hex_byte(8, 12, keyboard_irq_count, VGA_ATTR);
        __asm__("sti");
    }
}
