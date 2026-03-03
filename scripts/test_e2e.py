#!/usr/bin/env python3
"""
ODBC Fast - Run End-to-End Native Tests
Runs end-to-end Rust tests that require ODBC drivers.

Usage:
    python scripts/test_e2e.py

Requires:
    ODBC_TEST_DSN environment variable or .env file
    ENABLE_E2E_TESTS=true environment variable or .env file
"""

import os
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


def find_command(name: str) -> bool:
    return shutil.which(name) is not None


def run_command(cmd: list, cwd: Path = None) -> int:
    result = subprocess.run(cmd, cwd=cwd)
    return result.returncode


def parse_env_bool(value: str) -> bool | None:
    if not value or not value.strip():
        return None
    v = value.strip().lower()
    if v in ("1", "true", "yes", "y"):
        return True
    if v in ("0", "false", "no", "n"):
        return False
    return None


def load_env_file(root_dir: Path):
    env_file = root_dir / ".env"
    if not env_file.exists():
        return

    content = env_file.read_text(encoding="utf-8")

    if not os.environ.get("ODBC_TEST_DSN"):
        match = re.search(r"^\s*ODBC_TEST_DSN=(.+)$", content, re.MULTILINE)
        if match:
            os.environ["ODBC_TEST_DSN"] = match.group(1).strip()
            print_info("Loaded ODBC_TEST_DSN from .env file")

    if not os.environ.get("ENABLE_E2E_TESTS"):
        match = re.search(r"^\s*ENABLE_E2E_TESTS=(.+)$", content, re.MULTILINE)
        if match:
            os.environ["ENABLE_E2E_TESTS"] = match.group(1).strip()
            print_info("Loaded ENABLE_E2E_TESTS from .env file")


def main():
    root_dir = Path(__file__).parent.parent
    native_dir = root_dir / "native"

    cargo_bin = Path.home() / ".cargo" / "bin"
    if cargo_bin.exists():
        os.environ["PATH"] = f"{cargo_bin}{os.pathsep}{os.environ['PATH']}"

    load_env_file(root_dir)

    enable_e2e = parse_env_bool(os.environ.get("ENABLE_E2E_TESTS", ""))

    if enable_e2e is False:
        print_step("ENABLE_E2E_TESTS is disabled. Skipping end-to-end native tests.")
        return 0

    if enable_e2e is not True:
        print_step("ENABLE_E2E_TESTS is not enabled. Skipping end-to-end native tests.")
        return 0

    os.chdir(native_dir)

    print_header("=== ODBC Fast - End-to-End Native Tests ===")
    print()

    odbc_test_dsn = os.environ.get("ODBC_TEST_DSN", "")
    if not odbc_test_dsn:
        print_step("WARNING: ODBC_TEST_DSN not set. Tests will be ignored.")
        print_step("Set ODBC_TEST_DSN environment variable or configure in .env file")
        print()
    else:
        dsn_preview = odbc_test_dsn[:50]
        if len(odbc_test_dsn) > 50:
            dsn_preview += "..."
        print_info(f"Using ODBC_TEST_DSN: {dsn_preview}")
        print()

    if not find_command("cargo"):
        print_error("ERROR: Cargo not found. Install Rust from https://rustup.rs/")
        return 1

    print_step("Running: cargo test --test e2e_test -- --ignored")
    exit_code = run_command(["cargo", "test", "--test", "e2e_test", "--", "--ignored"], cwd=native_dir)

    if exit_code == 0:
        print()
        print_success("All end-to-end tests passed.")
    else:
        print()
        print_error("Some tests failed.")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
