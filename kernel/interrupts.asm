; Contains assembly entry stubs for interrupt handlers.
;
; All interrupts are routed through interrupt_dispatch with the generic
; stack frame described in interrupt_frame.zig.

[bits 32]
section .text

extern interrupt_dispatch
extern kernel_reschedule

global return_to_userspace

%include "vectors.asm"

KERNEL_DATA_SELECTOR equ (2 << 3)

global kernel_yield_trampoline
global _kernel_yield_trampoline_return

kernel_yield_trampoline:
    pushad          ; save current task's registers
    push esp        ; pass current kernel esp into reschedule
    call kernel_reschedule  ; return esp of task to switch to
_kernel_yield_trampoline_return:
    mov esp, eax    ; restore other task's kernel esp
    popad           ; restore other task's registers
    ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

global generic_handler:
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; macro for ISRs which should push a dummy zero error code and the interrupt vector
%macro interrupt_isr 1
global %1_isr
%1_isr:
    push dword 0                ; error_code
    push dword VECTOR_%1        ; vector
    jmp generic_handler
%endmacro

interrupt_isr SYSCALL
interrupt_isr TIMER
interrupt_isr KEYBOARD
interrupt_isr IDE_PRIMARY
interrupt_isr IDE_SECONDARY

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

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
