; Contains assembly entry stubs for interrupt handlers.
;
; All interrupts are routed through interrupt_dispatch with the generic
; stack frame described in interrupt_frame.zig.

[bits 32]
section .text

extern interrupt_dispatch

global return_to_userspace

KERNEL_DATA_SELECTOR equ (2 << 3)

global keyboard_isr
keyboard_isr:
    push dword 0      ; error_code
    push dword 0x21   ; vector 0x21
generic_handler:
    push ds
    push es
    pushad

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    push esp
    call interrupt_dispatch
    add esp, 4
return_to_userspace:        ; esp -> InterruptFrame
    popad
    pop es
    pop ds
    add esp, 8              ; drop vector + error code
    iretd

global timer_isr
timer_isr:
    push dword 0      ; error_code
    push dword 0x20   ; vector
    jmp generic_handler

global syscall_isr
syscall_isr:
    push dword 0      ; error_code
    push dword 0x80   ; vector
    jmp generic_handler

; macro for exception IRQs which already push an error code onto the stack
%macro exception_isr 1
global exception_isr_int%1
exception_isr_int%1:
    push dword 0x%1          ; vector
    jmp generic_handler
%endmacro

exception_isr 08
exception_isr 0A
exception_isr 0B
exception_isr 0C
exception_isr 0D

global page_fault_isr
page_fault_isr:
    push dword 0x0e       ; vector
    jmp generic_handler

global spurious_isr
spurious_isr:
    push ds

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    inc dword [spurious_irq_count]

    pop ds
    ; LAPIC spurious interrupts do not require EOI.
    iretd


section .bss

global spurious_irq_count
spurious_irq_count: resd 1
