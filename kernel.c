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

static void delete_char() {
    // shift all later chars forward by one
    if (readline_buf_cursor < readline_buf_len) {
        for (int i = readline_buf_cursor; i < readline_buf_len - 1; ++i) {
            readline_buf[i] = readline_buf[i + 1];
        }
        --readline_buf_len;
    }
}

static void insert_char(char ch) {
    // shift all later chars back by one
    if (readline_buf_len < READLINE_BUF_MAX_LEN) {
        for (int i = readline_buf_len; i >= readline_buf_cursor + 1; --i) {
            readline_buf[i] = readline_buf[i - 1];
        }
        ++readline_buf_len;
    }
    readline_buf[readline_buf_cursor] = ch;
}

u32 app_launcher_keyhandler(const struct key_event *event) {
    if (!event->pressed)
        return 0;

    int redraw_all = 0;

    if (event->modifiers & ~MOD_SHIFT) {
        // If any modifier except shift is pressed, we do not insert a char.
        // However, only some combinations with Ctrl actually have an effect.
        if (event->modifiers == MOD_CTRL) {
            switch (event->keycode) {
                case 0x1E:  // Ctrl+A - go to beginning of line
                    readline_buf_cursor = 0;
                    break;
                case 0x20:  // Ctrl+D - delete
                    delete_char();
                    break;
                case 0x30:  // Ctrl+B - go back
                    if (readline_buf_cursor > 0)
                        --readline_buf_cursor;
                    break;
                case 0x12:  // Ctrl+E - go to end of line
                    readline_buf_cursor = readline_buf_len;
                    break;
                case 0x21:  // Ctrl+F - go forward
                    if (readline_buf_cursor < readline_buf_len)
                        ++readline_buf_cursor;
                    break;
                case 0x25:  // Ctrl+K - kill until end of line
                    readline_buf_len = readline_buf_cursor;
                    redraw_all = 1;
                    break;
            }
        }
    } else if (event->ascii) {
        // make space for the new char and insert it
        insert_char(event->ascii);
        // advance cursor if there is more space
        if (readline_buf_cursor < READLINE_BUF_MAX_LEN - 1)
            ++readline_buf_cursor;

        // if we inserted past the end, enlarge the buffer
        if (readline_buf_cursor > readline_buf_len) {
            // NB: it's valid to have cursor = len (pointing past the end)
            readline_buf_len = readline_buf_cursor;
        }
    } else if (event->extended) {
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
                // NB: the cursor is allowed to go one past the current buffer
                // length, but only if there is more space to append another char
                if (readline_buf_cursor < readline_buf_len
                        && readline_buf_cursor < READLINE_BUF_MAX_LEN - 1)
                    ++readline_buf_cursor;
                break;
            case ESC_DELETE:
                delete_char();
                break;
        }
    } else {
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
    // it's usually sufficient to blank out one char past the end of the buffer
    if (readline_buf_len < READLINE_BUF_MAX_LEN)
        vga_put_char_at(10, i, ' ', VGA_ATTR);
    if (redraw_all)     // only if we killed a longer portion of the buffer
        for (; i < READLINE_BUF_MAX_LEN; ++i)
            vga_put_char_at(10, i, ' ', VGA_ATTR);

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
