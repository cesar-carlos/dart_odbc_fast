#!/usr/bin/env python3
"""
ODBC Fast - Native Assets Validation
Validates whether hook/build.dart and related setup are correctly configured.

Usage:
    python scripts/validate_native_assets.py
"""

import os
import platform
import re
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


def format_size(size_bytes: int) -> str:
    size_mb = size_bytes / (1024 * 1024)
    return f"{size_mb:.2f} MB"


def main():
    root_dir = Path(__file__).parent.parent
    os.chdir(root_dir)

    print_header("=== Native Assets Validation ===")
    print()

    all_passed = True

    print_step("1. Checking hook/build.dart...")
    hook_path = root_dir / "hook" / "build.dart"
    if hook_path.exists():
        print_success("   OK hook/build.dart found")
    else:
        print_error("   ERROR hook/build.dart not found")
        all_passed = False

    print()
    print_step("2. Analyzing hook/build.dart...")
    result = subprocess.run(
        ["dart", "analyze", str(hook_path)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print_success("   OK Analyze completed with no issues")
    else:
        print_error("   ERROR Issues found:")
        print(result.stdout)
        print(result.stderr)
        all_passed = False

    print()
    print_step("3. Checking Rust library...")
    system = platform.system().lower()
    if system == "windows":
        dll_path = root_dir / "native" / "odbc_engine" / "target" / "release" / "odbc_engine.dll"
    elif system == "darwin":
        dll_path = root_dir / "native" / "odbc_engine" / "target" / "release" / "libodbc_engine.dylib"
    else:
        dll_path = root_dir / "native" / "odbc_engine" / "target" / "release" / "libodbc_engine.so"

    if dll_path.exists():
        size_str = format_size(dll_path.stat().st_size)
        print_success(f"   OK Rust library found: {dll_path.relative_to(root_dir)}")
        print_info(f"   Size: {size_str}")
    else:
        print_step("   WARNING Rust library not found")
        print_info("   Build command: cd native/odbc_engine && cargo build --release")

    print()
    print_step("4. Checking pubspec.yaml...")
    pubspec_path = root_dir / "pubspec.yaml"
    if not pubspec_path.exists():
        print_error("   ERROR pubspec.yaml not found")
        all_passed = False
    else:
        pubspec_content = pubspec_path.read_text(encoding="utf-8")

        if re.search(r"\bcode_assets:\s*", pubspec_content):
            print_success("   OK code_assets dependency found")
        else:
            print_error("   ERROR code_assets dependency not found")
            all_passed = False

        if re.search(r"\bhooks:\s*", pubspec_content):
            print_success("   OK hooks dependency found")
        else:
            print_error("   ERROR hooks dependency not found")
            all_passed = False

    print()
    print_step("5. Checking library_loader.dart...")
    loader_path = root_dir / "lib" / "infrastructure" / "native" / "bindings" / "library_loader.dart"
    if not loader_path.exists():
        print_error("   ERROR library_loader.dart not found")
        all_passed = False
    else:
        loader_content = loader_path.read_text(encoding="utf-8")
        if "package:odbc_fast" in loader_content or "Native Assets" in loader_content:
            print_success("   OK Native Assets support detected")
        else:
            print_error("   ERROR Native Assets support not detected")
            all_passed = False

    print()
    print_step("6. Checking release workflow...")
    release_workflow = root_dir / ".github" / "workflows" / "release.yml"
    if release_workflow.exists():
        print_success("   OK release.yml found")
    else:
        print_error("   ERROR release.yml not found")
        all_passed = False

    print()
    print_header("=== Validation complete ===")
    print()

    if not all_passed:
        return 1

    print_step("Suggested next steps:")
    print_info("1. Build Rust: cd native/odbc_engine && cargo build --release")
    print_info("2. Validate hook path: dart analyze hook/build.dart")
    print_info("3. Run tests: dart test")
    print_info("4. Run release flow: see doc/RELEASE_AUTOMATION.md")

    return 0


if __name__ == "__main__":
    sys.exit(main())
