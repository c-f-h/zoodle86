# Interrupts & Exception Handling

## Protected Mode & Segmentation

The kernel initializes a GDT with kernel code/data segments (DPL 0), user code/data segments (DPL 3), and per-task Task State Segment (TSS) descriptors for ring transitions. Interrupts and exceptions load a 256-entry IDT with gate types for task gates and 16/32-bit interrupt/trap gates.

## Interrupt Controller Initialization (ACPI + APIC)

During `kernel_enter()`, after early paging and allocator setup, `acpi.init()` scans for the RSDP in EBDA/BIOS regions, maps and validates ACPI SDTs (including RSDT and MADT), and extracts APIC topology data. `apic.initApic()` then maps LAPIC and I/O APIC MMIO regions uncached, verifies controller presence, disables the legacy 8259 PIC, enables the local APIC, applies MADT interrupt source overrides (IRQ→GSI remaps), and programs the keyboard interrupt route to IDT vector `0x21` via the I/O APIC.

## Exception Handling

The kernel handles multiple exception types including Page Fault (0x0E), General Protection Fault (0x0D), and others. Low-level entry stubs in `interrupts.asm` normalize all interrupts/exceptions/syscalls onto a shared interrupt-frame prefix (defined in `interrupt_frame.zig`). All handlers converge on `kernel.interrupt_dispatch()` which routes to specific handlers based on vector type. User-mode faults terminate the offending task without crashing the kernel.
