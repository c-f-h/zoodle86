[bits 32]
section .text

global interrupts_init
global keyboard_irq_count
global keyboard_last_scancode
global keyboard_raw_scancode
global keyboard_event_pending

extern _start

PIC1_COMMAND    equ 0x20
PIC1_DATA       equ 0x21
PIC2_COMMAND    equ 0xA0
PIC2_DATA       equ 0xA1
PIC_EOI         equ 0x20
KEYBOARD_VECTOR equ 0x21
CODE_SEL        equ 0x08

interrupts_init:
    ; Build the IDT first so protected mode has a valid destination for IRQ1
    ; before we unmask anything.
    call setup_idt
    call remap_pic
    call enable_keyboard_irq1
    call unmask_keyboard_irq
    sti
    ret

setup_idt:
    pushad

    ; Zero the small IDT we actually use. Any unexpected interrupt will still
    ; fault, but only IRQ1 is unmasked in this demo.
    mov edi, idt
    xor eax, eax
    mov ecx, ((KEYBOARD_VECTOR + 1) * 8) / 4
    rep stosd

    ; Install a 32-bit interrupt gate for IRQ1 after PIC remapping.
    mov edi, idt + (KEYBOARD_VECTOR * 8)
    mov eax, keyboard_isr
    mov word [edi + 0], ax
    mov word [edi + 2], CODE_SEL
    mov byte [edi + 4], 0
    mov byte [edi + 5], 10001110b
    shr eax, 16
    mov word [edi + 6], ax

    lidt [idt_descriptor]
    popad
    ret

remap_pic:
    push eax

    ; Move legacy PIC IRQs away from the CPU exception vectors.
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

    ; Mask everything until we explicitly enable IRQ1.
    mov al, 0xFF
    out PIC1_DATA, al
    out PIC2_DATA, al

    pop eax
    ret

unmask_keyboard_irq:
    push eax

    ; IRQ1 is bit 1 in the master PIC mask register.
    in al, PIC1_DATA
    and al, 11111101b
    out PIC1_DATA, al

    pop eax
    ret

enable_keyboard_irq1:
    push eax
    push ebx

    ; Update the 8042 command byte so the keyboard controller actually raises
    ; IRQ1 instead of only buffering scancodes for polling.
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

    pop ebx
    pop eax
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
    pushad

    ; Reading port 0x60 both acknowledges the controller and fetches the raw
    ; scancode byte that triggered IRQ1.
    in al, 0x60
    mov [keyboard_raw_scancode], al
    inc byte [keyboard_irq_count]

    ; Break codes have bit 7 set. For the foreground demo we only queue make
    ; codes so each key press generates one event.
    test al, 0x80
    jnz .send_eoi

    mov [keyboard_last_scancode], al
    mov byte [keyboard_event_pending], 1

.send_eoi:
    mov al, PIC_EOI
    out PIC1_COMMAND, al

    popad
    iretd

section .bss
align 8
idt: resq KEYBOARD_VECTOR + 1

keyboard_irq_count: resb 1
keyboard_last_scancode: resb 1
keyboard_raw_scancode: resb 1
keyboard_event_pending: resb 1

section .data
idt_descriptor:
    dw ((KEYBOARD_VECTOR + 1) * 8) - 1
    dd idt
