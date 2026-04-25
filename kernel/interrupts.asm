[bits 32]
section .text

extern _bss_start, _bss_end
extern syscall_dispatch, exception_handler, page_fault_handler
extern save_kernel_stack_ptr

; exports
global interrupts_init
global task_switch

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

KEYBOARD_BUFFER_SIZE equ 16
KEYBOARD_BUFFER_MASK equ KEYBOARD_BUFFER_SIZE - 1
USER_CODE_SELECTOR equ (3 << 3) | 3
USER_DATA_SELECTOR equ (4 << 3) | 3
KERNEL_DATA_SELECTOR equ (2 << 3)

interrupts_init:
    pushad
    call remap_pic
    call unmask_keyboard_irq
    sti
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
    mov al, PIC_EOI
    out PIC1_COMMAND, al
    ; NB: for IRQs >= 8, we have to send EOI to both PICs

    popad
    pop es
    pop ds
    iretd

global syscall_isr
syscall_isr:
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

    ; restore eax, ecx, edx from pushad
    mov eax, dword [esp + 28]
    mov ecx, dword [esp + 24]
    mov edx, dword [esp + 20]

    push edx    ; arg3
    push ecx    ; arg2
    push ebx    ; arg1
    push eax    ; nr
    call syscall_dispatch
    add esp, 16

    ; move result into stack position from which popad will restore eax
    mov [esp + 28], eax

return_to_userspace:
    popad
    pop es
    pop ds
    iretd

task_switch:
    mov esp, eax             ; caller puts desired kernel stack pointer into eax
    jmp return_to_userspace


%macro exception_isr 1
global exception_isr_int%1
exception_isr_int%1:
    mov ebx, 0x%1
    jmp general_exception_handler
%endmacro

exception_isr 08
exception_isr 0A
exception_isr 0B
exception_isr 0C
exception_isr 0D
exception_isr 0E

general_exception_handler:
    ; We don't worry about returning from an exception for now: we either
    ; panic or terminate the user program. So we can clobber everything.
    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    ; reusing arguments already on the stack:
    ; - original CS
    ; - original EIP
    ; - error code
    push ebx        ; interrupt vector
    call exception_handler
    ; stack here: interrupt vector, error code, eip, cs, eflags, [esp, ss]
    jmp $   ; we should never reach this

global page_fault_isr
page_fault_isr:
    push ds
    push es
    pushad

    mov ax, KERNEL_DATA_SELECTOR
    mov ds, ax
    mov es, ax

    ; call handler with (0x0e, error code, original EIP, original CS)
    mov ebp, esp
    push dword [ebp + 48]   ; original CS
    push dword [ebp + 44]   ; original EIP
    push dword [ebp + 40]   ; error code
    push 0x0e               ; page fault
    call page_fault_handler
    add esp, 4 * 4          ; drop handler arguments

    popad
    pop es
    pop ds
    add esp, 4              ; drop error code
    iretd


section .bss

keyboard_irq_count: resd 1
keyboard_overflow_count: resd 1
keyboard_scancode_head: resb 1
keyboard_scancode_tail: resb 1
keyboard_scancode_buffer: resb KEYBOARD_BUFFER_SIZE
