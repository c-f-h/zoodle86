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
INTERRUPTS_ASM = ROOT / "kernel" / "interrupts.asm"
STAGE2_LINKER_SCRIPT = ROOT / "stage2.ld"
USERSPACE_LINKER_SCRIPT = ROOT / "userspace.ld"
ZIG_KERNEL_SRC = ROOT / "kernel" / "kernel.zig"
USERSPACE_SOURCES = [
    ROOT / "userspace" / "hello.zig",
    ROOT / "userspace" / "fs_stress.zig",
]
BOCHSRC = ROOT / "bochsrc.txt"
BOCHSOUT = ROOT / "bochsout.txt"
SERIALOUT = BUILD_DIR / "serial.txt"
AUTOEXEC_FILENAME = "autoexec"

IMAGE_SIZE = 1_474_560
STAGE2_IMAGE_BASE = 0x8000
STAGE2_RESERVED_SECTORS = 63    # NB: must match fs_defs.zig STAGE2_RESERVED_SECTORS


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


def reset_dir(path):
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def get_autoexec_script():
    script = ARGUMENTS.get("AUTOEXEC", "")
    return script.replace("\\r\\n", "\n").replace("\\n", "\n").replace("\r\n", "\n").replace("\r", "\n")


BOOT_BIN = build_artifact(BOOT_ASM, ".bin")
INTERRUPTS_OBJ = build_artifact(INTERRUPTS_ASM, ".o")
STAGE2_EXE = BUILD_DIR / "stage2.elf"
STAGE2_BIN = build_artifact(STAGE2_EXE, ".bin")
STAGE2_META = build_artifact(STAGE2_EXE, ".meta")
FS_IMAGE_DIR = BUILD_DIR / "fsimage"   # temp dir for collecting filesystem contents
FS_IMAGE = BUILD_DIR / "fsimage.img"   # file system image, without bootloader and stage 2
BOOT_IMG = BUILD_DIR / "image.img"     # final image with bootloader/stage 2/filesystem
BOCHSRC_PATH = build_artifact(BOCHSRC)
BOCHSOUT_PATH = build_artifact(BOCHSOUT)
SERIALOUT_PATH = SERIALOUT
USERSPACE_EXES = [build_artifact(path, ".elf") for path in USERSPACE_SOURCES]
ZIG_CACHE_DIR = BUILD_DIR / ".zig-cache"
ZIG_GLOBAL_CACHE_DIR = BUILD_DIR / ".zig-global-cache"
IMAGE_SIZE_SECTORS = IMAGE_SIZE // 512


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
                f'com1: enabled=1, mode=file, dev="{SERIALOUT_PATH.relative_to(ROOT).as_posix()}"',
                'display_library: win32, options="autoscale, gui_debug"',
                "panic: action=ask",
                "error: action=report",
                "info: action=report",
                "debug: action=ignore",
                "clock: sync=realtime",
                "magic_break: enabled=1",  # use xchg bx, bx to break
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
    "-O", "ReleaseSmall",
    "-fno-stack-protector",
]

def build_stage2(target, source, env):
    """Compile kernel.zig and link it with interrupts.o into stage2.elf in one
    build-exe step.  Using build-exe with a .zig source file (rather than a
    pre-compiled .o) causes Zig's LLVM backend to emit local STT_FUNC symbol
    table entries for every non-inlined internal function; useful for debugging."""
    output_path = pathlib.Path(str(target[0]))
    linker_script = str(source[-1])
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
            "-fno-strip",
            "-T", linker_script,
            f"-femit-bin={output_path.as_posix()}",
            str(INTERRUPTS_OBJ),
            str(ZIG_KERNEL_SRC),
        ]
    )

def build_userspace_exe(target, source, env):
    output_path = pathlib.Path(str(target[0]))
    source_path = pathlib.Path(str(source[0]))
    linker_script = str(source[1])
    ensure_parent(output_path)
    ensure_parent(ZIG_CACHE_DIR / "cache")
    ensure_parent(ZIG_GLOBAL_CACHE_DIR / "cache")
    if output_path.exists():
        output_path.unlink()
    run(
        [
            str(ZIG_EXE),
            "build-exe",
            *COMMON_ZIG_OPTS,
            "-ofmt=elf",
            "-fentry=_start",
            "-fno-compiler-rt",
            "-T", linker_script,
            f"-femit-bin={output_path.as_posix()}",
            str(source_path),
        ]
    )
    if not output_path.exists():
        raise RuntimeError(f"Zig did not produce {output_path.name}.")


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


def build_fs_image(target, source, env):
    target_path = pathlib.Path(str(target[0]))
    ensure_parent(target_path)
    if target_path.exists():
        target_path.unlink()

    reset_dir(FS_IMAGE_DIR)

    # preserve any existing filesystem contents of image.img
    if BOOT_IMG.exists():
        run(
            [
                str(ZIG_EXE), "run", str(ROOT / "extract_fs.zig"),
                "--",
                str(BOOT_IMG.absolute()),
                str(FS_IMAGE_DIR.absolute()),
            ]
        )

    # Inject each userspace binary into the filesystem image, dropping the .elf extension.
    for userspace_exe in source[0:len(USERSPACE_EXES)]:
        userspace_path = pathlib.Path(str(userspace_exe))
        shutil.copy2(userspace_path, FS_IMAGE_DIR / userspace_path.stem)

    autoexec_path = FS_IMAGE_DIR / AUTOEXEC_FILENAME
    autoexec_script = get_autoexec_script()
    if autoexec_script:
        if not autoexec_script.endswith("\n"):
            autoexec_script += "\n"
        autoexec_path.write_text(autoexec_script, encoding="utf-8")
    elif autoexec_path.exists():
        autoexec_path.unlink()

    run(
        [
            str(ZIG_EXE), "run", str(ROOT / "compile_fs.zig"),
            "--",
            str(FS_IMAGE_DIR.absolute()),
            str(IMAGE_SIZE_SECTORS),
            str(target_path.absolute()),
        ]
    )


def build_image(target, source, env):
    target_path = pathlib.Path(str(target[0]))
    ensure_parent(target_path)

    fs_image_bytes = pathlib.Path(str(source[0])).read_bytes()
    if len(fs_image_bytes) != IMAGE_SIZE:
        raise RuntimeError(f"Filesystem image must be exactly {IMAGE_SIZE} bytes, got {len(fs_image_bytes)}.")

    boot_bytes = pathlib.Path(str(source[1])).read_bytes()
    if len(boot_bytes) != 512:
        raise RuntimeError(f"Boot sector must be exactly 512 bytes, got {len(boot_bytes)}.")
    stage2_bytes = pathlib.Path(str(source[2])).read_bytes()
    reserved_stage2_bytes = STAGE2_RESERVED_SECTORS * 512
    if len(stage2_bytes) > reserved_stage2_bytes:
        raise RuntimeError(f"stage2.bin exceeds the reserved {STAGE2_RESERVED_SECTORS}-sector stage2 area.")
    if 512 + reserved_stage2_bytes > IMAGE_SIZE:
        raise RuntimeError("Reserved stage2 area does not fit in the disk image.")

    target_path.write_bytes(fs_image_bytes)
    with target_path.open("r+b") as img_file:
        img_file.write(boot_bytes)
        img_file.write(b"\x00" * reserved_stage2_bytes)
        img_file.seek(512)
        img_file.write(stage2_bytes)

def check_bochs_returncode(rc):
    if rc not in (0, 1):
        raise RuntimeError(f"Bochs failed with exit code {rc}")

def run_bochs(target, source, env):
    print(f"Bochs: {BOCHS_EXE}")
    completed = subprocess.run([str(BOCHS_EXE), "-q", "-f", str(BOCHSRC_PATH)], cwd=ROOT)
    check_bochs_returncode(completed.returncode)

def debug_bochs(target, source, env):
    print(f"Bochs: {BOCHS_EXE}")
    completed = subprocess.run([str(BOCHS_EXE), "-q", "-f", str(BOCHSRC_PATH), "-debugger"], cwd=ROOT)
    check_bochs_returncode(completed.returncode)

def run_qemu(target, source, env):
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
# Always rebuild: zig imports are not tracked by scons, let zig handle caching.
stage2_exe = AlwaysBuild(env.Command(str(STAGE2_EXE), [interrupts_obj, str(ZIG_KERNEL_SRC), STAGE2_LINKER_SCRIPT], Action(build_stage2, "Compiling and linking $TARGET")))
stage2_payload = env.Command(
    [str(STAGE2_BIN), str(STAGE2_META)],
    stage2_exe,
    Action(build_stage2_payload, "Flattening $SOURCE"),
)
boot_bin = env.Command(str(BOOT_BIN), [BOOT_ASM, stage2_payload[1]], Action(assemble_boot, "Assembling $TARGET"))
userspace_exes = [
    AlwaysBuild(env.Command(str(userspace_exe), [str(userspace_src), USERSPACE_LINKER_SCRIPT], Action(build_userspace_exe, "Compiling $TARGET")))
    for userspace_src, userspace_exe in zip(USERSPACE_SOURCES, USERSPACE_EXES)
]
autoexec_value = env.Value(get_autoexec_script())
fsimage = env.Command(str(FS_IMAGE), userspace_exes + [autoexec_value], Action(build_fs_image, "Building $TARGET"))
boot_img = env.Command(str(BOOT_IMG), [fsimage, boot_bin, stage2_payload[0]], Action(build_image, "Packing $TARGET"))
env.Precious(boot_img)

Default(boot_img)
AlwaysBuild(env.Alias("run", [boot_img, bochsrc], Action(run_bochs, "Running Bochs")))
AlwaysBuild(env.Alias("debug", [boot_img, bochsrc], Action(debug_bochs, "Running Bochs with debugger")))
AlwaysBuild(env.Alias("qemu", [boot_img], Action(run_qemu, "Running QEMU")))
