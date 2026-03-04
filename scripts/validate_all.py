#!/usr/bin/env python3
"""
ODBC Fast - Full Validation Script
Validates Rust + Dart + artifacts.

Usage:
    python scripts/validate_all.py
    python scripts/validate_all.py --artifacts-only
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


def run_command(cmd: list, cwd: Path = None, capture: bool = False) -> tuple[int, str]:
    if capture:
        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr
    result = subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode, ""


def format_size(size_bytes: int) -> str:
    size_mb = size_bytes / (1024 * 1024)
    return f"{size_mb:.2f} MB"


def get_library_path(base_path: Path) -> Path | None:
    system = platform.system().lower()
    if system == "windows":
        lib_name = "odbc_engine.dll"
    elif system == "darwin":
        lib_name = "libodbc_engine.dylib"
    else:
        lib_name = "libodbc_engine.so"

    candidates = [
        base_path / "target" / "release" / lib_name,
        base_path / "odbc_engine" / "target" / "release" / lib_name,
    ]

    for path in candidates:
        if path.exists():
            return path
    return None


def main():
    parser = argparse.ArgumentParser(description="Full validation of Rust + Dart + artifacts")
    parser.add_argument(
        "--artifacts-only",
        action="store_true",
        help="Quick artifact check only (skip Rust/Dart validation)",
    )
    args = parser.parse_args()

    root_dir = Path(__file__).parent.parent

    cargo_bin = Path.home() / ".cargo" / "bin"
    if cargo_bin.exists():
        os.environ["PATH"] = f"{cargo_bin}{os.pathsep}{os.environ['PATH']}"

    os.chdir(root_dir)

    print_header("=== ODBC Fast Validation ===")
    print()

    all_passed = True
    step = 1
    total_steps = 1 if args.artifacts_only else 7

    if not args.artifacts_only:
        if not find_command("cargo"):
            print_error("ERROR: cargo not found in PATH.")
            return 1

        if not find_command("dart"):
            print_error("ERROR: dart not found in PATH.")
            return 1

        print_step(f"[{step}/{total_steps}] Rust: cargo fmt --all -- --check")
        native_dir = root_dir / "native"
        exit_code, _ = run_command(["cargo", "fmt", "--all", "--", "--check"], cwd=native_dir)
        if exit_code == 0:
            print_success("  OK")
        else:
            print_error("  FAILED")
            all_passed = False
        step += 1

        print_step(f"[{step}/{total_steps}] Rust: cargo check --all-targets")
        odbc_engine_dir = root_dir / "native" / "odbc_engine"
        exit_code, _ = run_command(["cargo", "check", "--all-targets"], cwd=odbc_engine_dir)
        if exit_code == 0:
            print_success("  OK")
        else:
            print_error("  FAILED")
            all_passed = False
        step += 1

        print_step(f"[{step}/{total_steps}] Rust: cargo test --lib")
        exit_code, _ = run_command(
            ["cargo", "test", "--lib", "--", "--test-threads=1"],
            cwd=odbc_engine_dir,
        )
        if exit_code == 0:
            print_success("  OK")
        else:
            print_error("  FAILED")
            all_passed = False
        step += 1

        print_step(f"[{step}/{total_steps}] Rust: cargo clippy --all-targets -- -D warnings")
        exit_code, _ = run_command(
            ["cargo", "clippy", "--all-targets", "--", "-D", "warnings"],
            cwd=odbc_engine_dir,
        )
        if exit_code == 0:
            print_success("  OK")
        else:
            print_error("  FAILED")
            all_passed = False
        step += 1

        print_step(f"[{step}/{total_steps}] Dart: dart analyze --fatal-infos")
        exit_code, _ = run_command(["dart", "analyze", "--fatal-infos"], cwd=root_dir)
        if exit_code == 0:
            print_success("  OK")
        else:
            print_error("  FAILED")
            all_passed = False
        step += 1

        print_step(f"[{step}/{total_steps}] Dart: unit-only test scope")
        exit_code, _ = run_command(
            [
                "dart",
                "test",
                "test/application",
                "test/domain",
                "test/infrastructure",
                "test/helpers/database_detection_test.dart",
            ],
            cwd=root_dir,
        )
        if exit_code == 0:
            print_success("  OK")
        else:
            print_error("  FAILED")
            all_passed = False
        step += 1

    print_step(f"[{step}/{total_steps}] Build artifacts")

    native_dir = root_dir / "native"
    dll_path = get_library_path(native_dir)
    header_path = root_dir / "native" / "odbc_engine" / "include" / "odbc_engine.h"
    bindings_path = root_dir / "lib" / "infrastructure" / "native" / "bindings" / "odbc_bindings.dart"

    if dll_path:
        size_str = format_size(dll_path.stat().st_size)
        print_success(f"  OK DLL: {dll_path.relative_to(root_dir)} ({size_str})")
    else:
        print_error("  FAILED DLL missing (checked native/target and native/odbc_engine/target)")
        all_passed = False

    if header_path.exists():
        print_success(f"  OK Header: {header_path.relative_to(root_dir)}")
    else:
        print_error(f"  FAILED Header missing: {header_path.relative_to(root_dir)}")
        all_passed = False

    if bindings_path.exists():
        print_success(f"  OK Bindings: {bindings_path.relative_to(root_dir)}")
    else:
        print_error(f"  FAILED Bindings missing: {bindings_path.relative_to(root_dir)}")
        all_passed = False

    print()
    print_header("=== Summary ===")
    if all_passed:
        print_success("ALL CHECKS PASSED")
        return 0

    print_error("SOME CHECKS FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
