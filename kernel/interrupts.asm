; Contains assembly entry stubs for interrupt handlers.
;
; All interrupts are routed through interrupt_dispatch with the generic
; stack frame described in interrupt_frame.zig.

[bits 32]
section .text

extern interrupt_dispatch

global return_to_userspace

VECTOR_TIMER      equ 0xE8
VECTOR_KEYBOARD   equ 0xD8
VECTOR_SYSCALL    equ 0x80

KERNEL_DATA_SELECTOR equ (2 << 3)

global keyboard_isr
keyboard_isr:
    push dword 0                 ; error_code
    push dword VECTOR_KEYBOARD   ; vector
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
    push dword 0                ; error_code
    push dword VECTOR_TIMER     ; vector
    jmp generic_handler

global syscall_isr
syscall_isr:
    push dword 0                ; error_code
    push dword VECTOR_SYSCALL   ; vector
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

global cpuid_query
cpuid_query:
    push ebx
    push edi

    mov eax, [esp + 12]
    mov ecx, [esp + 16]
    cpuid

    mov edi, [esp + 20]
    mov [edi + 0], eax
    mov [edi + 4], ebx
    mov [edi + 8], ecx
    mov [edi + 12], edx

    pop edi
    pop ebx
    ret


section .bss

global spurious_irq_count
spurious_irq_count: resd 1
