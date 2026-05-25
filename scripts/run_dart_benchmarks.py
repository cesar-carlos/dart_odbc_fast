#!/usr/bin/env python3
"""
ODBC Fast - run Dart ODBC benchmarks and optional baseline compare.

Requires ODBC_TEST_DSN or ODBC_DSN in .env or the environment.

Usage:
    python scripts/run_dart_benchmarks.py --smoke
    python scripts/run_dart_benchmarks.py --heavy
    python scripts/run_dart_benchmarks.py --heavy --rows 50000
    python scripts/run_dart_benchmarks.py --smoke --compare
    python scripts/run_dart_benchmarks.py --rust-micro
    python scripts/run_dart_benchmarks.py --harness
    python scripts/run_dart_benchmarks.py --all
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
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


def print_header(text: str) -> None:
    print(Colors.colorize(text, Colors.CYAN))


def print_step(text: str) -> None:
    print(Colors.colorize(text, Colors.YELLOW))


def print_success(text: str) -> None:
    print(Colors.colorize(text, Colors.GREEN))


def print_error(text: str) -> None:
    print(Colors.colorize(text, Colors.RED))


def print_info(text: str) -> None:
    print(Colors.colorize(text, Colors.GRAY))


def load_dotenv(root: Path) -> None:
    env_path = root / ".env"
    if not env_path.is_file():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and value and key not in os.environ:
            os.environ[key] = value


def resolve_dart() -> str | None:
    return shutil.which("dart")


def run(cmd: list[str], cwd: Path) -> int:
    if cmd and cmd[0] == "dart":
        dart = resolve_dart()
        if dart is None:
            print_error("dart not found on PATH")
            return 1
        cmd = [dart, *cmd[1:]]
    return subprocess.run(cmd, cwd=cwd, check=False).returncode


def has_dsn() -> bool:
    for key in ("ODBC_TEST_DSN", "ODBC_DSN"):
        value = os.environ.get(key, "").strip()
        if value:
            return True
    return False


def env_truthy(key: str) -> bool:
    return os.environ.get(key, "").strip().lower() in ("1", "true", "yes")


def bench_out_dir(root: Path) -> Path:
    out = root / "bench_baselines"
    out.mkdir(parents=True, exist_ok=True)
    return out


def print_async_fallback_summary(json_path: Path) -> None:
    if not json_path.is_file():
        return
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print_info(f"Could not read {json_path.name}: {exc}")
        return
    if not isinstance(data, list):
        return
    print_step(f"async summary ({json_path.name}):")
    for item in data:
        if not isinstance(item, dict):
            continue
        scenario = item.get("scenario")
        if not isinstance(scenario, str):
            continue
        fb = item.get("fallbacksToBlocking", 0)
        qps = item.get("queriesPerSecond", 0)
        print_info(f"  {scenario}: fallbacks={fb}, queries/s={qps}")


def run_streaming(root: Path, query: str, tag: str) -> int:
    out = bench_out_dir(root) / f"streaming-{tag}.json"
    os.environ["ODBC_STREAM_BENCH_QUERY"] = query
    os.environ["ODBC_STREAM_BENCH_OUTPUT"] = "json"
    os.environ["ODBC_STREAM_BENCH_OUT_FILE"] = str(out)
    print_step(f"streaming -> {out.name}")
    return run(["dart", "run", "example/streaming_performance_benchmark.dart"], root)


def run_async(root: Path, query: str, tag: str) -> int:
    out = bench_out_dir(root) / f"async-{tag}.json"
    os.environ["ODBC_BENCH_QUERY"] = query
    os.environ["ODBC_BENCH_STREAM_QUERY"] = query
    os.environ["ODBC_BENCH_PREPARED_QUERY"] = query
    os.environ["ODBC_BENCH_OUTPUT"] = "json"
    os.environ["ODBC_BENCH_OUT_FILE"] = str(out)
    print_step(f"async concurrency -> {out.name}")
    code = run(["dart", "run", "example/async_concurrency_benchmark.dart"], root)
    if code == 0:
        print_async_fallback_summary(out)
    return code


def _compare_tool_argv(root: Path) -> list[str]:
    cmd: list[str] = [
        "dart",
        "run",
        "tool/compare_benchmark_baseline.dart",
    ]
    cmd += [
        "--max-regression-percent",
        os.environ.get("BENCHMARK_MAX_REGRESSION_PERCENT", "30"),
        "--max-p95-regression-percent",
        os.environ.get("BENCHMARK_MAX_P95_REGRESSION_PERCENT", "30"),
        "--max-fallbacks-delta",
        os.environ.get("BENCHMARK_MAX_FALLBACKS_DELTA", "5"),
    ]
    if os.environ.get("BENCHMARK_COMPARE_STRICT", "").strip() in ("1", "true", "yes"):
        cmd.append("--strict-scenarios")
    return cmd


def compare(root: Path, tag: str, kind: str) -> int:
    out_dir = bench_out_dir(root)
    current = out_dir / f"{kind}-{tag}.json"
    baseline = out_dir / f"{kind}-{tag}.baseline.json"
    if not current.is_file():
        print_error(f"Missing current file: {current}")
        return 1
    if not baseline.is_file():
        print_info(f"No baseline at {baseline}; copying current as baseline.")
        shutil.copy2(current, baseline)
        return 0
    print_step(f"compare {kind}-{tag}")
    cmd = _compare_tool_argv(root)
    cmd += [
        "--baseline",
        str(baseline),
        "--current",
        str(current),
    ]
    return run(cmd, root)


def run_criterion(cmd: list[str], cwd: Path) -> int:
    fail_on_regression = env_truthy("BENCHMARK_FAIL_ON_CRITERION_REGRESSION")
    saw_regression = False
    process = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    assert process.stdout is not None
    for line in process.stdout:
        if "Performance has regressed." in line:
            saw_regression = True
        print(line, end="")
    code = process.wait()
    if code != 0:
        return code
    if fail_on_regression and saw_regression:
        print_error(
            "Criterion reported a performance regression "
            "(BENCHMARK_FAIL_ON_CRITERION_REGRESSION=1)."
        )
        return 1
    return 0


def run_rust_micro(root: Path) -> int:
    native = root / "native" / "odbc_engine"
    if not shutil.which("cargo"):
        print_error("cargo not found")
        return 1
    print_step("Rust micro benches (bulk, metadata, columnar)")
    code = run_criterion(
        [
            "cargo",
            "bench",
            "--bench",
            "bulk_operations_bench",
            "--bench",
            "metadata_cache_bench",
            "--bench",
            "columnar_v1_v2_encode",
        ],
        native,
    )
    if code != 0:
        return code
    print_step("Rust columnar_v2_placeholder (--features columnar-v2)")
    code = run_criterion(
        ["cargo", "bench", "--bench", "columnar_v2_placeholder", "--features", "columnar-v2"],
        native,
    )
    if code != 0:
        return code
    if os.environ.get("BENCHMARK_SAVE_RUST_MICRO_LOG", "").strip() in ("1", "true", "yes"):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        log_path = bench_out_dir(root) / f"rust-micro-{stamp}.txt"
        print_step(f"Saving Rust bench log to {log_path.name}")
        with log_path.open("w", encoding="utf-8") as log_file:
            subprocess.run(
                [
                    "cargo",
                    "bench",
                    "--bench",
                    "bulk_operations_bench",
                    "--bench",
                    "metadata_cache_bench",
                ],
                cwd=native,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                check=False,
            )
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description="Run ODBC Fast benchmarks")
    parser.add_argument(
        "--all",
        action="store_true",
        help="Run protocol, rust-micro, harness, smoke, heavy, and compare",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="SELECT 1 async + streaming benchmarks",
    )
    parser.add_argument(
        "--heavy",
        action="store_true",
        help="SELECT TOP N * FROM Produto (default N=5000)",
    )
    parser.add_argument(
        "--rows",
        type=int,
        default=None,
        metavar="N",
        help="Row limit for --heavy (default 5000 or ODBC_BENCH_ROWS)",
    )
    parser.add_argument(
        "--table",
        default=None,
        help="Table name for --heavy (default Produto or ODBC_BENCH_TABLE)",
    )
    parser.add_argument(
        "--compare",
        action="store_true",
        help="Compare JSON output to *.baseline.json (creates baseline if missing)",
    )
    parser.add_argument(
        "--rust-micro",
        action="store_true",
        help="Run Rust Criterion micro benches (no DSN)",
    )
    parser.add_argument(
        "--protocol",
        action="store_true",
        help="Run dart test test/performance/ (no DSN)",
    )
    parser.add_argument(
        "--harness",
        action="store_true",
        help="Run benchmarks/m1_baseline.dart and m2_performance.dart (DSN for m2)",
    )
    args = parser.parse_args()

    if args.all:
        args.protocol = True
        args.rust_micro = True
        args.harness = True
        args.smoke = True
        args.heavy = True
        args.compare = True

    rows_default = 5000
    if os.environ.get("ODBC_BENCH_ROWS", "").strip().isdigit():
        rows_default = int(os.environ["ODBC_BENCH_ROWS"])
    if args.rows is None:
        args.rows = rows_default

    table_default = os.environ.get("ODBC_BENCH_TABLE", "Produto").strip() or "Produto"
    if args.table is None:
        args.table = table_default

    if not any(
        (
            args.smoke,
            args.heavy,
            args.rust_micro,
            args.protocol,
            args.harness,
        )
    ):
        args.smoke = True

    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    load_dotenv(root)

    print_header("=== ODBC Fast benchmarks ===")
    print()

    if args.rust_micro:
        code = run_rust_micro(root)
        if code != 0:
            return code
        print()

    if args.protocol:
        print_step("Dart protocol/telemetry performance tests")
        code = run(["dart", "test", "test/performance/", "--concurrency=1"], root)
        if code != 0:
            return code
        print()

    needs_dsn = args.smoke or args.heavy or args.harness
    if resolve_dart() is None:
        print_error("dart not found on PATH")
        return 1

    if needs_dsn and not has_dsn():
        print_error("ODBC_TEST_DSN or ODBC_DSN required for Dart ODBC benchmarks")
        return 1

    exit_code = 0
    if args.harness:
        print_step("benchmark_harness m1_baseline")
        if run(["dart", "run", "benchmarks/m1_baseline.dart"], root) != 0:
            exit_code = 1
        print_step("benchmark_harness m2_performance")
        if run(["dart", "run", "benchmarks/m2_performance.dart"], root) != 0:
            exit_code = 1

    if args.smoke:
        if run_streaming(root, "SELECT 1 AS value", "smoke") != 0:
            exit_code = 1
        if run_async(root, "SELECT 1 AS value", "smoke") != 0:
            exit_code = 1
        if args.compare and exit_code == 0:
            if compare(root, "smoke", "streaming") != 0:
                exit_code = 1
            if compare(root, "smoke", "async") != 0:
                exit_code = 1

    if args.heavy:
        query = f"SELECT TOP {args.rows} * FROM {args.table}"
        tag = f"{args.table.lower()}-{args.rows}"
        if run_streaming(root, query, tag) != 0:
            exit_code = 1
        if run_async(root, query, tag) != 0:
            exit_code = 1
        if args.compare and exit_code == 0:
            if compare(root, tag, "streaming") != 0:
                exit_code = 1
            if compare(root, tag, "async") != 0:
                exit_code = 1

    print()
    if exit_code == 0:
        print_success("Benchmarks finished.")
        print_info(f"JSON under: {bench_out_dir(root)}")
    else:
        print_error("One or more benchmark steps failed.")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
