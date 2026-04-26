[bits 32]
section .text

extern syscall_dispatch, exception_handler, page_fault_handler
extern timer_irq_handler
extern save_kernel_stack_ptr
extern lapic_eoi

; exports
global interrupts_init
global task_switch

; keyboard interrupt output: total IRQ count plus a raw scancode ring buffer
global keyboard_irq_count
global keyboard_scancode_buffer
global keyboard_scancode_head
global keyboard_scancode_tail
global keyboard_overflow_count
global spurious_irq_count

KEYBOARD_BUFFER_SIZE equ 16
KEYBOARD_BUFFER_MASK equ KEYBOARD_BUFFER_SIZE - 1
USER_CODE_SELECTOR equ (3 << 3) | 3
USER_DATA_SELECTOR equ (4 << 3) | 3
KERNEL_DATA_SELECTOR equ (2 << 3)

global keyboard_isr
keyboard_isr:
    push ds
    push es
    pushad

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

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
    call lapic_eoi

    popad
    pop es
    pop ds
    iretd

global timer_isr
timer_isr:
    push ds
    push es
    pushad

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    call timer_irq_handler

    call lapic_eoi
    popad
    pop es
    pop ds
    iretd


global spurious_isr
spurious_isr:
    push ds

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    inc dword [spurious_irq_count]

    pop ds
    ; LAPIC spurious interrupts do not require EOI.
    iretd

global syscall_isr
syscall_isr:
    push dword 0
    push dword 0x80
    push ds
    push es
    pushad

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    ; save kernel stack pointer for task switching
    ; NB: this may clobber eax, ecx, and edx
    push esp
    call save_kernel_stack_ptr
    add esp, 4

    push esp
    call syscall_dispatch
    add esp, 4

    ; move result into stack position from which popad will restore eax
    mov [esp + 28], eax

return_to_userspace:
    popad
    pop es
    pop ds
    add esp, 8              ; drop vector + error code
    iretd

task_switch:
    mov esp, eax             ; caller puts desired kernel stack pointer into eax
    jmp return_to_userspace


%macro exception_isr 1
global exception_isr_int%1
exception_isr_int%1:
    push dword 0x%1
    push ds
    push es
    pushad
    jmp general_exception_handler
%endmacro

exception_isr 08
exception_isr 0A
exception_isr 0B
exception_isr 0C
exception_isr 0D

general_exception_handler:
    ; We don't worry about returning from an exception for now: we either
    ; panic or terminate the user program. So we can clobber everything.
    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    push esp
    call exception_handler
    ; stack here: interrupt vector, error code, eip, cs, eflags, [esp, ss]
    jmp $   ; we should never reach this

global page_fault_isr
page_fault_isr:
    push dword 0x0e
    push ds
    push es
    pushad

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    push esp
    call page_fault_handler
    add esp, 4
    jmp return_to_userspace


section .bss

keyboard_irq_count: resd 1
keyboard_overflow_count: resd 1
spurious_irq_count: resd 1
keyboard_scancode_head: resb 1
keyboard_scancode_tail: resb 1
keyboard_scancode_buffer: resb KEYBOARD_BUFFER_SIZE
