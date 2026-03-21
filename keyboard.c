#include "keyboard.h"

extern volatile u8 keyboard_scancode_buffer[16];
extern volatile u8 keyboard_scancode_head;
extern volatile u8 keyboard_scancode_tail;

static u8 keyboard_modifiers = 0;
static u8 keyboard_e0_pending = 0;

// keyboard event sink - defined by kernel
extern void consume_key_event(const struct key_event *event);

static char keycode_to_ascii(u8 keycode, u8 modifiers) {
    switch (keycode) {
    case 0x02: return (modifiers & MOD_SHIFT) ? '!' : '1';
    case 0x03: return (modifiers & MOD_SHIFT) ? '@' : '2';
    case 0x04: return (modifiers & MOD_SHIFT) ? '#' : '3';
    case 0x05: return (modifiers & MOD_SHIFT) ? '$' : '4';
    case 0x06: return (modifiers & MOD_SHIFT) ? '%' : '5';
    case 0x07: return (modifiers & MOD_SHIFT) ? '^' : '6';
    case 0x08: return (modifiers & MOD_SHIFT) ? '&' : '7';
    case 0x09: return (modifiers & MOD_SHIFT) ? '*' : '8';
    case 0x0A: return (modifiers & MOD_SHIFT) ? '(' : '9';
    case 0x0B: return (modifiers & MOD_SHIFT) ? ')' : '0';
    case 0x0C: return (modifiers & MOD_SHIFT) ? '_' : '-';
    case 0x0D: return (modifiers & MOD_SHIFT) ? '+' : '=';
    case 0x10: return (modifiers & MOD_SHIFT) ? 'Q' : 'q';
    case 0x11: return (modifiers & MOD_SHIFT) ? 'W' : 'w';
    case 0x12: return (modifiers & MOD_SHIFT) ? 'E' : 'e';
    case 0x13: return (modifiers & MOD_SHIFT) ? 'R' : 'r';
    case 0x14: return (modifiers & MOD_SHIFT) ? 'T' : 't';
    case 0x15: return (modifiers & MOD_SHIFT) ? 'Y' : 'y';
    case 0x16: return (modifiers & MOD_SHIFT) ? 'U' : 'u';
    case 0x17: return (modifiers & MOD_SHIFT) ? 'I' : 'i';
    case 0x18: return (modifiers & MOD_SHIFT) ? 'O' : 'o';
    case 0x19: return (modifiers & MOD_SHIFT) ? 'P' : 'p';
    case 0x1A: return (modifiers & MOD_SHIFT) ? '{' : '[';
    case 0x1B: return (modifiers & MOD_SHIFT) ? '}' : ']';
    //case 0x1C: return '\n';           // return: not a printable char
    case 0x1E: return (modifiers & MOD_SHIFT) ? 'A' : 'a';
    case 0x1F: return (modifiers & MOD_SHIFT) ? 'S' : 's';
    case 0x20: return (modifiers & MOD_SHIFT) ? 'D' : 'd';
    case 0x21: return (modifiers & MOD_SHIFT) ? 'F' : 'f';
    case 0x22: return (modifiers & MOD_SHIFT) ? 'G' : 'g';
    case 0x23: return (modifiers & MOD_SHIFT) ? 'H' : 'h';
    case 0x24: return (modifiers & MOD_SHIFT) ? 'J' : 'j';
    case 0x25: return (modifiers & MOD_SHIFT) ? 'K' : 'k';
    case 0x26: return (modifiers & MOD_SHIFT) ? 'L' : 'l';
    case 0x27: return (modifiers & MOD_SHIFT) ? ':' : ';';
    case 0x28: return (modifiers & MOD_SHIFT) ? '"' : '\'';
    case 0x29: return (modifiers & MOD_SHIFT) ? '~' : '`';
    case 0x2B: return (modifiers & MOD_SHIFT) ? '|' : '\\';
    case 0x2C: return (modifiers & MOD_SHIFT) ? 'Z' : 'z';
    case 0x2D: return (modifiers & MOD_SHIFT) ? 'X' : 'x';
    case 0x2E: return (modifiers & MOD_SHIFT) ? 'C' : 'c';
    case 0x2F: return (modifiers & MOD_SHIFT) ? 'V' : 'v';
    case 0x30: return (modifiers & MOD_SHIFT) ? 'B' : 'b';
    case 0x31: return (modifiers & MOD_SHIFT) ? 'N' : 'n';
    case 0x32: return (modifiers & MOD_SHIFT) ? 'M' : 'm';
    case 0x33: return (modifiers & MOD_SHIFT) ? '<' : ',';
    case 0x34: return (modifiers & MOD_SHIFT) ? '>' : '.';
    case 0x35: return (modifiers & MOD_SHIFT) ? '?' : '/';
    case 0x39: return ' ';
    default: return 0;
    }
}

const char *keycode_name(u8 keycode, u8 extended) {
    if (extended) {
        switch (keycode) {
        case 0x1C: return "Keypad Enter";
        case 0x1D: return "Right Ctrl";
        case 0x35: return "Keypad /";
        case 0x38: return "Right Alt";
        case 0x48: return "Up";
        case 0x4B: return "Left";
        case 0x4D: return "Right";
        case 0x50: return "Down";
        default: return "Ext";
        }
    }

    switch (keycode) {
    case 0x01: return "Esc";
    case 0x0E: return "Backspace";
    case 0x0F: return "Tab";
    case 0x1C: return "Enter";
    case 0x1D: return "Left Ctrl";
    case 0x2A: return "Left Shift";
    case 0x36: return "Right Shift";
    case 0x38: return "Left Alt";
    case 0x39: return "Space";
    default: return 0;
    }
}

static u8 decode_scancode(u8 scancode, struct key_event *event) {
    if (scancode == 0xE0) {
        keyboard_e0_pending = 1;
        return 0;
    }

    u8 extended = keyboard_e0_pending;
    keyboard_e0_pending = 0;
    u8 keycode = scancode & 0x7Fu;
    u8 pressed = (u8)((scancode & 0x80u) == 0);     // highest bit = released/pressed

    // left or right shift pressed/released?
    if (!extended && (keycode == 0x2A || keycode == 0x36)) {
        if (pressed) {
            keyboard_modifiers |= MOD_SHIFT;
        } else {
            keyboard_modifiers &= (u8)~MOD_SHIFT;
        }
    }

    // alt modifier
    if (keycode == 0x38) {
        if (pressed) {
            keyboard_modifiers |= MOD_ALT;
        } else {
            keyboard_modifiers &= (u8)~MOD_ALT;
        }
    }

    // ctrl pressed/released?
    if (keycode == 0x1D) {
        if (pressed) {
            keyboard_modifiers |= MOD_CTRL;
        } else {
            keyboard_modifiers &= (u8)~MOD_CTRL;
        }
    }

    event->scancode = scancode;
    event->keycode = keycode;
    event->pressed = pressed;
    event->extended = extended;
    event->modifiers = keyboard_modifiers;
    event->ascii = (!extended && pressed) ? keycode_to_ascii(keycode, keyboard_modifiers) : 0;
    return 1;
}

void keyboard_poll(void) {
    __asm__("cli");
    if (keyboard_scancode_head == keyboard_scancode_tail) {
        __asm__("sti\nhlt\ncli");
    }

    while (keyboard_scancode_head != keyboard_scancode_tail) {
        u8 scancode = keyboard_scancode_buffer[keyboard_scancode_tail];
        struct key_event event;

        keyboard_scancode_tail = (keyboard_scancode_tail + 1) & 0x0f;
        __asm__("sti");

        if (decode_scancode(scancode, &event)) {
            consume_key_event(&event);
        }

        __asm__("cli");
    }

    __asm__("sti");
}
