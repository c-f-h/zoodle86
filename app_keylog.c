#include "app.h"
#include "keyboard.h"
#include "console.h"
#include "stdlib.h"

static const u8 VGA_ATTR = 0x07;

u32 app_keylog_keyhandler(const struct key_event *event) {
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
    return 0;
}


u32 app_keylog_init(struct app_context* app) {
	memset(app, 0, sizeof(*app));
	app->name = "keylog";
	app->key_event_handler = app_keylog_keyhandler;
    return 0;
}
