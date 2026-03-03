#!/usr/bin/env python3
"""
ODBC Fast - Build Script (Cross-platform)
Builds the Rust library and generates FFI bindings.

Usage:
    python scripts/build.py
    python scripts/build.py --skip-rust
    python scripts/build.py --skip-bindings
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


class Colors:
    CYAN = "\033[96m"
    YELLOW = "\033[93m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    GRAY = "\033[90m"
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


def print_info(text: str):
    print(Colors.colorize(text, Colors.GRAY))


def find_command(name: str) -> bool:
    return shutil.which(name) is not None


def run_command(cmd: list, cwd: Path = None, check: bool = True) -> int:
    result = subprocess.run(cmd, cwd=cwd)
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, cmd)
    return result.returncode


def get_library_path(base_path: Path) -> tuple[Path, str]:
    system = platform.system().lower()
    if system == "windows":
        return base_path / "odbc_engine.dll", "DLL"
    elif system == "darwin":
        return base_path / "libodbc_engine.dylib", "dylib"
    else:
        return base_path / "libodbc_engine.so", "shared library"


def format_size(size_bytes: int) -> str:
    size_mb = size_bytes / (1024 * 1024)
    return f"{size_mb:.2f} MB"


def main():
    parser = argparse.ArgumentParser(
        description="Build ODBC Fast Rust library and generate FFI bindings"
    )
    parser.add_argument(
        "--skip-rust", action="store_true", help="Skip Rust library build"
    )
    parser.add_argument(
        "--skip-bindings", action="store_true", help="Skip Dart bindings generation"
    )
    args = parser.parse_args()

    root_dir = Path(__file__).parent.parent
    os.chdir(root_dir)

    print_header("=== ODBC Fast Build Script ===")
    print()

    try:
        if not args.skip_rust:
            print_step("[1/3] Building Rust library...")

            if not find_command("cargo"):
                print_error("ERROR: Rust/Cargo not found in PATH")
                print_step("Please install Rust from https://rustup.rs/")
                print_step("Or add Rust to your PATH")
                return 1

            rust_dir = root_dir / "native" / "odbc_engine"
            print_info("  Running: cargo build --release")

            try:
                run_command(["cargo", "build", "--release"], cwd=rust_dir)
                print_success("  ✓ Rust library built successfully")

                header_path = rust_dir / "include" / "odbc_engine.h"
                if header_path.exists():
                    print_success(f"  ✓ C header generated: {header_path.relative_to(root_dir)}")
                else:
                    print_step("  WARNING: Header not found, but build succeeded")
            except subprocess.CalledProcessError:
                print_error("ERROR: Rust build failed")
                return 1
        else:
            print_info("[1/3] Skipping Rust build (--skip-rust)")

        if not args.skip_bindings:
            print()
            print_step("[2/3] Generating Dart FFI bindings...")

            if not find_command("dart"):
                print_error("ERROR: Dart SDK not found in PATH")
                print_step("Please install Dart SDK from https://dart.dev/get-dart")
                return 1

            header_path = root_dir / "native" / "odbc_engine" / "include" / "odbc_engine.h"
            if not header_path.exists():
                print_error("ERROR: C header not found. Run Rust build first.")
                return 1

            print_info("  Running: dart run ffigen")

            try:
                run_command(["dart", "run", "ffigen"], cwd=root_dir)
                bindings_path = root_dir / "lib" / "infrastructure" / "native" / "bindings" / "odbc_bindings.dart"
                print_success(f"  ✓ Dart bindings generated: {bindings_path.relative_to(root_dir)}")
            except subprocess.CalledProcessError:
                print_error("ERROR: FFI bindings generation failed")
                return 1
        else:
            print_info("[2/3] Skipping bindings generation (--skip-bindings)")

        print()
        print_step("[3/3] Verifying build...")

        lib_base = root_dir / "native" / "odbc_engine" / "target" / "release"
        lib_path, lib_type = get_library_path(lib_base)

        if lib_path.exists():
            size_str = format_size(lib_path.stat().st_size)
            print_success(f"  ✓ Library found: {lib_path.relative_to(root_dir)} ({size_str})")
        else:
            print_step(f"  WARNING: Library not found at {lib_path.relative_to(root_dir)}")

        bindings_path = root_dir / "lib" / "infrastructure" / "native" / "bindings" / "odbc_bindings.dart"
        if bindings_path.exists():
            print_success(f"  ✓ Bindings found: {bindings_path.relative_to(root_dir)}")
        else:
            print_step(f"  WARNING: Bindings not found")

        print()
        print_header("=== Build Complete ===")
        print()
        print_step("Next steps:")
        print_info("  1. Run tests: dart test")
        print_info("  2. Run example: dart run example/main.dart")
        print()

        return 0

    except Exception as e:
        print_error(f"ERROR: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
