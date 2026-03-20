import math
import os
import pathlib
import struct
import subprocess

ROOT = pathlib.Path(Dir("#").abspath)
BUILD_DIR = ROOT / "build"

DEFAULT_NASM = pathlib.Path(r"C:\Program Files\nasm-3.01\nasm.exe")
DEFAULT_TCC32 = pathlib.Path(r"C:\Program Files (x86)\tcc-0.9.27\i386-win32-tcc.exe")
DEFAULT_BOCHS = pathlib.Path(r"C:\Program Files\Bochs-3.0\bochs.exe")

NASM_EXE = pathlib.Path(os.environ.get("NASM_EXE", DEFAULT_NASM))
TCC32_EXE = pathlib.Path(os.environ.get("TCC32_EXE", DEFAULT_TCC32))
BOCHS_EXE = pathlib.Path(os.environ.get("BOCHS_EXE", DEFAULT_BOCHS))
BOCHS_DIR = BOCHS_EXE.parent

BOOT_ASM = ROOT / "boot.asm"
INTERRUPTS_ASM = ROOT / "interrupts.asm"
KERNEL_C_SOURCES = [
    ROOT / "console.c",
    ROOT / "keyboard.c",
    ROOT / "kernel.c",
    ROOT / "vgatext.c",
]
BOCHSRC = ROOT / "bochsrc.txt"
BOCHSOUT = ROOT / "bochsout.txt"

FLOPPY_SIZE = 1_474_560
STAGE2_IMAGE_BASE = 0x8000


def run(cmd):
    completed = subprocess.run(cmd, cwd=ROOT)
    if completed.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {completed.returncode}: {' '.join(map(str, cmd))}")


def sibling_with_suffix(path, suffix):
    return path.with_suffix(suffix)


def build_artifact(path, suffix=None):
    artifact_name = path.name if suffix is None else path.with_suffix(suffix).name
    return BUILD_DIR / artifact_name


def ensure_parent(path):
    path.parent.mkdir(parents=True, exist_ok=True)


BOOT_BIN = build_artifact(BOOT_ASM, ".bin")
INTERRUPTS_OBJ = build_artifact(INTERRUPTS_ASM, ".o")
STAGE2_EXE = BUILD_DIR / "stage2.exe"
STAGE2_BIN = build_artifact(STAGE2_EXE, ".bin")
STAGE2_META = build_artifact(STAGE2_EXE, ".meta")
FLOPPY_IMG = BUILD_DIR / "floppy.img"
BOCHSRC_PATH = build_artifact(BOCHSRC)
BOCHSOUT_PATH = build_artifact(BOCHSOUT)
KERNEL_OBJS = [build_artifact(source, ".o") for source in KERNEL_C_SOURCES]


def flatten_pe(pe_path):
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
    sections = []
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


def write_bochsrc(target, source, env):
    target_path = pathlib.Path(str(target[0]))
    ensure_parent(target_path)
    target_path.write_text(
        "\n".join(
            [
                "megs: 32",
                f'romimage: file="{BOCHS_DIR / "BIOS-bochs-latest"}", options=fastboot',
                f'vgaromimage: file="{BOCHS_DIR / "VGABIOS-lgpl-latest.bin"}"',
                "boot: floppy",
                f'floppya: 1_44="{FLOPPY_IMG.relative_to(ROOT)}", status=inserted',
                f'log: {BOCHSOUT_PATH.relative_to(ROOT)}',
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
    return None


def assemble_interrupts(target, source, env):
    ensure_parent(INTERRUPTS_OBJ)
    run([str(NASM_EXE), "-f", "elf32", str(INTERRUPTS_ASM), "-o", str(INTERRUPTS_OBJ)])
    if not INTERRUPTS_OBJ.exists():
        raise RuntimeError("NASM did not produce interrupts.o.")
    return None


def compile_kernel(target, source, env):
    output_path = pathlib.Path(str(target[0]))
    source_path = pathlib.Path(str(source[0]))
    ensure_parent(output_path)
    if output_path.exists():
        output_path.unlink()
    run([str(TCC32_EXE), "-c", str(source_path), "-o", str(output_path)])
    if not output_path.exists():
        raise RuntimeError(f"TCC did not produce {output_path.name}.")
    return None


def link_stage2(target, source, env):
    output_path = pathlib.Path(str(target[0]))
    ensure_parent(output_path)
    if output_path.exists():
        output_path.unlink()
    run(
        [
            str(TCC32_EXE),
            "-nostdlib",
            "-Wl,-image-base=0x8000",
            "-Wl,-section-alignment=0x200",
            "-Wl,-file-alignment=0x200",
            "-o",
            str(output_path),
            str(INTERRUPTS_OBJ),
            *[str(path) for path in KERNEL_OBJS],
        ]
    )
    return None


def build_stage2_payload(target, source, env):
    stage2_path = pathlib.Path(str(target[0]))
    meta_path = pathlib.Path(str(target[1]))
    ensure_parent(stage2_path)
    ensure_parent(meta_path)
    stage2_bytes, entry_rva = flatten_pe(pathlib.Path(str(source[0])))
    stage2_path.write_bytes(stage2_bytes)

    stage2_sectors = math.ceil(len(stage2_bytes) / 512.0)
    if stage2_sectors < 1:
        raise RuntimeError("Computed invalid stage2 sector count.")
    if stage2_sectors > 18:
        raise RuntimeError(
            f"stage2.bin requires {stage2_sectors} sectors, which does not fit in one floppy track with the current CHS loader."
        )

    meta_path.write_text(f"{entry_rva}\n{stage2_sectors}\n", encoding="ascii")
    return None


def assemble_boot(target, source, env):
    output_path = pathlib.Path(str(target[0]))
    ensure_parent(output_path)
    meta_lines = pathlib.Path(str(source[1])).read_text(encoding="ascii").splitlines()
    if len(meta_lines) < 2:
        raise RuntimeError("stage2.meta is malformed.")

    entry_rva = int(meta_lines[0], 10)
    stage2_sectors = int(meta_lines[1], 10)

    run(
        [
            str(NASM_EXE),
            f"-DSTAGE2_SECTORS={stage2_sectors}",
            f"-DSTAGE2_ENTRY_OFFSET={entry_rva}",
            "-f",
            "bin",
            str(BOOT_ASM),
            "-o",
            str(output_path),
        ]
    )

    boot_bytes = output_path.read_bytes()
    if len(boot_bytes) != 512:
        raise RuntimeError(f"Boot sector must be exactly 512 bytes, got {len(boot_bytes)}.")
    return None


def build_floppy(target, source, env):
    target_path = pathlib.Path(str(target[0]))
    ensure_parent(target_path)
    boot_bytes = pathlib.Path(str(source[0])).read_bytes()
    stage2_bytes = pathlib.Path(str(source[1])).read_bytes()
    image_bytes = bytearray(FLOPPY_SIZE)
    image_bytes[0 : len(boot_bytes)] = boot_bytes
    image_bytes[512 : 512 + len(stage2_bytes)] = stage2_bytes
    target_path.write_bytes(image_bytes)
    return None


def run_bochs(target, source, env):
    print(f"NASM : {NASM_EXE}")
    print(f"TCC  : {TCC32_EXE}")
    print(f"Bochs: {BOCHS_EXE}")
    completed = subprocess.run([str(BOCHS_EXE), "-q", "-f", str(BOCHSRC_PATH)], cwd=ROOT)
    if completed.returncode not in (0, 1):
        raise RuntimeError(
            f"Command failed with exit code {completed.returncode}: "
            f"{' '.join(map(str, [BOCHS_EXE, '-q', '-f', BOCHSRC_PATH]))}"
        )
    return None


env = Environment(ENV=os.environ)

bochsrc = env.Command(str(BOCHSRC_PATH), [], Action(write_bochsrc, "Generating $TARGET"))
interrupts_obj = env.Command(str(INTERRUPTS_OBJ), str(INTERRUPTS_ASM), Action(assemble_interrupts, "Assembling $TARGET"))
kernel_objs = [
    env.Command(str(obj_path), str(source_path), Action(compile_kernel, "Compiling $TARGET"))
    for source_path, obj_path in zip(KERNEL_C_SOURCES, KERNEL_OBJS)
]
stage2_exe = env.Command(str(STAGE2_EXE), [interrupts_obj, *kernel_objs], Action(link_stage2, "Linking $TARGET"))
stage2_payload = env.Command(
    [str(STAGE2_BIN), str(STAGE2_META)],
    stage2_exe,
    Action(build_stage2_payload, "Flattening $SOURCE"),
)
boot_bin = env.Command(str(BOOT_BIN), [str(BOOT_ASM), stage2_payload[1]], Action(assemble_boot, "Assembling $TARGET"))
floppy_img = env.Command(str(FLOPPY_IMG), [boot_bin, stage2_payload[0]], Action(build_floppy, "Packing $TARGET"))

Default(floppy_img)
AlwaysBuild(env.Alias("run", [floppy_img, bochsrc], Action(run_bochs, "Running Bochs")))
