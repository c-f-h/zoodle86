[bits 16]
[org 0x7C00]

STAGE2_LOAD_SEGMENT equ 0x0000
STAGE2_LOAD_OFFSET  equ 0x8000
FLOPPY_SECTORS_PER_TRACK equ 18
FLOPPY_HEADS_PER_CYLINDER equ 2

; must be set by build script:
;   STAGE2_SECTORS          how many sectors to load for stage 2
;   STAGE2_ENTRY_OFFSET     the entrypoint into stage 2

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
    test dl, 0x80
    jz no_hdd
    mov byte [loading_message_cont], 'H'   ; -> "HDD"
no_hdd:
    and dl, ~0x80
    add dl, '0'
    mov byte [loading_message_cont+4], dl

    ;; get memory map from BIOS
    xor bp, bp                  ; keep count of entries
    mov di, 0x7E02              ; directly after the bootloader - space for count
    xor ebx, ebx                ; initial value for ebx - int 15 will update it

load_smap_loop:
    clc
    mov eax, 0xE820             ; command for int 15h
    mov ecx, 24                 ; buffer size
    mov edx, 0x534D4150         ; magic number 'SMAP'
    int 0x15                    ; load an smap entry
    jc general_error
    mov edx, 0x534D4150         ; magic number 'SMAP'
    cmp eax, edx
    jne general_error
    inc bp
    add di, 24                ; advance to next entry
    test ebx, ebx
    jnz load_smap_loop

    ; finished loading smap entries - store the count
    mov word [0x7e00], bp

    ;; load stage 2 from the boot drive
    mov si, loading_message
    call print_string

    mov bx, STAGE2_LOAD_OFFSET  ; es:bx = buffer
    mov cx, STAGE2_SECTORS
    mov byte [disk_sector], 2
    mov byte [disk_head], 0
    mov byte [disk_cylinder], 0
    call load_stage2
    jc general_error

    ; Do not carry real-mode interrupt state into protected mode. Until stage 2
    ; installs a valid IDT, any hardware IRQ would triple-fault and reboot.
    cli
    call enable_a20
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 0x1
    mov cr0, eax

    jmp CODE_SEL:protected_mode_entry

general_error:
    mov si, error_message
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

load_stage2:
.next_sector:
    test cx, cx
    jz .done

    push cx             ; preserve number of sectors left to read
    mov ah, 0x02            ; cmd: read sectors
    mov al, 0x01            ; number of sectors = 1
    mov ch, [disk_cylinder] ; low 8 bits of cylinder number
    mov cl, [disk_sector]   ; sector number (1-based)
    mov dh, [disk_head]     ; disk head
    mov dl, [boot_drive]    ; drive number
    int 0x13                ; read 0x200 bytes into es:bx
    jc .error
    pop cx

    add bx, 0x200
    jnc .advance_disk
    mov ax, es              ; bx carried over to 0, meaning we read 0x10000 bytes
    add ax, 0x1000          ; so we add 0x1000 to the segment to advance 0x10000 bytes
    mov es, ax

.advance_disk:
    inc byte [disk_sector]
    cmp byte [disk_sector], FLOPPY_SECTORS_PER_TRACK + 1
    jne .continue

    mov byte [disk_sector], 1
    inc byte [disk_head]
    cmp byte [disk_head], FLOPPY_HEADS_PER_CYLINDER
    jb .continue

    mov byte [disk_head], 0
    inc byte [disk_cylinder]

.continue:
    dec cx
    jmp .next_sector

.done:
    clc
    ret

.error:
    pop cx
    stc
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

    ; Required before any SSE/xmm usage
    mov eax, cr0
    and eax, ~(1 << 2)   ; Clear EM (emulation)
    or  eax, (1 << 1)    ; Set MP (monitor coprocessor)
    mov cr0, eax

    mov eax, cr4
    or  eax, (1 << 9)    ; Set OSFXSR
    or  eax, (1 << 10)   ; Set OSXMMEXCPT (optional but recommended)
    mov cr4, eax

    mov eax, STAGE2_LOAD_OFFSET + STAGE2_ENTRY_OFFSET
    jmp eax

boot_drive db 0
disk_sector db 0
disk_head db 0
disk_cylinder db 0
loading_message db 'Loading stage 2 from '
loading_message_cont db 'FDD ?...', 0
error_message db 13, 10, 'Bootloader failure.', 0

times 510 - ($ - $$) db 0
dw 0xAA55
