#pragma once

#include "keyboard.h"

typedef u32 (*key_event_handler_t)(const struct key_event* key_ev) ;

struct app_context {
	const char *name;
	key_event_handler_t key_event_handler;
};

u32 app_keylog_init(struct app_context* app);

