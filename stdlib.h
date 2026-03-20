#include "types.h"

void* memset(void* ptr, i32 value, size_t sz);

// Get a pointer to the currently active app context.
struct app_context* get_cur_app();

