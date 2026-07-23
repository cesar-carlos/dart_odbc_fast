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


def format_size(size_bytes: int) -> str:
    size_mb = size_bytes / (1024 * 1024)
    return f"{size_mb:.2f} MB"


def library_candidates(root_dir: Path) -> list[Path]:
    system = platform.system().lower()
    if system == "windows":
        name = "odbc_engine.dll"
    elif system == "linux":
        name = "libodbc_engine.so"
    else:
        return []

    return [
        root_dir / "native" / "target" / "release" / name,
        root_dir / "native" / "odbc_engine" / "target" / "release" / name,
    ]


def main():
    root_dir = Path(__file__).parent.parent
    os.chdir(root_dir)

    print_header("=== Native Assets Validation ===")
    print()

    all_passed = True

    print_step("1. Checking hook files...")
    hook_path = root_dir / "hook" / "build.dart"
    resolver_path = root_dir / "hook" / "native_library_resolver.dart"
    for path in (hook_path, resolver_path):
        if path.exists():
            print_success(f"   OK {path.relative_to(root_dir)} found")
        else:
            print_error(f"   ERROR {path.relative_to(root_dir)} not found")
            all_passed = False

    print()
    print_step("2. Analyzing hook/...")
    dart = shutil.which("dart") or shutil.which("dart.bat")
    if dart is None:
        print_error("   ERROR dart executable not found on PATH")
        all_passed = False
    else:
        result = subprocess.run(
            [dart, "analyze", str(root_dir / "hook")],
            capture_output=True,
            text=True,
            shell=False,
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
    if system not in {"windows", "linux"}:
        print_step(
            f"   WARNING Unsupported platform for native assets: {system}"
        )
        print_info("   Supported platforms: Windows and Linux (x64)")
    else:
        found = False
        for dll_path in library_candidates(root_dir):
            if dll_path.exists():
                size_str = format_size(dll_path.stat().st_size)
                print_success(
                    f"   OK Rust library found: {dll_path.relative_to(root_dir)}"
                )
                print_info(f"   Size: {size_str}")
                found = True
                break
        if not found:
            print_step("   WARNING Rust library not found")
            print_info("   Build command: cd native && cargo build --release")
            print_info(
                "   Checked: native/target/release/ and "
                "native/odbc_engine/target/release/"
            )

    print()
    print_step("4. Checking pubspec.yaml...")
    pubspec_path = root_dir / "pubspec.yaml"
    if not pubspec_path.exists():
        print_error("   ERROR pubspec.yaml not found")
        all_passed = False
    else:
        pubspec_content = pubspec_path.read_text(encoding="utf-8")

        for dep in ("code_assets:", "hooks:", "crypto:"):
            if re.search(rf"\b{re.escape(dep)}\s*", pubspec_content):
                print_success(f"   OK {dep.rstrip(':')} dependency found")
            else:
                print_error(f"   ERROR {dep.rstrip(':')} dependency not found")
                all_passed = False

    print()
    print_step("5. Checking library_loader.dart...")
    loader_path = (
        root_dir
        / "lib"
        / "infrastructure"
        / "native"
        / "bindings"
        / "library_loader.dart"
    )
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
    if not release_workflow.exists():
        print_error("   ERROR release.yml not found")
        all_passed = False
    else:
        print_success("   OK release.yml found")
        release_text = release_workflow.read_text(encoding="utf-8")
        if "sha256sum" in release_text and ".sha256" in release_text:
            print_success("   OK SHA-256 sidecar generation configured")
        else:
            print_error("   ERROR SHA-256 sidecar generation missing")
            all_passed = False

    print()
    print_header("=== Validation complete ===")
    print()

    if not all_passed:
        return 1

    print_step("Suggested next steps:")
    print_info("1. Build Rust: cd native && cargo build --release")
    print_info("2. Validate hook path: dart analyze hook")
    print_info("3. Run tests: dart test test/hook")
    print_info("4. Run release flow: see doc/RELEASE_AUTOMATION.md")

    return 0


if __name__ == "__main__":
    sys.exit(main())
