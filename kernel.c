#include "types.h"
#include "app.h"
#include "console.h"
#include "keyboard.h"
#include "vgatext.h"

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

#define READLINE_BUF_MAX_LEN 80
char readline_buf[READLINE_BUF_MAX_LEN];
int readline_buf_cursor;
int readline_buf_len;

void delete_char() {
    if (readline_buf_cursor < readline_buf_len) {
        for (int i = readline_buf_cursor; i < readline_buf_len - 1; ++i) {
            readline_buf[i] = readline_buf[i + 1];
        }
        --readline_buf_len;
    }
}

void insert_char() {
    if (readline_buf_len < READLINE_BUF_MAX_LEN) {
        for (int i = readline_buf_len; i >= readline_buf_cursor + 1; --i) {
            readline_buf[i] = readline_buf[i - 1];
        }
        ++readline_buf_len;
    }
}

u32 app_launcher_keyhandler(const struct key_event *event) {
    int handled = 0;

    if (!event->pressed)
        return 0;

    if (event->modifiers == MOD_CTRL) {
        switch (event->keycode) {
            case 0x1E:  // Ctrl+A
                readline_buf_cursor = 0;
                handled = 1;
                break;
            case 0x30:  // Ctrl+B
                if (readline_buf_cursor > 0)
                    --readline_buf_cursor;
                handled = 1;
                break;
            case 0x12:  // Ctrl+E
                readline_buf_cursor = readline_buf_len;
                handled = 1;
                break;
            case 0x21:  // Ctrl+F
                if (readline_buf_cursor < readline_buf_len)
                    ++readline_buf_cursor;
                handled = 1;
                break;
        }
    }

    if (!handled && event->ascii) {
        if (readline_buf_cursor < readline_buf_len) {
            // cursor in the middle of the buffer?
            insert_char();
            readline_buf[readline_buf_cursor++] = event->ascii;
        } else {
            //cursor at the end of the buffer?
            readline_buf[readline_buf_cursor] = event->ascii;

            if (readline_buf_cursor < READLINE_BUF_MAX_LEN - 1)
              ++readline_buf_cursor;

            if (readline_buf_cursor > readline_buf_len) {
              // NB: it's valid to have cursor = len (pointing past the end)
              readline_buf_len = readline_buf_cursor;
            }
        }
    } else if (!handled && event->extended) {
        switch (event->keycode) {
            case ESC_HOME:
                readline_buf_cursor = 0;
                break;
            case ESC_END:
                readline_buf_cursor = readline_buf_len;
                break;
            case ESC_LEFT:
                if (readline_buf_cursor > 0)
                    --readline_buf_cursor;
                break;
            case ESC_RIGHT:
                if (readline_buf_cursor < readline_buf_len)
                    ++readline_buf_cursor;
                break;
            case ESC_DELETE:
                delete_char();
                break;
        }
    } else if (!handled) {
        switch (event->keycode) {
            case SC_BACKSPACE:
                if (readline_buf_cursor > 0) {
                    --readline_buf_cursor;
                    delete_char();
                }
                break;
        }
    }

    int i = 0;
    for (; i < readline_buf_len; ++i) {
        vga_put_char_at(10, i, readline_buf[i], VGA_ATTR);
    }
    // TODO: should depend on screen width
    for (; i < READLINE_BUF_MAX_LEN; ++i) {
        vga_put_char_at(10, i, ' ', VGA_ATTR);
    }

    console_set_cursor(10, readline_buf_cursor);
    return 0;
}


u32 app_launcher_init(struct app_context* app) {
	memset(app, 0, sizeof(*app));
	app->name = "launcher";
	app->key_event_handler = app_launcher_keyhandler;
    console_set_cursor(10, 0);

    return 0;
}

void _start(void) {
    console_init(VGA_ATTR);
    console_puts("Hello from protected mode.\n");
    console_puts("Press a key.\n\n");
    interrupts_init();

    //app_keylog_init(&cur_app);
    app_launcher_init(&cur_app);

    while (1) {
        keyboard_poll();
    }
}
