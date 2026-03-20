#include "types.h"
#include "app.h"
#include "console.h"
#include "keyboard.h"

static const u8 VGA_ATTR = 0x07;

// from interrupts.asm
extern void interrupts_init(void);

struct app_context cur_app;

struct app_context* get_cur_app() {
    return &cur_app;
}

void consume_key_event(const struct key_event *event) {
    if (cur_app.key_event_handler) {
        cur_app.key_event_handler(event);
    }
}

void* memset(void* ptr, i32 value, size_t sz) {
    u8* bptr = ptr;
    while (sz-- != 0) {
        *bptr++ = (u8)value;
    }
    return ptr;
}


void _start(void) {
    console_init(VGA_ATTR);
    console_puts("Hello from protected mode.\n");
    console_puts("Press a key.\n\n");
    interrupts_init();

    app_keylog_init(&cur_app);

    while (1) {
        keyboard_poll();
    }
}
