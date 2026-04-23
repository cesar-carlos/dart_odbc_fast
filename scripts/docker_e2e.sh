#!/usr/bin/env bash
# Run the engine's E2E suite against the dockerised DB stack from inside
# the Linux `test-runner` container. POSIX equivalent of `docker_e2e.ps1`.

set -euo pipefail

ENGINE="postgres"
TEST_FILTER=""
FEATURES="ffi-tests"
NO_BUILD=0
SMOKE_ONLY=0
QUICK=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  scripts/docker_e2e.sh                       # PostgreSQL (default)
  scripts/docker_e2e.sh --engine mysql
  scripts/docker_e2e.sh --engine mariadb
  scripts/docker_e2e.sh --engine mssql
  scripts/docker_e2e.sh --filter xa_pg_      # cargo test substring filter
  scripts/docker_e2e.sh --no-build            # skip docker build
  scripts/docker_e2e.sh --smoke               # cargo test --lib transaction only
  scripts/docker_e2e.sh --quick               # no --include-ignored (skip long #[ignore] stress)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --filter) TEST_FILTER="$2"; shift 2 ;;
        --features) FEATURES="$2"; shift 2 ;;
        --no-build) NO_BUILD=1; shift ;;
        --smoke) SMOKE_ONLY=1; shift ;;
        --quick) QUICK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

case "$ENGINE" in
    postgres) DSN='Driver={PostgreSQL Unicode};Server=postgres;Port=5432;Database=odbc_test;UID=postgres;PWD=postgres;' ;;
    mysql)    DSN='Driver={MySQL ODBC 8.0 Unicode Driver};Server=mysql;Port=3306;Database=odbc_test;UID=odbc;PWD=odbc;' ;;
    mariadb)  DSN='Driver={MariaDB ODBC 3.1 Driver};Server=mariadb;Port=3306;Database=odbc_test;UID=odbc;PWD=odbc;' ;;
    mssql)    DSN='Driver={ODBC Driver 18 for SQL Server};Server=mssql,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;' ;;
    db2)      DSN='Driver={IBM DB2 ODBC DRIVER};HostName=db2;Port=50000;Database=TESTDB;Protocol=TCPIP;UID=db2inst1;PWD=OdbcTest123;' ;;
    oracle)   DSN='Driver={Oracle Instant Client ODBC};DBQ=oracle:1521/XEPDB1;UID=system;PWD=OdbcTest123!;' ;;
    *) echo "Unsupported engine: $ENGINE" >&2; exit 1 ;;
esac

if [[ "$ENGINE" == "oracle" ]]; then
    COMPOSE_PROFILE="oracle-test"
    RUNNER_SERVICE="test-runner-oracle"
else
    COMPOSE_PROFILE="test"
    RUNNER_SERVICE="test-runner"
fi

step() { printf '\033[36m[docker_e2e]\033[0m %s\n' "$*"; }
ok2()  { printf '\033[32m[docker_e2e]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[docker_e2e]\033[0m %s\n' "$*" >&2; }

step "Engine: $ENGINE"
step "DSN:    $DSN"

step 'Ensuring DB stack is up...'
if [[ "$ENGINE" == "db2" ]]; then
    "$SCRIPT_DIR/docker_db_up.sh" --include-db2 --timeout 600
else
    "$SCRIPT_DIR/docker_db_up.sh" --timeout 240
fi

if [[ $NO_BUILD -eq 0 ]]; then
    step "Building $RUNNER_SERVICE image (cached)..."
    docker compose --profile "$COMPOSE_PROFILE" build "$RUNNER_SERVICE"
fi

if [[ $SMOKE_ONLY -eq 1 ]]; then
    cargo_cmd="cargo test --lib --features ${FEATURES} transaction -- --test-threads=1"
elif [[ $QUICK -eq 1 ]]; then
    if [[ -n "$TEST_FILTER" ]]; then
        cargo_cmd="cargo test --features ${FEATURES} ${TEST_FILTER} -- --test-threads=1"
    else
        cargo_cmd="cargo test --features ${FEATURES} -- --test-threads=1"
    fi
else
    if [[ -n "$TEST_FILTER" ]]; then
        cargo_cmd="cargo test --features ${FEATURES} ${TEST_FILTER} -- --include-ignored --test-threads=1"
    else
        cargo_cmd="cargo test --features ${FEATURES} -- --include-ignored --test-threads=1"
    fi
fi

step "Inside container: $cargo_cmd"

if docker compose --profile "$COMPOSE_PROFILE" run --rm \
        -e "ODBC_TEST_DSN=$DSN" \
        -e "ENABLE_E2E_TESTS=1" \
        "$RUNNER_SERVICE" bash -c "$cargo_cmd"; then
    ok2 "All requested tests passed for engine=$ENGINE."
else
    fail "Test run failed for engine=$ENGINE."
    exit 1
fi
