#!/usr/bin/env python3
"""
ODBC Fast - Create Release Tag
Helper script to create release tag and trigger release workflow.

Usage:
    python scripts/create_release.py 1.1.0
    python scripts/create_release.py v1.1.0
    python scripts/create_release.py 1.1.0 --no-push
"""

import argparse
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


def fail(message: str):
    print_error(f"ERROR: {message}")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Create release tag and trigger release workflow")
    parser.add_argument("version", help="Version number (e.g., 1.1.0 or v1.1.0)")
    parser.add_argument("--no-push", action="store_true", help="Create tag locally without pushing")
    args = parser.parse_args()

    root_dir = Path(__file__).parent.parent

    tag = args.version if args.version.startswith("v") else f"v{args.version}"

    if not re.match(r"^v\d+\.\d+\.\d+([-.][\w.]+)?$", tag):
        fail(f"Invalid tag: '{tag}'. Use format vX.Y.Z (or suffixes -rc.N/-beta.N/-dev.N).")

    version = tag[1:]

    pubspec_path = root_dir / "pubspec.yaml"
    if not pubspec_path.exists():
        fail("Run this script from repository root (pubspec.yaml not found).")

    pubspec_content = pubspec_path.read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(.+)$", pubspec_content, re.MULTILINE)
    if not match:
        fail("'version:' field not found in pubspec.yaml.")

    pubspec_version = match.group(1).strip()

    if pubspec_version != version:
        fail(f"Version mismatch: pubspec.yaml={pubspec_version}, tag={tag}.")

    changelog_path = root_dir / "CHANGELOG.md"
    if not changelog_path.exists():
        fail("CHANGELOG.md not found.")

    changelog_content = changelog_path.read_text(encoding="utf-8")
    pattern = rf"^## \[{re.escape(version)}\]"
    if not re.search(pattern, changelog_content, re.MULTILINE):
        fail(f"CHANGELOG.md missing section [{version}].")

    if not shutil.which("git"):
        fail("Git not found in PATH.")

    result = subprocess.run(
        ["git", "tag", "--list", tag],
        cwd=root_dir,
        capture_output=True,
        text=True,
    )
    existing_tag = result.stdout.strip()
    if existing_tag == tag:
        fail(f"Tag '{tag}' already exists locally.")

    print_header(f"Creating annotated tag: {tag}")
    result = subprocess.run(
        ["git", "tag", "-a", tag, "-m", f"Release {tag}"],
        cwd=root_dir,
    )
    if result.returncode != 0:
        fail("Failed to create tag.")

    if args.no_push:
        print()
        print_step("Tag created locally (no push).")
        print_step("To trigger release:")
        print_info(f"  git push origin {tag}")
        return 0

    print_header(f"Pushing tag to origin: {tag}")
    result = subprocess.run(
        ["git", "push", "origin", tag],
        cwd=root_dir,
    )
    if result.returncode != 0:
        fail("Failed to push tag to origin.")

    print()
    print_success(f"Tag pushed successfully: {tag}")
    print_success("Workflow '.github/workflows/release.yml' should start automatically.")
    print_info("Track progress at: https://github.com/cesar-carlos/dart_odbc_fast/actions")

    return 0


if __name__ == "__main__":
    sys.exit(main())
