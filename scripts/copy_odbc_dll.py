#!/usr/bin/env python3
"""
ODBC Fast - Copy ODBC DLL
Copies odbc_engine.dll from odbc_fast package (pub cache or repo) to the consumer project.

Usage:
    python scripts/copy_odbc_dll.py
    python scripts/copy_odbc_dll.py --project-root /path/to/project

Example (from your project):
    python $LOCALAPPDATA/Pub/Cache/hosted/pub.dev/odbc_fast-1.1.0/scripts/copy_odbc_dll.py
"""

import argparse
import platform
import shutil
import sys
from pathlib import Path


class Colors:
    CYAN = "\033[96m"
    YELLOW = "\033[93m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    RESET = "\033[0m"

    @staticmethod
    def colorize(text: str, color: str) -> str:
        if sys.stdout.isatty():
            return f"{color}{text}{Colors.RESET}"
        return text


def print_header(text: str):
    print(Colors.colorize(text, Colors.CYAN))


def print_step(text: str):
    print(Colors.colorize(text, Colors.YELLOW))


def print_success(text: str):
    print(Colors.colorize(text, Colors.GREEN))


def print_error(text: str):
    print(Colors.colorize(text, Colors.RED))


def main():
    parser = argparse.ArgumentParser(
        description="Copy ODBC library from package to consumer project"
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Project root directory (default: current directory)",
    )
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    package_root = Path(__file__).parent.parent.resolve()

    system = platform.system().lower()
    if system == "windows":
        lib_name = "odbc_engine.dll"
        platform_dir = "windows-x64"
    elif system == "darwin":
        lib_name = "libodbc_engine.dylib"
        platform_dir = "macos-arm64"
    else:
        lib_name = "libodbc_engine.so"
        platform_dir = "linux-x64"

    dll_source = package_root / "artifacts" / platform_dir / lib_name

    if not dll_source.exists():
        print_error(f"ERROR: Library not found at {dll_source}")
        print_step("Run 'dart pub get' in your project first so odbc_fast is in the pub cache.")
        return 1

    targets = [
        project_root / lib_name,
    ]

    if system == "windows":
        targets.extend([
            project_root / "build" / "windows" / "x64" / "runner" / "Debug" / lib_name,
            project_root / "build" / "windows" / "x64" / "runner" / "Release" / lib_name,
        ])

    for dest in targets:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dll_source, dest)
        print_success(f"Copied to {dest}")

    print()
    print_header("Done. You can run 'flutter run -d windows' or 'dart test'.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
