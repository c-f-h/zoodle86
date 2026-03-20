[bits 16]
[org 0x8000]

CODE_SEL equ 0x08
DATA_SEL equ 0x10
PIC1_COMMAND equ 0x20
PIC1_DATA    equ 0x21
PIC2_COMMAND equ 0xA0
PIC2_DATA    equ 0xA1
PIC_EOI      equ 0x20
KEYBOARD_VECTOR equ 0x21

stage2_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    call enable_a20
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 0x1
    mov cr0, eax

    jmp CODE_SEL:protected_mode

enable_a20:
    in al, 0x92
    or al, 0x02
    out 0x92, al
    ret

gdt_start:
    ; Null descriptor. Selector 0x00 is intentionally unusable.
    dw 0x0000
    dw 0x0000
    db 0x00
    db 0x00
    db 0x00
    db 0x00

    ; Flat 32-bit ring-0 code segment covering the full 4 GiB space.
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b
    db 11001111b
    db 0x00

    ; Flat 32-bit ring-0 data segment covering the full 4 GiB space.
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b
    db 11001111b
    db 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

;; 32 bit protected mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

VGATEXTBUF equ 0xB8000

[bits 32]
protected_mode:
    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; clear the screen
    mov edi, VGATEXTBUF
    xor ax, ax
    mov ecx, 80*25
clearscreen:
    stosw
    loop clearscreen

    mov edi, VGATEXTBUF
    mov ah, 0x1F        ; character colors

    mov esi, prompt
    call write_string

    ; Install a tiny IDT with a keyboard handler, move the PIC off the CPU
    ; exception vectors, and then unmask only IRQ1 (keyboard) on the master PIC.
    call setup_idt
    call remap_pic
    call enable_keyboard_irq1
    call unmask_keyboard_irq
    sti

    ; The main loop checks whether the ISR has already queued a key event before
    ; going to sleep. That avoids a race where IRQ1 arrives just before HLT and
    ; the CPU would otherwise sleep with a pending event already recorded.
.event_loop:
    cmp byte [key_event_pending], 0
    jne .handle_key
    hlt
    jmp .event_loop

.handle_key:

    mov byte [key_event_pending], 0

    mov edi, VGATEXTBUF + 2*2*80
    mov ah, 0x1F
    mov esi, scancode_label
    call write_string

    mov al, [last_scancode]
    call write_hex_byte

    mov edi, VGATEXTBUF + 2*3*80
    mov ah, 0x1F
    mov esi, irq_count_label
    call write_string

    mov al, [irq_count]
    call write_hex_byte

    jmp .event_loop

write_string:
    lodsb
    test al, al
    jz .done
    mov [edi], ax
    add edi, 2
    jmp write_string
.done:
    ret

setup_idt:
    ; Start with all-zero entries. Any unexpected interrupt will fault, which is
    ; acceptable for this tiny demo because we only enable IRQ1 afterward.
    mov edi, idt
    xor eax, eax
    mov ecx, ((KEYBOARD_VECTOR + 1) * 8) / 4
    rep stosd

    ; Build one 32-bit interrupt gate for vector 0x21, which will be IRQ1 after
    ; PIC remapping. The gate points at keyboard_isr in our ring-0 code segment.
    mov edi, idt + (KEYBOARD_VECTOR * 8)
    mov eax, keyboard_isr
    mov word [edi + 0], ax
    mov word [edi + 2], CODE_SEL
    mov byte [edi + 4], 0
    mov byte [edi + 5], 10001110b
    shr eax, 16
    mov word [edi + 6], ax

    lidt [idt_descriptor]
    ret

remap_pic:
    ; The legacy PIC defaults IRQs onto vectors 0x08-0x0F and 0x70-0x77. In
    ; protected mode we move them to 0x20-0x2F so they do not overlap CPU
    ; exceptions. ICW1-4 is the standard 8259 initialization sequence.
    mov al, 0x11
    out PIC1_COMMAND, al
    out PIC2_COMMAND, al

    mov al, 0x20
    out PIC1_DATA, al
    mov al, 0x28
    out PIC2_DATA, al

    mov al, 0x04
    out PIC1_DATA, al
    mov al, 0x02
    out PIC2_DATA, al

    mov al, 0x01
    out PIC1_DATA, al
    out PIC2_DATA, al

    ; Mask every IRQ for now. We will selectively unmask the keyboard next.
    mov al, 0xFF
    out PIC1_DATA, al
    out PIC2_DATA, al
    ret

unmask_keyboard_irq:
    ; IRQ1 is bit 1 on the master PIC mask register. Clearing that bit enables
    ; keyboard interrupts while leaving all other IRQ lines masked.
    in al, PIC1_DATA
    and al, 11111101b
    out PIC1_DATA, al
    ret

enable_keyboard_irq1:
    ; To receive interrupts, update the 8042 command byte so bit 0 ("enable
    ; keyboard interrupt") is set.
    call wait_8042_input_empty
    mov al, 0x20
    out 0x64, al

    call wait_8042_output_full
    in al, 0x60
    or al, 0x01
    mov bl, al

    call wait_8042_input_empty
    mov al, 0x60
    out 0x64, al

    call wait_8042_input_empty
    mov al, bl
    out 0x60, al
    ret

wait_8042_input_empty:
    in al, 0x64
    test al, 0x02
    jnz wait_8042_input_empty
    ret

wait_8042_output_full:
    in al, 0x64
    test al, 0x01
    jz wait_8042_output_full
    ret

keyboard_isr:
    ; Save general-purpose registers because the interrupted code is our own
    ; main loop. We do not touch segment registers here because DS already points
    ; at the flat ring-0 data segment.
    pushad

    ; Reading port 0x60 acknowledges the keyboard controller and gives us the
    ; raw scancode. The ISR only records state and leaves all rendering to the
    ; foreground loop so screen updates happen from one place.
    in al, 0x60
    mov [last_raw_scancode], al
    inc byte [irq_count]

    test al, 0x80
    jnz .send_eoi

    mov [last_scancode], al
    mov byte [key_event_pending], 1

.send_eoi:
    ; Tell the master PIC that IRQ1 has been handled so it can deliver the next
    ; keyboard interrupt.
    mov al, PIC_EOI
    out PIC1_COMMAND, al

    popad
    iretd

write_hex_byte:
    push eax
    shr al, 4
    call write_hex_nibble
    pop eax
    and al, 0x0F
    call write_hex_nibble
    ret

write_hex_nibble:
    and al, 0x0F
    cmp al, 9
    jbe .digit
    add al, 'A' - 10
    jmp .emit
.digit:
    add al, '0'
.emit:
    mov [edi], ax
    add edi, 2
    ret

prompt db 'Press a key.', 0
scancode_label db 'Scancode: 0x', 0
irq_count_label db 'IRQ count: 0x', 0
last_scancode db 0
last_raw_scancode db 0
key_event_pending db 0
irq_count db 0

align 8, db 0
idt: times KEYBOARD_VECTOR + 1 dq 0

idt_descriptor:
    dw ((KEYBOARD_VECTOR + 1) * 8) - 1
    dd idt
