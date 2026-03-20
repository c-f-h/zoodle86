[bits 16]
[org 0x7C00]

STAGE2_LOAD_SEGMENT equ 0x0000
STAGE2_LOAD_OFFSET  equ 0x8000
STAGE2_SECTORS      equ 16          ; TODO make automatic

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    ; save boot drive obtained from BIOS
    mov [boot_drive], dl

    ; set video mode
    mov ax, 0x0003
    int 0x10

    mov si, loading_message
    call print_string

    mov ah, 0x02                ; READ SECTORS
    mov al, STAGE2_SECTORS      ; number of sectors to read
    mov ch, 0x00                ; low 8 bits of cylinder
    mov cl, 0x02                ; sector number
    mov dh, 0x00                ; head
    mov dl, [boot_drive]        ; drive
    mov bx, STAGE2_LOAD_OFFSET  ; es:bx = buffer
    int 0x13
    jc disk_error

    jmp STAGE2_LOAD_SEGMENT:STAGE2_LOAD_OFFSET

disk_error:
    mov si, disk_error_message
    call print_string

.hang:
    hlt
    jmp .hang

print_string:
    lodsb
    test al, al
    jz .done

    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp print_string

.done:
    ret

boot_drive db 0
loading_message db 'Loading stage 2...', 0
disk_error_message db 13, 10, 'Disk read failed.', 0

times 510 - ($ - $$) db 0
dw 0xAA55
