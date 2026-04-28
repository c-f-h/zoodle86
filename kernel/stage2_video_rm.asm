[bits 32]

global stage2_video_probe_and_set

BOOT_VIDEO_INFO_ADDR        equ 0x0600
VBE_CTRL_INFO_BUF           equ 0x2000
VBE_MODE_INFO_BUF           equ 0x2400
CODE32_SEL                  equ 0x08
DATA32_SEL                  equ 0x10
CODE16_SEL                  equ 0x18
DATA16_SEL                  equ 0x20

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

; Drop to real mode temporarily to run VBE BIOS calls, then return to protected mode.
; Returns 1 in EAX on success, 0 on failure.
stage2_video_probe_and_set:
    cli

    mov [saved_ebx], ebx
    mov [saved_esi], esi
    mov [saved_edi], edi
    mov [saved_ebp], ebp
    mov [saved_esp], esp

    mov byte [video_result], 0
    lgdt [pm_gdtr]

    jmp CODE16_SEL:protected_mode16_entry

[bits 16]
protected_mode16_entry:
    mov ax, DATA16_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000

    mov eax, cr0
    and eax, 0x7FFFFFFE
    mov cr0, eax

    jmp 0x0000:real_mode_entry

real_mode_entry:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    cld
    lidt [rm_idtr]

    call init_video_info

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

.done:
    cli
    lgdt [pm_gdtr]

    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax

    jmp CODE32_SEL:protected_mode_return

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

    mov byte [video_result], 1

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
    int 0x10
    cmp ax, 0x004F
    jne .bad

    mov ax, [di + 0x00]
    test ax, 0x0080
    jz .bad

    mov al, [di + 0x19]
    cmp al, 15
    jb .bad

    mov al, [di + 0x1B]
    cmp al, 4
    je .good
    cmp al, 6
    jne .bad

.good:
    movzx eax, word [di + 0x12]
    movzx edx, word [di + 0x14]
    imul eax, edx
    pop bx
    ret

.bad:
    xor eax, eax
    pop bx
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
protected_mode_return:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov esp, [saved_esp]

    mov ebx, [saved_ebx]
    mov esi, [saved_esi]
    mov edi, [saved_edi]
    mov ebp, [saved_ebp]

    xor eax, eax
    mov al, [video_result]
    ret

section .data
align 4
pm_gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
    dq 0x00009A000000FFFF
    dq 0x000092000000FFFF
pm_gdt_end:

pm_gdtr:
    dw pm_gdt_end - pm_gdt - 1
    dd pm_gdt

rm_idtr:
    dw 0x03FF
    dd 0x00000000

section .bss
align 4
saved_esp:    resd 1
saved_ebx:    resd 1
saved_esi:    resd 1
saved_edi:    resd 1
saved_ebp:    resd 1
video_result: resb 1
mode_list_off: resw 1
mode_list_seg: resw 1
best_mode:     resw 1
best_area:     resd 1
