# Remaining Implementation Checklist

## Context

This file consolidates what is still pending after the CI hardening and
multi-database validation work.

Current state:
- 5-database CI matrix is green (Oracle, SQL Server, PostgreSQL, MySQL, SQLite).
- SQL Server driver installation in CI is hardened for Ubuntu 24.
- Main roadmap gap is now concentrated in statement reuse performance.

## Pending Items

### 1) Statement Reuse Real Gain (F9)

Status: in progress, currently blocked by upstream lifetime constraints
(`odbc-api`), with measured regression when opt-in is enabled.

Current observed behavior:
- Opt-in path is integrated.
- Real handle reuse is not complete.
- Repetitive benchmark does not meet target (+10%), and can regress.

Implementation checklist:
- [ ] Implement real statement handle reuse for equivalent SQL hits.
- [ ] Ensure LRU eviction releases resources safely (no leaks).
- [ ] Keep timeout-per-execution behavior intact and covered by tests.
- [ ] Remove/avoid overhead paths when reuse is not effective.
- [ ] Reach benchmark target: >= 10% improvement in repetitive scenario.

Acceptance criteria:
- [ ] Repetitive benchmark shows >= 10% throughput gain with opt-in enabled.
- [ ] No regressions in E2E timeout, statement reuse, and BCP fallback suites.
- [ ] `cargo clippy --all-targets --all-features -D warnings` passes.

Suggested validation commands:
- `cd native && cargo test e2e_statement_reuse_test -- --nocapture`
- `cd native && cargo test e2e_timeout_test -- --nocapture`
- `cd native && cargo bench --bench comparative_bench`

---

### 2) Metadata Cache E2E Validation (complementary)

Status: implementation complete; missing explicit E2E evidence for the
"80%+ reduction" claim in real multi-db environment.

Checklist:
- [ ] Run cache-focused E2E benchmark in CI or controlled local environment.
- [ ] Record before/after metrics and test settings.
- [ ] Publish evidence in docs (single source of truth).

Acceptance criteria:
- [ ] Repeated metadata calls show >= 80% reduction versus cold path baseline.
- [ ] Result is reproducible in at least one CI run.

---

## Closeout Definition

The implementation plan can be considered fully complete when:
- [ ] F9 benchmark target (+10%) is achieved with stable behavior.
- [ ] Metadata cache E2E evidence is recorded and published.
- [ ] Final status note is updated in project docs.
