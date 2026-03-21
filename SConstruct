import math
import os
import pathlib
import shutil
import struct
import subprocess

ROOT = pathlib.Path(Dir("#").abspath)
BUILD_DIR = ROOT / "build"

DEFAULT_NASM = pathlib.Path(r"C:\Program Files\nasm-3.01\nasm.exe")
DEFAULT_TCC32 = pathlib.Path(r"C:\Program Files (x86)\tcc-0.9.27\i386-win32-tcc.exe")
DEFAULT_ZIG = "zig"
DEFAULT_BOCHS = pathlib.Path(r"C:\Program Files\Bochs-3.0\bochs.exe")
DEFAULT_QEMU = pathlib.Path(r"C:\Program Files\qemu\qemu-system-i386.exe")

NASM_EXE = pathlib.Path(os.environ.get("NASM_EXE", DEFAULT_NASM))
TCC32_EXE = pathlib.Path(os.environ.get("TCC32_EXE", DEFAULT_TCC32))
ZIG_EXE = os.environ.get("ZIG_EXE") or shutil.which(DEFAULT_ZIG) or DEFAULT_ZIG
BOCHS_EXE = pathlib.Path(os.environ.get("BOCHS_EXE", DEFAULT_BOCHS))
QEMU_EXE = pathlib.Path(os.environ.get("QEMU_EXE", DEFAULT_QEMU))
BOCHS_DIR = BOCHS_EXE.parent

BOOT_ASM = ROOT / "boot.asm"
INTERRUPTS_ASM = ROOT / "interrupts.asm"
STAGE2_LINKER_SCRIPT = ROOT / "stage2.ld"
ZIG_SOURCES = [
    ROOT / "readline.zig",
]
KERNEL_C_SOURCES = [
    ROOT / "console.c",
    ROOT / "keyboard.c",
    ROOT / "kernel.c",
    ROOT / "vgatext.c",
    ####################
    ROOT / "app_keylog.c",
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
STAGE2_EXE = BUILD_DIR / "stage2.elf"
STAGE2_BIN = build_artifact(STAGE2_EXE, ".bin")
STAGE2_META = build_artifact(STAGE2_EXE, ".meta")
FLOPPY_IMG = BUILD_DIR / "floppy.img"
BOCHSRC_PATH = build_artifact(BOCHSRC)
BOCHSOUT_PATH = build_artifact(BOCHSOUT)
KERNEL_OBJS = [build_artifact(source, ".o") for source in KERNEL_C_SOURCES]
ZIG_OBJS = [build_artifact(source, ".o") for source in ZIG_SOURCES]
ZIG_CACHE_DIR = BUILD_DIR / ".zig-cache"
ZIG_GLOBAL_CACHE_DIR = BUILD_DIR / ".zig-global-cache"


def flatten_elf(elf_path):
    elf_bytes = elf_path.read_bytes()
    if len(elf_bytes) < 52:
        raise RuntimeError("stage2.elf is too small to be a valid ELF image.")
    if elf_bytes[0:4] != b"\x7fELF":
        raise RuntimeError("stage2.elf does not contain a valid ELF signature.")
    if elf_bytes[4] != 1:
        raise RuntimeError("Expected a 32-bit ELF image.")
    if elf_bytes[5] != 1:
        raise RuntimeError("Expected a little-endian ELF image.")

    e_type, e_machine, _, e_entry, e_phoff, _, _, _, e_phentsize, e_phnum = struct.unpack_from(
        "<HHIIIIIHHH", elf_bytes, 16
    )
    if e_type != 2:
        raise RuntimeError(f"Expected an executable ELF image, got type {e_type}.")
    if e_machine != 3:
        raise RuntimeError(f"Expected an x86 ELF image, got machine {e_machine}.")
    if e_phentsize != 32:
        raise RuntimeError(f"Expected ELF32 program headers of size 32, got {e_phentsize}.")

    load_segments = []
    image_base = None
    image_end = 0
    for index in range(e_phnum):
        phoff = e_phoff + (index * e_phentsize)
        p_type, p_offset, p_vaddr, _, p_filesz, p_memsz, _, _ = struct.unpack_from("<IIIIIIII", elf_bytes, phoff)
        if p_type != 1:
            continue
        if image_base is None:
            image_base = p_vaddr
        else:
            image_base = min(image_base, p_vaddr)
        image_end = max(image_end, p_vaddr + p_memsz)
        load_segments.append((p_vaddr, p_offset, p_filesz, p_memsz))

    if image_base is None:
        raise RuntimeError("ELF image does not contain any PT_LOAD segments.")
    if image_base != STAGE2_IMAGE_BASE:
        raise RuntimeError(f"Expected stage2 image base 0x{STAGE2_IMAGE_BASE:X}, got 0x{image_base:X}.")

    flat = bytearray(image_end - image_base)
    for p_vaddr, p_offset, p_filesz, p_memsz in load_segments:
        dest_offset = p_vaddr - image_base
        flat[dest_offset : dest_offset + p_filesz] = elf_bytes[p_offset : p_offset + p_filesz]
        if p_memsz > p_filesz:
            flat[dest_offset + p_filesz : dest_offset + p_memsz] = b"\x00" * (p_memsz - p_filesz)

    return bytes(flat), e_entry - image_base


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


COMMON_ZIG_OPTS = [
    "--cache-dir", str(ZIG_CACHE_DIR),
    "--global-cache-dir", str(ZIG_GLOBAL_CACHE_DIR),
    "-I", str(ROOT),
    "-target", "x86-freestanding-none",
    "-O",
    "ReleaseSmall",
    "-fno-stack-protector",
]

def compile_zig(target, source, env):
    output_path = pathlib.Path(str(target[0]))
    source_path = pathlib.Path(str(source[0]))
    ensure_parent(output_path)
    ensure_parent(ZIG_CACHE_DIR / "cache")
    ensure_parent(ZIG_GLOBAL_CACHE_DIR / "cache")
    if output_path.exists():
        output_path.unlink()
    run(
        [
            str(ZIG_EXE),
            "build-obj",
            str(source_path),
            *COMMON_ZIG_OPTS,
            "-ofmt=elf",
            "-fno-entry",
            f"-femit-bin={output_path}",
        ]
    )
    if not output_path.exists():
        raise RuntimeError(f"Zig did not produce {output_path.name}.")
    return None


def link_stage2(target, source, env):
    output_path = pathlib.Path(str(target[0]))
    ensure_parent(output_path)
    if output_path.exists():
        output_path.unlink()
    run(
        [
            str(ZIG_EXE),
            "build-exe",
            *COMMON_ZIG_OPTS,
            "-fentry=_start",
            "-fno-compiler-rt",
            "-T",
            str(STAGE2_LINKER_SCRIPT),
            f"-femit-bin={output_path.as_posix()}",
            str(INTERRUPTS_OBJ),
            *[str(path) for path in KERNEL_OBJS],
            *[str(path) for path in ZIG_OBJS],
        ]
    )
    return None


def build_stage2_payload(target, source, env):
    stage2_path = pathlib.Path(str(target[0]))
    meta_path = pathlib.Path(str(target[1]))
    ensure_parent(stage2_path)
    ensure_parent(meta_path)
    stage2_bytes, entry_rva = flatten_elf(pathlib.Path(str(source[0])))
    stage2_path.write_bytes(stage2_bytes)

    stage2_sectors = math.ceil(len(stage2_bytes) / 512.0)
    if stage2_sectors < 1:
        raise RuntimeError("Computed invalid stage2 sector count.")
    max_stage2_sectors = (FLOPPY_SIZE // 512) - 1
    if stage2_sectors > max_stage2_sectors:
        raise RuntimeError(
            f"stage2.bin requires {stage2_sectors} sectors, but only {max_stage2_sectors} sectors fit after the boot sector."
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
    if 512 + len(stage2_bytes) > FLOPPY_SIZE:
        raise RuntimeError("stage2.bin does not fit in the floppy image.")
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


def run_qemu(target, source, env):
    print(f"NASM : {NASM_EXE}")
    print(f"TCC  : {TCC32_EXE}")
    print(f"QEMU : {QEMU_EXE}")
    completed = subprocess.run(
        [
            str(QEMU_EXE),
            "-m",
            "32",
            "-boot",
            "a",
            "-drive",
            f"file={FLOPPY_IMG},if=floppy,format=raw",
        ],
        cwd=ROOT,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {completed.returncode}: "
            f"{' '.join(map(str, [QEMU_EXE, '-m', '32', '-boot', 'a', '-drive', f'file={FLOPPY_IMG},if=floppy,format=raw']))}"
        )
    return None


env = Environment(ENV=os.environ)

bochsrc = env.Command(str(BOCHSRC_PATH), [], Action(write_bochsrc, "Generating $TARGET"))
interrupts_obj = env.Command(str(INTERRUPTS_OBJ), str(INTERRUPTS_ASM), Action(assemble_interrupts, "Assembling $TARGET"))
kernel_objs = [
    env.Command(str(obj_path), str(source_path), Action(compile_kernel, "Compiling $TARGET"))
    for source_path, obj_path in zip(KERNEL_C_SOURCES, KERNEL_OBJS)
]
zig_objs = [
    env.Command(str(obj_path), str(source_path), Action(compile_zig, "Compiling $TARGET"))
    for source_path, obj_path in zip(ZIG_SOURCES, ZIG_OBJS)
]
stage2_exe = env.Command(str(STAGE2_EXE), [interrupts_obj, *kernel_objs, *zig_objs], Action(link_stage2, "Linking $TARGET"))
stage2_payload = env.Command(
    [str(STAGE2_BIN), str(STAGE2_META)],
    stage2_exe,
    Action(build_stage2_payload, "Flattening $SOURCE"),
)
boot_bin = env.Command(str(BOOT_BIN), [str(BOOT_ASM), stage2_payload[1]], Action(assemble_boot, "Assembling $TARGET"))
floppy_img = env.Command(str(FLOPPY_IMG), [boot_bin, stage2_payload[0]], Action(build_floppy, "Packing $TARGET"))

Default(floppy_img)
AlwaysBuild(env.Alias("run", [floppy_img, bochsrc], Action(run_bochs, "Running Bochs")))
AlwaysBuild(env.Alias("qemu", [floppy_img], Action(run_qemu, "Running QEMU")))
