#!/usr/bin/env bash
# Bring up the Docker DB stack used by the E2E suite, wait for every
# container to report healthy. POSIX equivalent of `docker_db_up.ps1`.

set -euo pipefail

INCLUDE_DB2=0
DOWN=0
TIMEOUT_SECONDS=300
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  scripts/docker_db_up.sh                  # PG + MySQL + MariaDB + MSSQL + Oracle
  scripts/docker_db_up.sh --include-db2    # also start IBM Db2 (slow)
  scripts/docker_db_up.sh --down           # tear everything down
  scripts/docker_db_up.sh --timeout 600    # change healthcheck timeout
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-db2) INCLUDE_DB2=1; shift ;;
        --down) DOWN=1; shift ;;
        --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

info()  { printf '\033[36m[docker_db_up]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[docker_db_up]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[docker_db_up]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[docker_db_up]\033[0m %s\n' "$*" >&2; }

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    fail "Docker daemon is not reachable. Is Docker (Desktop) running?"
    exit 1
fi
info "Docker server: $(docker version --format '{{.Server.Version}}')"

if [[ $DOWN -eq 1 ]]; then
    info "Stopping the DB stack..."
    docker compose --profile db2 down --volumes --remove-orphans
    ok "All containers + volumes removed."
    exit 0
fi

services=(postgres mysql mariadb mssql oracle)
compose_args=(compose)
if [[ $INCLUDE_DB2 -eq 1 ]]; then
    compose_args+=(--profile db2)
    services+=(db2)
fi
compose_args+=(up -d "${services[@]}")

info "Bringing up: ${services[*]}"
docker "${compose_args[@]}"

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
pending=("${services[@]}")
info "Waiting for healthchecks (timeout: ${TIMEOUT_SECONDS}s)..."

while [[ ${#pending[@]} -gt 0 ]]; do
    if [[ $(date +%s) -gt $deadline ]]; then
        fail "Timed out waiting for: ${pending[*]}"
        exit 2
    fi
    new_pending=()
    for svc in "${pending[@]}"; do
        container="odbc_test_${svc}"
        state=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)
        case "$state" in
            healthy)
                printf '\033[32m[docker_db_up]\033[0m   %-9s healthy\n' "$svc"
                ;;
            unhealthy)
                fail "  $svc unhealthy. Last 10 log lines:"
                docker logs --tail 10 "$container" >&2 || true
                exit 3
                ;;
            *)
                new_pending+=("$svc")
                ;;
        esac
    done
    pending=("${new_pending[@]}")
    [[ ${#pending[@]} -gt 0 ]] && sleep 1.5
done

ok "All services are healthy."
echo
echo "=== DSN cheatsheet (host -> container) ==========================="
echo "  PostgreSQL:"
echo "    ODBC_TEST_DSN='Driver={PostgreSQL Unicode};Server=localhost;Port=5432;Database=odbc_test;UID=postgres;PWD=postgres;'"
echo "  MySQL 8:"
echo "    ODBC_TEST_DSN='Driver={MySQL ODBC 8.0 Unicode Driver};Server=localhost;Port=3306;Database=odbc_test;UID=odbc;PWD=odbc;'"
echo "  MariaDB 11:"
echo "    ODBC_TEST_DSN='Driver={MariaDB ODBC 3.1 Driver};Server=localhost;Port=3307;Database=odbc_test;UID=odbc;PWD=odbc;'"
echo "  SQL Server 2022:"
echo "    ODBC_TEST_DSN='Driver={ODBC Driver 18 for SQL Server};Server=localhost,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;'"
echo "=================================================================="
echo "Tip: install missing ODBC drivers on the host, OR run inside the"
echo "     test-runner container (see scripts/docker_e2e.sh)."
