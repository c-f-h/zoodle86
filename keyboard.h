#ifndef KEYBOARD_H
#define KEYBOARD_H

#include "types.h"

#define MOD_SHIFT 0x01
#define MOD_ALT   0x02
#define MOD_CTRL  0x04

struct key_event {
    u8 scancode;
    u8 keycode;
    u8 pressed;
    u8 extended;
    u8 modifiers;
    char ascii;
};

// Poll the ringbuffer of scancodes filled by the keyboard ISR, decode key_events, and send them to the event sink.
void keyboard_poll(void);

// Human-readable name for special keycodes.
const char *keycode_name(u8 keycode, u8 extended);

// additional output from keyboard ISR
extern volatile u32 keyboard_irq_count;
extern volatile u32 keyboard_overflow_count;

#endif
