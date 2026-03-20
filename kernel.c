#include "console.h"
#include "keyboard.h"

static const u8 VGA_ATTR = 0x07;

// from interrupts.asm
extern void interrupts_init(void);

// output from keyboard ISR
extern volatile u32 keyboard_irq_count;
extern volatile u32 keyboard_overflow_count;

void consume_key_event(const struct key_event *event) {
    const char *name = keycode_name(event->keycode, event->extended);

    console_puts(event->pressed ? "Down: " : "Up:   ");
    if (event->ascii != 0) {
        console_putch('\'');
        console_set_attr(0x0f);
        if (event->ascii == '\n') {
            console_putch('\\');
            console_putch('n');
        } else {
            console_putch(event->ascii);
        }
        console_set_attr(VGA_ATTR);
        console_putch('\'');
    } else if (name != 0) {
        console_set_attr(0x0f);
        console_puts(name);
        console_set_attr(VGA_ATTR);
    } else {
        console_puts("keycode 0x");
        console_set_attr(0x0f);
        console_put_hex_u8(event->keycode);
        console_set_attr(VGA_ATTR);
    }
    console_newline();

    console_puts("Raw:     ");
    if (event->extended) {
        console_puts("0xE0 ");
    }
    console_puts("0x");
    console_set_attr(0x0f);
    console_put_hex_u8(event->scancode);
    console_set_attr(VGA_ATTR);
    console_newline();

    console_puts("Mods:    ");
    console_set_attr(0x0f);
    if (event->modifiers & MOD_SHIFT)
        console_puts("Shift ");
    if (event->modifiers & MOD_ALT)
        console_puts("Alt ");
    if (event->modifiers & MOD_CTRL)
        console_puts("Ctrl ");
    else if (event->modifiers == 0)
        console_puts("-");
    console_set_attr(VGA_ATTR);
    console_newline();

    console_puts("IRQs:    ");
    console_set_attr(0x0f);
    console_put_dec_u32(keyboard_irq_count);
    console_set_attr(VGA_ATTR);
    console_newline();

    console_puts("Dropped: ");
    console_set_attr(0x0f);
    console_put_dec_u32(keyboard_overflow_count);
    console_set_attr(VGA_ATTR);
    console_newline();
    console_newline();
}

void _start(void) {
    console_init(VGA_ATTR);
    console_puts("Hello from protected mode.\n");
    console_puts("Press a key.\n\n");
    interrupts_init();

    while (1) {
        keyboard_poll();
    }
}
