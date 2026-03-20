#pragma once

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;

typedef signed char  i8;
typedef signed short i16;
typedef signed int   i32;

#ifdef __TINYC__
// TODO Should be active for all 32 bit compilers - mostly to keep clangd from complaining
typedef u32 size_t;
#endif
