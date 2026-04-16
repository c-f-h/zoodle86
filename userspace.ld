ENTRY(_start)

SECTIONS
{
    . = 0x400000;

    /DISCARD/ : { *(.eh_frame .eh_frame_hdr) }

    .text : ALIGN(16)
    {
        *(.text .text.*)
    }

    . = 0x10000000;

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
        _bss_start = .;
        *(.bss .bss.* COMMON)
        _bss_end = .;

        . = ALIGN(16);

        _stack_bottom = .;
        . = . + 0x4000;   /* 16 KB stack */
        _stack_top = .;
    }
}
