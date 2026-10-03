# Examples

Start with [quick_start_balanced_demo.dart](quick_start_balanced_demo.dart) for
small results, or [recommended_performance_patterns_demo.dart](recommended_performance_patterns_demo.dart)
for the workload-to-API guide. These use the public Result services and explicit
usage profiles.

Run commands from the repository root. Live examples load `ODBC_TEST_DSN` or
`ODBC_DSN` from the environment or `.env`. Missing configuration prints
`Skipping DB-dependent example.` before loading the native backend.
`ODBC_EXAMPLE_DISABLE_DSN=1` forces this skip, including when `.env` exists.

## Performance patterns

| Workload | Example | Pattern |
| --- | --- | --- |
| Small response | [quick_start_balanced_demo.dart](quick_start_balanced_demo.dart) | `balanced`, typed `ParamValue`, narrow `IQueryService` |
| Repeated SQL | [named_parameters_demo.dart](named_parameters_demo.dart) | Prepare once outside the loop; bind values; close once |
| Large row scan | [streaming_demo.dart](streaming_demo.dart) | `streamQueryFor`, 1000-row fetches, profile chunk recommendation |
| Large numeric scan | [stream_query_columnar_demo.dart](stream_query_columnar_demo.dart) | Typed arrays, null-aware aggregation, one batch at a time |
| Small numeric result | [typed_columnar_demo.dart](typed_columnar_demo.dart) | Explicit buffered columnar API; resolve columns once |
| Repeated named-column access | [query_result_access_demo.dart](query_result_access_demo.dart) | One `result.reader()` per result/batch; no row maps |
| Large multi-result cursor | [multi_result_batches_demo.dart](multi_result_batches_demo.dart) | `streamQueryMultiBatches`; handle continuations independently |
| Bulk writes | [bulk_insert_demo.dart](bulk_insert_demo.dart) | Column-oriented payload, bounded batch generation |
| Independent bulk writes | [bulk_insert_parallel_demo.dart](bulk_insert_parallel_demo.dart) | Native parallel bulk through async Result service; bounded payload |
| Independent requests | [high_concurrency_pool_demo.dart](high_concurrency_pool_demo.dart) | Separate pool checkouts; bounded tasks; drain active work before shutdown |

Choose fetch size, payload size and concurrency from measurements on your driver
and schema. There is no universal row-count threshold for parallel bulk.
A single ODBC connection stays serialized even with multiple Dart workers.
The pool example limits in-flight work to the recommended pool size; it does not
allocate a Future/result list for every request.

The read examples aggregate or count rows without logging each row, creating
maps, retaining all batches or launching unawaited consumers. Await asynchronous
batch consumers inside `await for` to apply backpressure. Rows in one fetch batch
can still be large: tune `fetchSize` and connection buffer limits for your data.
Retaining views/typed columns retains their backing memory.

Server examples use `balancedServer` or `highThroughput` and
`recommendedStreamChunkSizeBytes` (currently 1 MiB). Explicit columnar APIs are
required: selecting a server profile does not make `executeQuery` columnar.
Numeric examples expect a `score` column backed by float or integer arrays;
decimal columns may be string-backed. Use `FLOAT`/`DOUBLE` in dialect-appropriate
SQL and adapt the default literal SELECTs for Oracle or other drivers.

`QueryResultReader` fixes column names at creation, preserves first duplicate
occurrences, supports case-insensitive lookup, and reads live rows. Create a new
reader after changing the result's column layout.

PowerShell examples:

```powershell
dart run example/recommended_performance_patterns_demo.dart
$env:ODBC_STREAM_QUERY = 'SELECT id, name FROM your_table'
dart run example/streaming_demo.dart
$env:ODBC_COLUMNAR_QUERY = 'SELECT id, CAST(score AS FLOAT) AS score FROM your_table'
dart run example/stream_query_columnar_demo.dart
$env:ODBC_PREPARED_ITERATIONS = '1000'
dart run example/named_parameters_demo.dart
$env:ODBC_CONCURRENCY_TASKS = '100'
dart run example/high_concurrency_pool_demo.dart
```

Bulk demos use SQL Server DDL and uniquely named scratch tables. They create and
drop only their generated table; use a disposable database with the necessary
permissions. Both accept `ODBC_BULK_ROWS` (default 10000) and
`ODBC_BULK_BATCH_ROWS` (1000 single / 5000 parallel).
Parallel bulk also accepts `ODBC_BULK_PARALLELISM` (4) and reserves one pool
checkout for setup/cleanup. It is not a single atomic transaction; failures may
report partially inserted rows. Do not replay the payload automatically.

## Benchmarks

The demos' tiny default queries illustrate API shape. Their one-shot stopwatch
output is not proof of improvement. Use representative queries, the same SDK,
driver and data, warmup and repeated samples, and run benchmarks without
concurrent test suites.

| Benchmark | Comparison |
| --- | --- |
| [async_concurrency_benchmark.dart](async_concurrency_benchmark.dart) | Workers, pooled requests, prepared reuse, row/columnar encodings and streaming |
| [streaming_performance_benchmark.dart](streaming_performance_benchmark.dart) | Native legacy streaming vs batched streaming; fetch/chunk settings |
| [multi_result_performance_benchmark.dart](multi_result_performance_benchmark.dart) | Buffered, coalesced stream and uncoalesced batch stream |

```powershell
$env:ODBC_BENCH_OUTPUT = 'json'
$env:ODBC_BENCH_OUT_FILE = 'bench_baselines/async.json'
dart run example/async_concurrency_benchmark.dart
$env:ODBC_STREAM_BENCH_QUERY = 'SELECT id, name FROM your_table'
$env:ODBC_STREAM_BENCH_OUTPUT = 'json'
dart run example/streaming_performance_benchmark.dart
dart run example/multi_result_performance_benchmark.dart
dart run benchmarks/dart_hot_paths.dart
```

The last command measures Dart buffers/framing/readers without a database.
See [PERFORMANCE.md](../doc/PERFORMANCE.md) and [TESTING.md](../doc/TESTING.md)
for the matrix, protocol guards and baseline comparisons.

## Focused API examples

| Topic | Example |
| --- | --- |
| Small buffered/coalesced multi-result responses | [multi_result_demo.dart](multi_result_demo.dart) |
| Named streaming parameters | [stream_query_named_demo.dart](stream_query_named_demo.dart) |
| IN / OUT / INOUT parameters | [output_param_directions_demo.dart](output_param_directions_demo.dart) |
| Oracle REF CURSOR, explicitly configured | [oracle_ref_cursor_demo.dart](oracle_ref_cursor_demo.dart) |
| Local transaction scope | [run_in_transaction_demo.dart](run_in_transaction_demo.dart) |
| Savepoints within transaction scope | [savepoint_demo.dart](savepoint_demo.dart) |
| XA / one-phase shortcut / recovery listing | [xa_2pc_demo.dart](xa_2pc_demo.dart) |
| Pool options and native capability detection | [pool_with_options_demo.dart](pool_with_options_demo.dart) |
| Backpressure and recovery callbacks | [backpressure_modes_demo.dart](backpressure_modes_demo.dart) |
| Low-level async polling and streaming | [execute_async_demo.dart](execute_async_demo.dart) |
| Connection string builders | [connection_string_builder_demo.dart](connection_string_builder_demo.dart) |
| Driver-specific SQL builders | [driver_features_demo.dart](driver_features_demo.dart) |
| Schema/catalog inspection | [catalog_reflection_demo.dart](catalog_reflection_demo.dart) |
| DBMS information | [dbms_info_demo.dart](dbms_info_demo.dart) |
| Retry/configuration/schema entities | [advanced_entities_demo.dart](advanced_entities_demo.dart) |
| Typed errors and presentation | [structured_errors_demo.dart](structured_errors_demo.dart) |
| Audit wrapper | [audit_example.dart](audit_example.dart) |
| In-memory telemetry | [telemetry_demo.dart](telemetry_demo.dart) |
| Capability-scoped telemetry decorators | [telemetry_decorators_demo.dart](telemetry_decorators_demo.dart) |
| OpenTelemetry FFI / optional OTLP endpoint | [otel_repository_demo.dart](otel_repository_demo.dart) |
| Events and narrow admin interface | [event_bus_demo.dart](event_bus_demo.dart) |
| Native asset resolution, DSN-free | [native_assets_resolution_demo.dart](native_assets_resolution_demo.dart) |

`streamQueryMulti` coalesces a complete cursor, including continuation rows;
use `streamQueryMultiBatches` when a result set is large. Native API examples
preserve their sentinel/exception contracts. Result services are the default
for application examples. Import `package:odbc_fast/odbc_fast.dart` for those
services; add `odbc_fast_native.dart` only for direct native types.

## Failure and lifecycle handling

[common.dart](common.dart) centralizes DSN loading, Result-service initialization,
connection/pool cleanup and bounded task scheduling for the primary examples.
Failures print the stable code, `userMessage`, operation and uncertainty flag,
without connection strings, SQL or parameters. Cleanup failures are reported
separately and set a nonzero exit code.

A request timeout can leave work running in the driver. It does not confirm
cancellation or rollback. Sent unreconciled work still occupies async capacity;
late cleanup runs on the original worker. Closing Dart state does not guarantee
cleanup of a blocked FFI call. Do not automatically replay queries or decide an
uncertain transaction. `cancelStatement` currently returns unsupported
(SQLSTATE `0A000`); use supported driver timeouts plus explicit recovery policy.

The XA example uses the service helper and never commits recovered branches
automatically. `ODBC_XA_RECOVER_ONLY=1` lists prepared branches without changing
their decisions. Recovery/adoption requires the transaction manager's durable
XID and decision. `Xid.fromStrings` uses UTF-8; old non-ASCII branches require
their original bytes via the binary `Xid` constructor.

## Consolidated examples

The old aggregate CRUD/API walkthroughs (`main`, `simple_demo`, `async_demo`,
`service_api_coverage_demo`) have been replaced by the quick start and focused
examples. Legacy pool/worker walkthroughs are consolidated in the bounded pool
example and concurrency benchmark. The encoding and migration walkthroughs are
covered by typed columnar, typed parameters and narrow service usage in the
remaining examples. Coalesced multi-result streaming lives in
`multi_result_demo`; native transaction-helper walkthroughs are superseded by
service-managed transactions and savepoints.

Run validation without database access:

```powershell
$env:ODBC_EXAMPLE_DISABLE_DSN = '1'
dart analyze
dart test test/example test/documentation
```
