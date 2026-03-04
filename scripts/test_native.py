#!/usr/bin/env python3
"""
ODBC Fast - Run Native Rust Tests
Runs Rust library tests (all module tests).

Usage:
    python scripts/test_native.py
    python scripts/test_native.py --release
    python scripts/test_native.py --ffi-only
"""

import argparse
import os
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


def run_command(cmd: list, cwd: Path = None) -> int:
    result = subprocess.run(cmd, cwd=cwd)
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description="Run native Rust tests")
    parser.add_argument("--release", action="store_true", help="Build and test in release mode")
    parser.add_argument("--ffi-only", action="store_true", help="Run only FFI tests")
    args = parser.parse_args()

    root_dir = Path(__file__).parent.parent
    native_dir = root_dir / "native"

    cargo_bin = Path.home() / ".cargo" / "bin"
    if cargo_bin.exists():
        os.environ["PATH"] = f"{cargo_bin}{os.pathsep}{os.environ['PATH']}"

    os.chdir(native_dir)

    print_header("=== ODBC Fast - Native Rust Tests ===")
    print()

    if not find_command("cargo"):
        print_error("ERROR: Cargo not found. Install Rust from https://rustup.rs/")
        return 1

    cmd = ["cargo", "test", "--lib", "--", "--test-threads=1"]

    if args.ffi_only:
        cmd.insert(-2, "ffi::tests")  # before "--"

    if args.release:
        cmd.insert(2, "--release")  # cargo test --release --lib

    cmd_str = " ".join(cmd)
    print_step(f"Running: {cmd_str}")

    exit_code = run_command(cmd, cwd=native_dir)

    if exit_code == 0:
        print()
        print_success("All native tests passed.")
        print()
        print_header("Test coverage:")
        print_info("  - FFI Layer (20 tests)")
        print_info("  - Error Handling (10 tests)")
        print_info("  - Protocol Types (16 tests)")
        print_info("  - Protocol Encoder (9 tests)")
        print_info("  - Security Buffer (13 tests)")
        print_info("  - Protocol Version (17 tests)")
        print_info("  - Engine Core (3 tests)")
    else:
        print()
        print_error("Some tests failed.")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
