#!/usr/bin/env python3
"""
ODBC Fast - Run All Tests
Builds Rust library and runs all Dart tests.

Usage:
    python scripts/test_all.py
    python scripts/test_all.py --skip-rust
    python scripts/test_all.py --concurrency 4
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
    parser = argparse.ArgumentParser(description="Build Rust and run all Dart tests")
    parser.add_argument(
        "--skip-rust", action="store_true", help="Skip Rust library build"
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=1,
        help="Test concurrency level (default: 1)",
        metavar="N",
    )
    args = parser.parse_args()

    if args.concurrency < 1 or args.concurrency > 64:
        print_error("ERROR: Concurrency must be between 1 and 64")
        return 1

    root_dir = Path(__file__).parent.parent
    os.chdir(root_dir)

    cargo_bin = Path.home() / ".cargo" / "bin"
    if cargo_bin.exists():
        os.environ["PATH"] = f"{cargo_bin}{os.pathsep}{os.environ['PATH']}"

    print_header("=== ODBC Fast - All Tests ===")
    print()

    if not args.skip_rust:
        print_step("[1/2] Building Rust library...")

        if not find_command("cargo"):
            print_error("ERROR: Cargo not found. Install Rust from https://rustup.rs/")
            return 1

        native_dir = root_dir / "native"
        exit_code = run_command(["cargo", "build", "--release"], cwd=native_dir)

        if exit_code != 0:
            print_error("ERROR: Rust build failed")
            return 1

        print_success("  OK Rust built")
        print()
    else:
        print_info("[1/2] Skipping Rust build (--skip-rust)")
        print()

    print_step("[2/2] Running dart test...")
    exit_code = run_command(["dart", "test", f"--concurrency={args.concurrency}"], cwd=root_dir)

    if exit_code == 0:
        print()
        print_success("All tests passed.")
    else:
        print()
        print_step("Some tests failed. Unit-only: python scripts/test_unit.py")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
