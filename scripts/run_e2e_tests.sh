#!/usr/bin/env bash
# Run all Rust E2E integration tests (native/odbc_engine/tests/e2e_*.rs).
#
# Prerequisites: cargo, ODBC driver, database matching ODBC_TEST_DSN in .env.
# Loads repo-root .env. Maps RUN_SKIPPED_TESTS -> ENABLE_SLOW_E2E_TESTS when unset.
#
# Usage:
#   ./scripts/run_e2e_tests.sh           # full suite incl. slow stress tests
#   ./scripts/run_e2e_tests.sh --quick   # live E2E only (slow stress self-skip)
#   ./scripts/run_e2e_tests.sh --release

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$ROOT/native/odbc_engine"
ENV_FILE="$ROOT/.env"
QUICK=0
RELEASE=0

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --release) RELEASE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/\r$//')
  set +a
fi

if [[ -z "${ENABLE_E2E_TESTS:-}" ]]; then
  echo "ENABLE_E2E_TESTS is not set. Set ENABLE_E2E_TESTS=1 in .env or the environment." >&2
  exit 1
fi

if [[ "$QUICK" -eq 1 ]]; then
  export ENABLE_SLOW_E2E_TESTS=0
elif [[ -z "${ENABLE_SLOW_E2E_TESTS:-}" && -n "${RUN_SKIPPED_TESTS:-}" ]]; then
  export ENABLE_SLOW_E2E_TESTS="$RUN_SKIPPED_TESTS"
fi

if [[ -z "${ODBC_TEST_DSN:-}" ]]; then
  echo "WARNING: ODBC_TEST_DSN not set; live tests will self-skip." >&2
fi

E2E_TESTS=(
  e2e_async_api_test e2e_basic_connection_test e2e_batch_executor_test
  e2e_bcp_fallback_test e2e_bcp_native_numeric_test e2e_bulk_compare_benchmark_test
  e2e_bulk_operations_test e2e_bulk_transaction_stress_test e2e_catalog_test
  e2e_driver_capabilities_test e2e_execution_engine_test e2e_ffi_refactor_regression_test
  e2e_multi_db_basic_test e2e_oracle_ref_cursor_test e2e_pool_test
  e2e_savepoint_test e2e_sqlserver_test e2e_statement_reuse_test
  e2e_streaming_test e2e_structured_error_test e2e_test e2e_timeout_test
  e2e_transaction_access_mode_test e2e_transaction_lock_timeout_test e2e_xa_transaction_test
)

CARGO_ARGS=(test --features test-helpers)
if [[ "$RELEASE" -eq 1 ]]; then
  CARGO_ARGS+=(--release)
fi
for t in "${E2E_TESTS[@]}"; do
  CARGO_ARGS+=(--test "$t")
done
CARGO_ARGS+=(-- --test-threads=1 --include-ignored)

cd "$ENGINE_DIR"
exec cargo "${CARGO_ARGS[@]}"
