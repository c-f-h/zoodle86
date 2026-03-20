#!/usr/bin/env python3
import argparse
import math
import pathlib
import struct
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent

NASM_EXE = pathlib.Path(r"C:\Program Files\nasm-3.01\nasm.exe")
TCC32_EXE = pathlib.Path(r"C:\Program Files (x86)\tcc-0.9.27\i386-win32-tcc.exe")
BOCHS_EXE = pathlib.Path(r"C:\Program Files\Bochs-3.0\bochs.exe")
BOCHS_DIR = BOCHS_EXE.parent

BOOT_ASM = ROOT / "boot.asm"
BOOT_BIN = ROOT / "boot.bin"
INTERRUPTS_ASM = ROOT / "interrupts.asm"
INTERRUPTS_OBJ = ROOT / "interrupts.o"
KERNEL_C = ROOT / "kernel.c"
KERNEL_OBJ = ROOT / "kernel.o"
STAGE2_EXE = ROOT / "stage2.exe"
STAGE2_BIN = ROOT / "stage2.bin"
FLOPPY_IMG = ROOT / "floppy.img"
BOCHSRC = ROOT / "bochsrc.txt"

FLOPPY_SIZE = 1_474_560
STAGE2_IMAGE_BASE = 0x8000


def run(cmd: list[str]) -> None:
    completed = subprocess.run(cmd, cwd=ROOT)
    if completed.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {completed.returncode}: {' '.join(cmd)}")


def write_bochsrc() -> None:
    BOCHSRC.write_text(
        "\n".join(
            [
                "megs: 32",
                f'romimage: file="{BOCHS_DIR / "BIOS-bochs-latest"}", options=fastboot',
                f'vgaromimage: file="{BOCHS_DIR / "VGABIOS-lgpl-latest.bin"}"',
                "boot: floppy",
                'floppya: 1_44="floppy.img", status=inserted',
                "log: bochsout.txt",
                'display_library: win32, options="autoscale"',
                "panic: action=ask",
                "error: action=report",
                "info: action=report",
                "debug: action=ignore",
                "clock: sync=realtime",
                "",
            ]
        ),
        encoding="ascii",
    )


def flatten_pe(pe_path: pathlib.Path) -> tuple[bytes, int]:
    pe_bytes = pe_path.read_bytes()
    if len(pe_bytes) < 0x40:
        raise RuntimeError("stage2.exe is too small to be a valid PE image.")

    pe_header_offset = struct.unpack_from("<I", pe_bytes, 0x3C)[0]
    signature = struct.unpack_from("<I", pe_bytes, pe_header_offset)[0]
    if signature != 0x00004550:
        raise RuntimeError("stage2.exe does not contain a valid PE signature.")

    coff_offset = pe_header_offset + 4
    number_of_sections = struct.unpack_from("<H", pe_bytes, coff_offset + 2)[0]
    size_of_optional_header = struct.unpack_from("<H", pe_bytes, coff_offset + 16)[0]
    optional_offset = coff_offset + 20
    optional_magic = struct.unpack_from("<H", pe_bytes, optional_offset)[0]
    if optional_magic != 0x10B:
        raise RuntimeError(f"Expected a PE32 optional header, got 0x{optional_magic:X}.")

    entry_rva = struct.unpack_from("<I", pe_bytes, optional_offset + 16)[0]
    image_base = struct.unpack_from("<I", pe_bytes, optional_offset + 28)[0]
    if image_base != STAGE2_IMAGE_BASE:
        raise RuntimeError(f"Expected stage2 image base 0x{STAGE2_IMAGE_BASE:X}, got 0x{image_base:X}.")

    section_table_offset = optional_offset + size_of_optional_header
    image_size = 0
    sections: list[tuple[int, int, int]] = []
    for index in range(number_of_sections):
        section_offset = section_table_offset + (40 * index)
        virtual_size, virtual_address, size_of_raw_data, pointer_to_raw_data = struct.unpack_from(
            "<IIII", pe_bytes, section_offset + 8
        )
        image_size = max(image_size, virtual_address + max(virtual_size, size_of_raw_data))
        sections.append((virtual_address, size_of_raw_data, pointer_to_raw_data))

    flat = bytearray(image_size)
    for virtual_address, size_of_raw_data, pointer_to_raw_data in sections:
        if size_of_raw_data == 0:
            continue
        flat[virtual_address : virtual_address + size_of_raw_data] = pe_bytes[
            pointer_to_raw_data : pointer_to_raw_data + size_of_raw_data
        ]

    return bytes(flat), entry_rva


def build(build_only: bool) -> None:
    print(f"NASM : {NASM_EXE}")
    print(f"TCC  : {TCC32_EXE}")
    print(f"Bochs: {BOCHS_EXE}")

    write_bochsrc()

    for path in (INTERRUPTS_OBJ, KERNEL_OBJ):
        if path.exists():
            path.unlink()

    run([str(NASM_EXE), "-f", "elf32", str(INTERRUPTS_ASM), "-o", str(INTERRUPTS_OBJ)])
    run([str(TCC32_EXE), "-c", str(KERNEL_C)])

    if not INTERRUPTS_OBJ.exists():
        raise RuntimeError("NASM did not produce interrupts.o.")
    if not KERNEL_OBJ.exists():
        raise RuntimeError("TCC did not produce kernel.o.")

    run(
        [
            str(TCC32_EXE),
            "-nostdlib",
            "-Wl,-image-base=0x8000",
            "-Wl,-section-alignment=0x200",
            "-Wl,-file-alignment=0x200",
            "-o",
            str(STAGE2_EXE),
            str(INTERRUPTS_OBJ),
            str(KERNEL_OBJ),
        ]
    )

    stage2_bytes, entry_rva = flatten_pe(STAGE2_EXE)
    STAGE2_BIN.write_bytes(stage2_bytes)

    stage2_sectors = math.ceil(len(stage2_bytes) / 512.0)
    if stage2_sectors < 1:
        raise RuntimeError("Computed invalid stage2 sector count.")
    if stage2_sectors > 18:
        raise RuntimeError(
            f"stage2.bin requires {stage2_sectors} sectors, which does not fit in one floppy track with the current CHS loader."
        )

    run(
        [
            str(NASM_EXE),
            f"-DSTAGE2_SECTORS={stage2_sectors}",
            f"-DSTAGE2_ENTRY_OFFSET={entry_rva}",
            "-f",
            "bin",
            str(BOOT_ASM),
            "-o",
            str(BOOT_BIN),
        ]
    )

    boot_bytes = BOOT_BIN.read_bytes()
    if len(boot_bytes) != 512:
        raise RuntimeError(f"Boot sector must be exactly 512 bytes, got {len(boot_bytes)}.")

    image_bytes = bytearray(FLOPPY_SIZE)
    image_bytes[0 : len(boot_bytes)] = boot_bytes
    image_bytes[512 : 512 + len(stage2_bytes)] = stage2_bytes
    FLOPPY_IMG.write_bytes(image_bytes)

    print(f"Built {BOOT_BIN}, {STAGE2_BIN}, and {FLOPPY_IMG}")
    print(f"Stage2 entry offset: 0x{entry_rva:X}")
    print(f"Stage2 sectors     : {stage2_sectors}")

    if not build_only:
        run([str(BOCHS_EXE), "-q", "-f", str(BOCHSRC)])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()

    try:
        build(build_only=args.build_only)
    except Exception as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
