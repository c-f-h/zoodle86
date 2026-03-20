[bits 16]
[org 0x7C00]

STAGE2_LOAD_SEGMENT equ 0x0000
STAGE2_LOAD_OFFSET  equ 0x8000

; should be set by build script
;%define STAGE2_SECTORS 4

%ifndef STAGE2_ENTRY_OFFSET
%define STAGE2_ENTRY_OFFSET 0
%endif

CODE_SEL equ 0x08
DATA_SEL equ 0x10

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

    ; Do not carry real-mode interrupt state into protected mode. Until stage 2
    ; installs a valid IDT, any hardware IRQ would triple-fault and reboot.
    cli
    call enable_a20
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 0x1
    mov cr0, eax

    jmp CODE_SEL:protected_mode_entry

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

enable_a20:
    in al, 0x92
    or al, 0x02
    out 0x92, al
    ret

gdt_start:
    ; --- Descriptor 0x00: null descriptor (required by spec) ---
    dq 0x0000000000000000

    ; --- Descriptor 0x08: kernel code segment ---
    ;   base=0, limit=0xFFFFF (× 4KB = 4 GB), ring 0, 32-bit, executable
    dq 0x00CF9A000000FFFF

    ; --- Descriptor 0x10: kernel data segment ---
    ;   base=0, limit=0xFFFFF (× 4KB = 4 GB), ring 0, 32-bit, read/write
    dq 0x00CF92000000FFFF
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1      ; GDT num bytes minus 1
    dd gdt_start                    ; GDT address

[bits 32]
protected_mode_entry:
    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    mov eax, STAGE2_LOAD_OFFSET + STAGE2_ENTRY_OFFSET
    jmp eax

[bits 16]

boot_drive db 0
loading_message db 'Loading stage 2...', 0
disk_error_message db 13, 10, 'Disk read failed.', 0

times 510 - ($ - $$) db 0
dw 0xAA55
