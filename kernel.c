#include "console.h"

static const u8 VGA_ATTR = 0x07;

extern volatile u32 keyboard_irq_count;
extern volatile u8 keyboard_last_scancode;
extern volatile u8 keyboard_event_pending;

extern void interrupts_init(void);

void _start(void) {
    console_init(VGA_ATTR);
    console_puts("Hello from freestanding C.\n");
    console_puts("Boot sector did the mode switch.\n");
    console_puts("Stage 2 is C plus a linked IRQ module.\n\n");
    console_puts("Press a key.\n\n");
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

            console_puts("Scancode:  0x");
            console_set_attr(0x0f);
            console_put_hex_u8(keyboard_last_scancode);
            console_set_attr(VGA_ATTR);
            console_newline();

            console_puts("IRQ count: ");
            console_set_attr(0x0f);
            console_put_dec_u32(keyboard_irq_count);
            console_set_attr(VGA_ATTR);
            console_newline();
            console_newline();
        }

        __asm__("sti");
    }
}
