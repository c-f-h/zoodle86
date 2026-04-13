ENTRY(_start)

SECTIONS
{
    . = 0;

    /DISCARD/ : { *(.eh_frame .eh_frame_hdr) }

    .text : ALIGN(16)
    {
        *(.text .text.*)
    }

    . = ALIGN(4096);

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
    }
}
