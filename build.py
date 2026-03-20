#!/usr/bin/env python3
import argparse
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser(description="Compatibility wrapper around the SCons build.")
    parser.add_argument("--build-only", action="store_true", help="Build artifacts without launching Bochs.")
    parser.add_argument("scons_args", nargs="*", help="Additional arguments passed through to scons.")
    args = parser.parse_args()

    cmd = ["scons"]
    if not args.build_only:
        cmd.append("run")
    cmd.extend(args.scons_args)

    completed = subprocess.run(cmd, cwd=ROOT)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
