#!/usr/bin/env python3
"""
ODBC Fast - Rust Code Coverage
Runs cargo-tarpaulin to generate Rust code coverage (HTML + LCOV).

Usage:
    python scripts/run_coverage.py
    python scripts/run_coverage.py --lib-only
    python scripts/run_coverage.py --install-tools

By default measures `odbc_engine` with `--lib` and `--tests` (matches doc/TESTING.md
and reports the same scope developers use locally). Use `--lib-only` for library
targets only (faster, lower percentage).

Requires:
    cargo-tarpaulin (install manually or use --install-tools)

Output:
    native/coverage/tarpaulin-report.html
    native/coverage/lcov.info
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


def check_tarpaulin_installed() -> bool:
    result = subprocess.run(
        ["cargo", "tarpaulin", "--version"],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def install_tarpaulin():
    print_step("Installing cargo-tarpaulin...")
    result = subprocess.run(["cargo", "install", "--locked", "cargo-tarpaulin"])
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(
        description="Generate Rust code coverage using cargo-tarpaulin"
    )
    parser.add_argument(
        "--install-tools",
        action="store_true",
        help="Install cargo-tarpaulin if not found",
    )
    parser.add_argument(
        "--lib-only",
        action="store_true",
        help="Measure only --lib (omit integration tests under tests/)",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    engine_dir = script_dir.parent
    workspace_root = engine_dir.parent
    coverage_dir = workspace_root / "coverage"

    scope = "lib + integration tests" if not args.lib_only else "lib only"
    print_header("=== Rust Code Coverage (cargo tarpaulin) ===")
    print_info(f"Workspace: {workspace_root}")
    print_info(f"Package:   odbc_engine")
    print_info(f"Scope:     {scope}")
    print_info(f"Output:    {coverage_dir}")
    print()

    if not find_command("cargo"):
        print_error("ERROR: cargo not found. Install Rust from https://rustup.rs")
        return 1

    if not check_tarpaulin_installed():
        if not args.install_tools:
            print_error("ERROR: cargo-tarpaulin not found.")
            print_step("Install with: cargo install --locked cargo-tarpaulin")
            print_step("Or run with --install-tools flag")
            return 1

        if not install_tarpaulin():
            print_error("ERROR: Failed to install cargo-tarpaulin")
            return 1

    os.chdir(workspace_root)
    coverage_dir.mkdir(parents=True, exist_ok=True)

    tarpaulin_args = [
        "cargo",
        "tarpaulin",
        "-p",
        "odbc_engine",
        "--lib",
        "--out",
        "Html",
        "--out",
        "Lcov",
        "--output-dir",
        "coverage",
        "--timeout",
        "600",
    ]
    if not args.lib_only:
        tarpaulin_args.extend(["--tests", "--", "--test-threads=1"])
    result = subprocess.run(tarpaulin_args)

    if result.returncode == 0:
        html_path = coverage_dir / "tarpaulin-report.html"
        print()
        print_success(f"Coverage report: {html_path}")

        file_uri = html_path.as_uri()
        print_info(f"Open in browser: {file_uri}")
        return 0

    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
