import math
import os
import pathlib
import shutil
import struct
import subprocess

ROOT = pathlib.Path(Dir("#").abspath)
BUILD_DIR = ROOT / "build"

DEFAULT_NASM = pathlib.Path(r"C:\Program Files\nasm-3.01\nasm.exe")
DEFAULT_ZIG = "zig"
DEFAULT_BOCHS = pathlib.Path(r"C:\Program Files\Bochs-3.0\bochs.exe")
DEFAULT_QEMU = pathlib.Path(r"C:\Program Files\qemu\qemu-system-i386.exe")

NASM_EXE = pathlib.Path(os.environ.get("NASM_EXE", DEFAULT_NASM))
ZIG_EXE = os.environ.get("ZIG_EXE") or shutil.which(DEFAULT_ZIG) or DEFAULT_ZIG
BOCHS_EXE = pathlib.Path(os.environ.get("BOCHS_EXE", DEFAULT_BOCHS))
QEMU_EXE = pathlib.Path(os.environ.get("QEMU_EXE", DEFAULT_QEMU))
BOCHS_DIR = BOCHS_EXE.parent

BOOT_ASM = ROOT / "boot.asm"
INTERRUPTS_ASM = ROOT / "interrupts.asm"
STAGE2_LINKER_SCRIPT = ROOT / "stage2.ld"
ZIG_KERNEL_SRC = ROOT / "kernel.zig"
BOCHSRC = ROOT / "bochsrc.txt"
BOCHSOUT = ROOT / "bochsout.txt"

IMAGE_SIZE = 1_474_560
STAGE2_IMAGE_BASE = 0x8000
STAGE2_RESERVED_SECTORS = 63    # NB: must match the value in fs.zig


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
BOOT_IMG = BUILD_DIR / "image.img"
BOCHSRC_PATH = build_artifact(BOCHSRC)
BOCHSOUT_PATH = build_artifact(BOCHSOUT)
ZIG_OBJ = build_artifact(ZIG_KERNEL_SRC, ".o")
ZIG_CACHE_DIR = BUILD_DIR / ".zig-cache"
ZIG_GLOBAL_CACHE_DIR = BUILD_DIR / ".zig-global-cache"


def write_bochsrc(target, source, env):
    target_path = pathlib.Path(str(target[0]))
    ensure_parent(target_path)
    target_path.write_text(
        "\n".join(
            [
                "megs: 32",
                f'romimage: file="{BOCHS_DIR / "BIOS-bochs-latest"}", options=fastboot',
                f'vgaromimage: file="{BOCHS_DIR / "VGABIOS-lgpl-latest.bin"}"',
                "boot: c",
                f'ata0-master: type=disk, path="{BOOT_IMG.relative_to(ROOT)}", mode=flat',
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


def assemble_interrupts(target, source, env):
    ensure_parent(INTERRUPTS_OBJ)
    run([str(NASM_EXE), "-f", "elf32", str(INTERRUPTS_ASM), "-o", str(INTERRUPTS_OBJ)])
    if not INTERRUPTS_OBJ.exists():
        raise RuntimeError("NASM did not produce interrupts.o.")


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
            str(ZIG_OBJ),
        ]
    )


def build_stage2_payload(target, source, env):
    stage2_path = pathlib.Path(str(target[0]))
    meta_path = pathlib.Path(str(target[1]))
    ensure_parent(stage2_path)
    ensure_parent(meta_path)

    run([
        str(ZIG_EXE), "run", str(ROOT / "flatten_elf.zig"), "--",
        str(pathlib.Path(str(source[0])).absolute()),
        str(stage2_path.absolute()),
        str(meta_path.absolute()),
    ])

    meta_lines = meta_path.read_text(encoding="ascii").splitlines()
    if len(meta_lines) < 2:
        raise RuntimeError("stage2.meta is malformed.")
    entry_rva = int(meta_lines[0], 10)
    stage2_sectors = int(meta_lines[1], 10)

    if stage2_sectors < 1:
        raise RuntimeError("Computed invalid stage2 sector count.")
    if stage2_sectors > STAGE2_RESERVED_SECTORS:
        raise RuntimeError(
            f"stage2.bin requires {stage2_sectors} sectors, but only {STAGE2_RESERVED_SECTORS} sectors are reserved after the boot sector."
        )


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
            "-f", "bin",
            str(BOOT_ASM),
            "-o", str(output_path),
        ]
    )


def build_image(target, source, env):
    target_path = pathlib.Path(str(target[0]))
    ensure_parent(target_path)      # ensure build directory exists
    
    boot_bytes = pathlib.Path(str(source[0])).read_bytes()
    if len(boot_bytes) != 512:
        raise RuntimeError(f"Boot sector must be exactly 512 bytes, got {len(boot_bytes)}.")
    stage2_bytes = pathlib.Path(str(source[1])).read_bytes()
    reserved_stage2_bytes = STAGE2_RESERVED_SECTORS * 512
    if len(stage2_bytes) > reserved_stage2_bytes:
        raise RuntimeError(f"stage2.bin exceeds the reserved {STAGE2_RESERVED_SECTORS}-sector stage2 area.")
    if 512 + reserved_stage2_bytes > IMAGE_SIZE:
        raise RuntimeError("Reserved stage2 area does not fit in the disk image.")
    
    # If target doesn't exist, create it full of zeros
    if not target_path.exists():
        target_path.write_bytes(b"\x00" * IMAGE_SIZE)
    
    # Open for modification and patch in the boot sector and reserved stage2 area.
    img_file = target_path.open("r+b")
    img_file.write(boot_bytes)
    img_file.write(b"\x00" * reserved_stage2_bytes)
    img_file.seek(512)
    img_file.write(stage2_bytes)
    img_file.close()


def run_bochs(target, source, env):
    print(f"NASM : {NASM_EXE}")
    print(f"Bochs: {BOCHS_EXE}")
    completed = subprocess.run([str(BOCHS_EXE), "-q", "-f", str(BOCHSRC_PATH)], cwd=ROOT)
    if completed.returncode not in (0, 1):
        raise RuntimeError(
            f"Command failed with exit code {completed.returncode}: "
            f"{' '.join(map(str, [BOCHS_EXE, '-q', '-f', BOCHSRC_PATH]))}"
        )


def run_qemu(target, source, env):
    print(f"NASM : {NASM_EXE}")
    print(f"QEMU : {QEMU_EXE}")
    completed = subprocess.run(
        [
            str(QEMU_EXE),
            "-m", "32",
            "-boot", "order=ac",
            "-drive", f"file={BOOT_IMG},if=ide,format=raw",
        ],
        cwd=ROOT,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Command qemu failed with exit code {completed.returncode}"
        )

env = Environment(ENV=os.environ)

bochsrc = env.Command(str(BOCHSRC_PATH), [], Action(write_bochsrc, "Generating $TARGET"))
interrupts_obj = env.Command(str(INTERRUPTS_OBJ), str(INTERRUPTS_ASM), Action(assemble_interrupts, "Assembling $TARGET"))
# build always because zig imports are not correctly tracked by scons - let zig figure it out
zig_obj = AlwaysBuild(env.Command(str(ZIG_OBJ), str(ZIG_KERNEL_SRC), Action(compile_zig, "Compiling $TARGET")))
stage2_exe = env.Command(str(STAGE2_EXE), [interrupts_obj, zig_obj], Action(link_stage2, "Linking $TARGET"))
stage2_payload = env.Command(
    [str(STAGE2_BIN), str(STAGE2_META)],
    stage2_exe,
    Action(build_stage2_payload, "Flattening $SOURCE"),
)
boot_bin = env.Command(str(BOOT_BIN), [str(BOOT_ASM), stage2_payload[1]], Action(assemble_boot, "Assembling $TARGET"))
boot_img = env.Command(str(BOOT_IMG), [boot_bin, stage2_payload[0]], Action(build_image, "Packing $TARGET"))
env.Precious(boot_img)

Default(boot_img)
AlwaysBuild(env.Alias("run", [boot_img, bochsrc], Action(run_bochs, "Running Bochs")))
AlwaysBuild(env.Alias("qemu", [boot_img], Action(run_qemu, "Running QEMU")))
