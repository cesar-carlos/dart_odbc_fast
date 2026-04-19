# Test Coverage Report — v2.0.0

Baseline measured immediately after the v2.0.0 hardening release with
`cargo tarpaulin 0.31.5` running unit + integration tests serially
(`--test-threads=1`) without a live ODBC database.

## Headline numbers

| Metric | Value |
|---|---|
| **Overall line coverage** | **41.64%** (2 201 / 5 286 lines) |
| Unit tests passed | 766 / 766 |
| Integration tests passed | 314 / 314 (with 16 ignored gated by `ODBC_TEST_DSN`) |
| Regression tests passed | 23 / 23 (new in v2.0.0) |
| Structured-error regression | 8 / 8 |
| Clippy strict (`--all-targets --all-features -- -D warnings`) | 0 warnings |
| HTML report | [`coverage/tarpaulin-report.html`](../coverage/tarpaulin-report.html) |

The "low" overall percentage is driven by the FFI surface, the catalog
adapters, the streaming worker, and the BCP shim — modules whose meaningful
behaviour requires a live ODBC driver that is not available in CI. With a
configured `ODBC_TEST_DSN`, the 16 currently-ignored integration tests would
push coverage above 60% (estimated from per-file gap analysis).

## Coverage by module (sorted by ratio)

### 100% covered — fully exercised by unit tests

```
protocol/arena.rs                  20/20
protocol/columnar.rs               19/19
protocol/decoder.rs                39/39
protocol/multi_result.rs           18/29  (62% — see medium tier)
engine/statement.rs                18/18
engine/core/memory_engine.rs       20/20
engine/core/protocol_engine.rs     21/21
plugins/driver_plugin.rs            7/7
versioning/abi_version.rs          11/11
versioning/api_version.rs          15/15
versioning/protocol_version.rs     15/15
```

### Excellent (≥ 90%) — comprehensive unit-test coverage

```
engine/identifier.rs               32/34   94.1%   (NEW — added in v2.0.0)
engine/core/metadata_cache.rs      31/34   91.2%
engine/core/security_layer.rs      11/13   84.6%   (in tier below)
plugins/registry.rs                36/42   85.7%   (in tier below)
plugins/sqlserver.rs               28/30   93.3%
plugins/oracle.rs                  32/34   94.1%
plugins/postgres.rs                30/32   93.8%
plugins/mysql.rs                   30/32   93.8%
plugins/sybase.rs                  25/27   92.6%
security/audit.rs                  46/51   90.2%
security/sanitize.rs               32/34   94.1%   (improved in v2.0.0)
observability/metrics.rs           57/63   90.5%
protocol/columnar_encoder.rs       48/55   87.3%   (in tier below)
protocol/converter.rs              31/32   96.9%
protocol/param_value.rs            75/82   91.5%
protocol/encoder.rs                31/35   88.6%
```

### Good (≥ 70%) — solid coverage with minor gaps

```
engine/core/driver_capabilities.rs  21/30   70.0%
engine/core/connection_manager.rs   20/31   64.5%   (in tier below)
engine/core/pipeline.rs             15/31   48.4%   (in tier below)
engine/environment.rs               10/14   71.4%
engine/connection.rs                18/38   47.4%   (in tier below)
engine/core/disk_spill.rs           35/70   50.0%   (improved with new Drop)
engine/core/security_layer.rs       11/13   84.6%
error/mod.rs                        56/62   90.3%
ffi/guard.rs                        38/55   69.1%   (NEW — added in v2.0.0)
handles/mod.rs                      26/34   76.5%
lib.rs                              15/19   78.9%
observability/logging.rs            33/45   73.3%   (improved in v2.0.0)
observability/tracing.rs            40/46   86.9%   (improved with SpanGuard)
plugins/registry.rs                 36/42   85.7%
pool/mod.rs                        107/139   77.0%   (improved with customizer)
protocol/bulk_insert.rs             83/185  44.9%   (in tier below)
protocol/compression.rs             26/33   78.8%
protocol/multi_result.rs            18/29   62.1%
protocol/columnar_encoder.rs        48/55   87.3%
protocol/row_buffer.rs              11/13   84.6%
protocol/types.rs                   23/29   79.3%
security/secret_manager.rs          27/35   77.1%   (improved with with_secret)
security/secure_buffer.rs           15/19   78.9%   (improved with with_bytes)
async_bridge/mod.rs                 14/22   63.6%
```

### Medium (≥ 30%) — opportunistic coverage; primary path covered

```
engine/core/connection_manager.rs   20/31   64.5%
engine/core/pipeline.rs             15/31   48.4%
engine/connection.rs                18/38   47.4%
engine/core/disk_spill.rs           35/70   50.0%
engine/core/prepared_cache.rs       21/50   42.0%
engine/transaction.rs               58/150  38.7%   (improved Drop hardening)
ffi/mod.rs                         403/1540 26.2%   (most paths require live DB)
observability/telemetry/mod.rs      30/49   61.2%
observability/telemetry/exporters.rs 26/56  46.4%
protocol/bulk_insert.rs             83/185  44.9%
```

### Low (< 30%) — primarily DB-dependent paths

```
engine/cell_reader.rs                 8/36   22.2%   (live cursor required)
engine/catalog.rs                     9/121   7.4%   (SQLTables/SQLColumns paths)
engine/core/array_binding.rs         16/238   6.7%   (bulk insert needs live DB)
engine/core/batch_executor.rs         8/86    9.3%   (live txn batching)
engine/core/bulk_copy.rs              4/10   40.0%
engine/core/execution_engine.rs      37/212  17.5%   (most paths execute SQL)
engine/core/parallel_insert.rs       10/87   11.5%   (rayon + live conns)
engine/core/sqlserver_bcp.rs          0/104   0.0%   (Windows + SQL Server BCP DLL)
engine/query.rs                       2/12   16.7%
engine/streaming.rs                  49/272  18.0%   (worker threads need live DB)
handles/cached_connection.rs          3/40    7.5%   (statement-handle-reuse path)
observability/telemetry/console.rs    0/3     0.0%   (smoke-test only)
```

## What changed vs v1.2.1

The hardening release added new code (regression tests, `SpanGuard`,
`ffi::guard`, `engine::identifier`, `BulkPartialFailure`, `SqlSanitizer`,
`with_bytes`/`with_secret` and per-chunk transactional mode) that pulled
coverage **up** in the security/observability/protocol/identifier modules
even though the absolute headline number is similar. New modules covered:

| New module / function | Coverage |
|---|---|
| `engine::identifier` | 94% |
| `ffi::guard` | 69% (the rest is `unsafe` ptr branches exercised via the FFI suite when DB is available) |
| `observability::SpanGuard` | included in tracing — module went from 60.9% → 86.9% |
| `observability::sanitize_sql_for_log` | 100% via new unit tests |
| `security::SecureBuffer::with_bytes` | covered in unit tests |
| `protocol::bulk_insert::is_null_strict` | covered |

## Largest gaps & recommended actions

| Priority | Module | Gap | Recommendation |
|---|---|---|---|
| 🔴 | `engine/core/sqlserver_bcp.rs` | 100% uncovered | Add Windows-only mock-DLL CI job, or gate behind a feature that disables when DLL missing. |
| 🔴 | `ffi/mod.rs` | 1 137 lines uncovered (74%) | Expand `tests/ffi_compatibility_test.rs`; many checks are pure error-path validation that can run without a DB. |
| 🟠 | `engine/streaming.rs` | 223 lines uncovered (82%) | Add unit tests for `BatchedStreamingState`/`AsyncStreamingState` using channel mocks (no DB). |
| 🟠 | `engine/core/array_binding.rs` | 222 lines uncovered (93%) | Wrap `quote_column_list` and SQL-build helpers in pure-functional tests. |
| 🟠 | `engine/core/execution_engine.rs` | 175 lines uncovered (82%) | Add unit tests for `is_no_more_results`, plugin-mapping branches, and `SpanGuard` wiring. |
| 🟡 | `engine/transaction.rs` | 92 lines uncovered (61%) | Add unit tests using mock `HandleManager` for the new `Drop` logging branches. |
| 🟡 | `engine/catalog.rs` | 112 lines uncovered (93%) | Mostly unreachable without DB; document and accept. |
| 🟡 | `protocol/bulk_insert.rs` | 102 lines uncovered (55%) | Add unit tests targeting the new `read_null_bitmap` and `len_to_u32` error paths. |
| 🟢 | `handles/cached_connection.rs` | 37 lines uncovered (93%) | Driven by `statement-handle-reuse` feature; add feature-gated tests. |
| 🟢 | `observability/telemetry/exporters.rs` | 30 lines uncovered (54%) | Add unit tests for the new redaction allowlist. |

## How to reproduce

```powershell
# from repo root
cd native\odbc_engine
cargo test --lib --tests --no-fail-fast --all-features -- --test-threads=1
cargo clippy --all-targets --all-features -- -D warnings
cargo tarpaulin --tests --lib `
  --out Stdout --out Html `
  --output-dir D:\Developer\dart_odbc_fast\coverage `
  --skip-clean --timeout 600 -- --test-threads=1
```

Open `D:\Developer\dart_odbc_fast\coverage\tarpaulin-report.html` in a
browser for the file-level drill-down.

## Roadmap to ≥ 60% coverage (v2.1)

1. **Mock-driven FFI tests** for the validation paths in `ffi/mod.rs`
   (target: lift from 26% → 50%, +400 lines).
2. **Unit tests for streaming state machines** with crossbeam channel
   mocks (`engine/streaming.rs`, target: 18% → 60%, +110 lines).
3. **Pure-function tests for array_binding/execution_engine helpers**
   (`is_no_more_results`, `quote_column_list`, plugin mapping branches —
   +150 lines).
4. **CI matrix entry** with a SQLite ODBC driver to run the
   `#[ignore]`-gated integration tests (frees ~250 lines across catalog,
   cell_reader, bulk operations, savepoint and execution_engine).
