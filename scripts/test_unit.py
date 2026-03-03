#!/usr/bin/env python3
"""
ODBC Fast - Run Unit Tests
Runs unit tests that do not require ODBC native bindings.

Usage:
    python scripts/test_unit.py
"""

import os
import subprocess
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


def run_command(cmd: list, cwd: Path = None) -> int:
    result = subprocess.run(cmd, cwd=cwd)
    return result.returncode


def main():
    root_dir = Path(__file__).parent.parent
    os.chdir(root_dir)

    print_header("=== ODBC Fast - Unit Tests ===")
    print()
    print_step("Running: dart test test/infrastructure/native/protocol")

    exit_code = run_command(
        ["dart", "test", "test/infrastructure/native/protocol"],
        cwd=root_dir
    )

    if exit_code == 0:
        print()
        print_success("All unit tests passed.")
    else:
        print()
        print_error("Some tests failed.")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
