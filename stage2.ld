ENTRY(_start)

SECTIONS
{
    . = 0x8000;

    .text : ALIGN(16)
    {
        *(.text .text.*)
    }

    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(16)
    {
        *(.data .data.*)
    }

    .bss : ALIGN(16)
    {
        *(.bss .bss.* COMMON)
    }
}
