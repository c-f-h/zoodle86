[bits 16]

global _start
extern stage2_main
extern stage2_graphical_enabled

BOOT_VIDEO_INFO_ADDR        equ 0x0600
VBE_CTRL_INFO_BUF           equ 0x2000
VBE_MODE_INFO_BUF           equ 0x2400
CODE32_SEL                  equ 0x08
DATA32_SEL                  equ 0x10

VIDEO_INFO_MAGIC            equ 0
VIDEO_INFO_DISPLAY_KIND     equ 4
VIDEO_INFO_BPP              equ 5
VIDEO_INFO_MODE             equ 8
VIDEO_INFO_WIDTH            equ 12
VIDEO_INFO_HEIGHT           equ 14
VIDEO_INFO_PITCH            equ 16
VIDEO_INFO_MEMORY_MODEL     equ 18
VIDEO_INFO_RED_MASK_SIZE    equ 19
VIDEO_INFO_RED_POSITION     equ 20
VIDEO_INFO_GREEN_MASK_SIZE  equ 21
VIDEO_INFO_GREEN_POSITION   equ 22
VIDEO_INFO_BLUE_MASK_SIZE   equ 23
VIDEO_INFO_BLUE_POSITION    equ 24
VIDEO_INFO_PHYS_BASE        equ 26

section .text

; Real-mode stage2 entry. Probes VBE, exports boot video metadata, then enters
; 32-bit protected mode and jumps to the Zig stage2 loader.
_start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    cld
    lidt [rm_idtr]

    call init_video_info

    cmp byte [stage2_graphical_enabled], 0
    je .skip_probe

    mov word [best_mode], 0xFFFF
    mov dword [best_area], 0

    mov di, VBE_CTRL_INFO_BUF
    mov dword [di], '2EBV'
    mov ax, 0x4F00
    int 0x10
    cmp ax, 0x004F
    jne .skip_probe

    mov ax, [VBE_CTRL_INFO_BUF + 0x0E]
    mov [mode_list_off], ax
    mov ax, [VBE_CTRL_INFO_BUF + 0x10]
    mov [mode_list_seg], ax

.probe_loop:
    mov ax, [mode_list_seg]
    mov ds, ax
    mov si, [mode_list_off]
    lodsw
    mov [mode_list_off], si

    xor dx, dx
    mov ds, dx

    cmp ax, 0xFFFF
    je .probe_done

    mov bx, ax
    call score_mode
    cmp eax, [best_area]
    jbe .probe_loop

    mov [best_area], eax
    mov [best_mode], bx
    jmp .probe_loop

.probe_done:
    mov bx, [best_mode]
    cmp bx, 0xFFFF
    je .skip_probe

    call try_mode

.skip_probe:
    cli
    call enable_a20
    lgdt [pm_gdtr]

    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax

    jmp CODE32_SEL:protected_mode_entry

; Try setting a VBE mode in BX and export metadata on success.
; CF=0 on success, CF=1 on failure.
try_mode:
    push bx

    mov ax, 0
    mov es, ax
    mov di, VBE_MODE_INFO_BUF
    mov cx, bx

    mov ax, 0x4F01
    int 0x10
    cmp ax, 0x004F
    jne .fail_pop

    mov ax, [di + 0x00]
    test ax, 0x0080
    jz .fail_pop

    pop dx
    push dx

    mov bx, dx
    or bx, 0x4000
    mov ax, 0x4F02
    int 0x10
    cmp ax, 0x004F
    jne .fail_pop

    pop dx

    mov byte [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_DISPLAY_KIND], 1
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_MODE], dx

    mov ax, [di + 0x12]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_WIDTH], ax
    mov ax, [di + 0x14]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_HEIGHT], ax
    mov ax, [di + 0x10]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_PITCH], ax

    mov al, [di + 0x19]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_BPP], al
    mov al, [di + 0x1B]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_MEMORY_MODEL], al

    mov al, [di + 0x1F]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_RED_MASK_SIZE], al
    mov al, [di + 0x20]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_RED_POSITION], al

    mov al, [di + 0x21]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_GREEN_MASK_SIZE], al
    mov al, [di + 0x22]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_GREEN_POSITION], al

    mov al, [di + 0x23]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_BLUE_MASK_SIZE], al
    mov al, [di + 0x24]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_BLUE_POSITION], al

    mov eax, [di + 0x28]
    mov [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_PHYS_BASE], eax

    clc
    ret

.fail_pop:
    pop bx
    stc
    ret

; Score a mode: returns pixel area in EAX if mode is acceptable, otherwise 0.
score_mode:
    push bx

    mov ax, 0
    mov es, ax
    mov di, VBE_MODE_INFO_BUF
    mov cx, bx

    mov ax, 0x4F01
    int 0x10           ; get mode info
    cmp ax, 0x004F     ; successful?
    jne .bad

    mov ax, [di + 0x00]
    test ax, 0x0080    ; linear framebuffer mode supported?
    jz .bad

    mov al, [di + 0x19]
    cmp al, 16         ; bits per pixel is 16?
    jne .bad

    mov al, [di + 0x1B] ; memory model type
    cmp al, 4          ; packed pixel?
    je .good
    cmp al, 6          ; RGB?
    jne .bad

.good:
    movzx eax, word [di + 0x12]
    movzx edx, word [di + 0x14]

    cmp edx, 1000              ; height > 1000?
    ja .bad

    imul eax, edx
    pop bx
    ret

.bad:
    xor eax, eax
    pop bx
    ret

enable_a20:
    in al, 0x92
    or al, 0x02
    out 0x92, al
    ret

init_video_info:
    mov dword [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_MAGIC], 0x30444956 ; "VID0"
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_DISPLAY_KIND], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_BPP], 0
    mov word  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_MODE], 0
    mov word  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_WIDTH], 0
    mov word  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_HEIGHT], 0
    mov word  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_PITCH], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_MEMORY_MODEL], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_RED_MASK_SIZE], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_RED_POSITION], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_GREEN_MASK_SIZE], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_GREEN_POSITION], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_BLUE_MASK_SIZE], 0
    mov byte  [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_BLUE_POSITION], 0
    mov dword [BOOT_VIDEO_INFO_ADDR + VIDEO_INFO_PHYS_BASE], 0
    ret

[bits 32]
protected_mode_entry:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x80000
    cld

    ; Required before any SSE/xmm usage.
    mov eax, cr0
    and eax, ~(1 << 2)   ; Clear EM (emulation)
    or  eax, (1 << 1)    ; Set MP (monitor coprocessor)
    mov cr0, eax

    mov eax, cr4
    or  eax, (1 << 9)    ; Set OSFXSR
    or  eax, (1 << 10)   ; Set OSXMMEXCPT (optional but recommended)
    mov cr4, eax

    jmp stage2_main

section .data
align 4
pm_gdt:
    ; --- Descriptor 0x00: null descriptor (required by spec) ---
    dq 0x0000000000000000

    ; --- Descriptor 0x08: kernel code segment ---
    ;   base=0, limit=0xFFFFF (× 4KB = 4 GB), ring 0, 32-bit, executable
    dq 0x00CF9A000000FFFF

    ; --- Descriptor 0x10: kernel data segment ---
    ;   base=0, limit=0xFFFFF (× 4KB = 4 GB), ring 0, 32-bit, read/write
    dq 0x00CF92000000FFFF
pm_gdt_end:

pm_gdtr:
    dw pm_gdt_end - pm_gdt - 1
    dd pm_gdt

rm_idtr:
    dw 0x03FF
    dd 0x00000000

section .bss
align 4
mode_list_off: resw 1
mode_list_seg: resw 1
best_mode:     resw 1
best_area:     resd 1
