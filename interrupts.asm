[bits 32]
section .text

extern _bss_start, _bss_end

; entry point to initialize the interrupt handler
global interrupts_init

; keyboard interrupt output: total IRQ count plus a raw scancode ring buffer
global keyboard_irq_count
global keyboard_scancode_buffer
global keyboard_scancode_head
global keyboard_scancode_tail
global keyboard_overflow_count

; port numbers for master and slave PIC
PIC1_COMMAND    equ 0x20
PIC1_DATA       equ 0x21
PIC2_COMMAND    equ 0xA0
PIC2_DATA       equ 0xA1

; PIC commands
PIC_INIT        equ 0x11
PIC_EOI         equ 0x20    ; end of interrupt
PIC_READ_IRR    equ 0x0a    ; OCW3 irq ready next CMD read
PIC_READ_ISR    equ 0x0b    ; OCW3 irq service next CMD read

KEYBOARD_VECTOR equ 0x21    ; interrupt vector to which IRQ1 will be remapped
NUM_IDT_ENTRIES equ KEYBOARD_VECTOR + 1
KEYBOARD_BUFFER_SIZE equ 16
KEYBOARD_BUFFER_MASK equ KEYBOARD_BUFFER_SIZE - 1

interrupts_init:
    ; zero out the BSS section
    mov edi, _bss_start
    mov ecx, _bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb

    ; Build the IDT first so protected mode has a valid destination for IRQ1
    ; before we unmask anything.
    call setup_idt
    call remap_pic
    ;call enable_keyboard_irq1
    call unmask_keyboard_irq
    sti
    ret

setup_idt:
    pushad

    ; Zero the IDT entries. Any unexpected interrupt will still
    ; fault, but only IRQ1 is unmasked for now.
    mov edi, idt
    xor eax, eax
    mov ecx, (NUM_IDT_ENTRIES * 8) / 4
    rep stosd

    ; Install a 32-bit interrupt gate for IRQ1 after PIC remapping.
    mov edi, idt + (KEYBOARD_VECTOR * 8)
    mov eax, keyboard_isr
    mov word [edi + 0], ax              ; handler low 16 bits
    mov word [edi + 2], cs              ; code segment selector (GDT)
    mov byte [edi + 4], 0               ; 0 (reserved)
    mov byte [edi + 5], 10001110b       ; attrs: present, dpl = 0, storage segment = 0, gate type = 1110 = 32-bit
    shr eax, 16
    mov word [edi + 6], ax              ; handler high 16 bits (32 bit handler)

    lidt [idt_descriptor]
    popad
    ret

remap_pic:
    push eax

    ; Move legacy PIC IRQs away from the CPU exception vectors and into the range 0x20..0x2F
    ; Therefore, IRQ1 = 0x21 after remapping

    ; initialize PICs - they then expect 3 further init words
    mov al, PIC_INIT
    out PIC1_COMMAND, al
    out PIC2_COMMAND, al

    ; init word 1: vector offset
    mov al, 0x20
    out PIC1_DATA, al
    mov al, 0x28
    out PIC2_DATA, al

    ; init word 2: master/slave wiring
    mov al, 1 << 2          ; tell PIC1 that slave is at IRQ2
    out PIC1_DATA, al
    mov al, 0x02            ; tell slave PIC its cascade identity
    out PIC2_DATA, al

    ; init word 3: environment
    mov al, 0x01            ; use 8086/88 mode
    out PIC1_DATA, al
    out PIC2_DATA, al

    ; IMR: mask everything until we explicitly enable IRQ1.
    mov al, 0xFF
    out PIC1_DATA, al
    out PIC2_DATA, al

    pop eax
    ret

unmask_keyboard_irq:
    push eax

    ; IRQ1 is bit 1 in the master PIC mask register (IMR)
    in al, PIC1_DATA
    and al, 11111101b
    out PIC1_DATA, al

    pop eax
    ret

enable_keyboard_irq1:
    ; NB: this routine is not necessary to enable the keyboard interrupt
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
    in al, 0x64                 ; keyboard controller read status
    test al, 0x02               ; input buffer full? can only write to 0x60/0x64 once this is clear
    jnz wait_8042_input_empty
    ret

wait_8042_output_full:
    in al, 0x64                 ; keyboard controller read status
    test al, 0x01               ; output buffer full? -> port 0x60 has data
    jz wait_8042_output_full
    ret

keyboard_isr:
    pushad

    ; Reading port 0x60 both acknowledges the keyboard controller and fetches the raw
    ; scancode byte that triggered IRQ1.
    in al, 0x60
    inc dword [keyboard_irq_count]

    mov dl, [keyboard_scancode_head]
    mov bl, dl
    inc bl
    and bl, KEYBOARD_BUFFER_MASK        ; (head + 1) % buffer_size
    cmp bl, [keyboard_scancode_tail]
    je .buffer_full

    movzx edi, dl
    mov [keyboard_scancode_buffer + edi], al
    mov [keyboard_scancode_head], bl
    jmp .send_eoi

.buffer_full:
    inc dword [keyboard_overflow_count]

.send_eoi:
    mov al, PIC_EOI
    out PIC1_COMMAND, al
    ; NB: for IRQs >= 8, we have to send EOI to both PICs

    popad
    iretd

section .bss
align 8
idt: resq NUM_IDT_ENTRIES

keyboard_irq_count: resd 1
keyboard_overflow_count: resd 1
keyboard_scancode_head: resb 1
keyboard_scancode_tail: resb 1
keyboard_scancode_buffer: resb KEYBOARD_BUFFER_SIZE

section .data
idt_descriptor:
    dw (NUM_IDT_ENTRIES * 8) - 1  ; total IDT bytes minus 1
    dd idt                        ; address of IDT
