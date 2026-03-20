[bits 16]
[org 0x8000]

CODE_SEL equ 0x08
DATA_SEL equ 0x10

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

wait_for_key_loop:
    call wait_for_make_code
    mov bl, al

    mov edi, VGATEXTBUF + 2*2*80
    mov esi, scancode_label
    call write_string

    mov al, bl
    call write_hex_byte

    jmp wait_for_key_loop

.halt:
    jmp .halt

write_string:
    lodsb
    test al, al
    jz .done
    mov [edi], ax
    add edi, 2
    jmp write_string
.done:
    ret

wait_for_make_code:
    ; poll status code
    in al, 0x64
    test al, 0x01
    jz wait_for_make_code

    ; only accept key-down scancodes
    in al, 0x60
    test al, 0x80
    jnz wait_for_make_code
    ret

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
