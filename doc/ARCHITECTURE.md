# `dart_odbc_fast` — Dart Layer Architecture

Companion to [`native/odbc_engine/ARCHITECTURE.md`](../native/odbc_engine/ARCHITECTURE.md).
This document describes only the **Dart side** of the package: layers,
boundaries, the public barrel, the service locator, and the runtime
seams (sealed `OdbcBackend`, sub-interfaces of `IOdbcService`, runners
inside the repository, event bus). It does not cover the Rust engine,
the wire protocol, or driver behavior — those live in the native doc.

## High-level layering

```mermaid
flowchart TB
  subgraph Public["Public API barrels"]
    P1[lib/odbc_fast.dart — curated domain + services]
    P2[lib/odbc_fast_native.dart — opt-in FFI / repository impl]
  end

  subgraph Application["application/"]
    A1[IOdbcService — aggregate]
    A2[IQueryService\nITransactionService\nIPoolService\nIAdminService]
    A3[OdbcService — concrete]
    A4[TelemetryOdbcServiceDecorator]
  end

  subgraph Domain["domain/"]
    D1[Connection, ConnectionOptions, QueryResult,\nOdbcMetrics, OdbcEvent, TypedColumnarResult]
    D2[OdbcError sealed hierarchy]
    D3[IOdbcRepository — abstraction]
  end

  subgraph Infrastructure["infrastructure/"]
    I1[OdbcRepositoryImpl — facade]
    I1a[OdbcCatalogRunner\nOdbcBulkRunner\nOdbcRepositoryState]
    I2[Sealed OdbcBackend\nSyncBackend / AsyncBackend]
    I3[NativeOdbcConnection\nAsyncNativeOdbcConnection]
    I4[BinaryProtocolParser\nFrameAccumulator\nLazyString]
  end

  subgraph Core["core/"]
    C1[ServiceLocator]
    C2[AppLogger]
  end

  Public --> Application
  Application --> Domain
  Application --> Infrastructure
  Infrastructure --> Domain
  Application --> Core
  Core --> Infrastructure
  I1 --> I1a
  I1 --> I2
  I2 --> I3
  I3 --> I4
```

The arrows describe **import direction**. Inner layers (`domain`) never
depend on outer layers (`infrastructure`, `application`). The
`OdbcRepositoryImpl` façade is allowed to compose its own runners
(`OdbcCatalogRunner`, `OdbcBulkRunner`) because the runners live in the
same layer.

## Public API barrels

Package consumers have two deliberate entry points:

1. **`package:odbc_fast/odbc_fast.dart`** (recommended) — curated domain
   entities, `IOdbcService` + sub-interfaces, `ServiceLocator`, telemetry
   decorators, and stable helpers (`TypedColumnarResult`, `OdbcEvent`,
   `For` extensions).
2. **`package:odbc_fast/odbc_fast_native.dart`** (opt-in) — FFI connection
   types (`NativeOdbcConnection`, `AsyncNativeOdbcConnection`),
   `OdbcRepositoryImpl`, pool factory, `AsyncError`, and OpenTelemetry
   FFI. Prefer this only for demos/benchmarks or repository-level seams.

`lib/odbc_fast.dart` re-exports:

- **Domain entities** — `Connection`, `ConnectionOptions`, `QueryResult`
  (with optional `columnsMetadata`), `OdbcMetrics`, `PoolState`,
  `OdbcEvent` (sealed lifecycle events), `TypedColumnarResult`,
  `DartSideMetrics`.
- **Errors** — `OdbcError` sealed hierarchy.
- **Service contracts** — `IOdbcService` aggregate plus the four
  narrower sub-interfaces (`IQueryService`, `ITransactionService`,
  `IPoolService`, `IAdminService`).
- **Concrete service + DI** — `OdbcService`, `ServiceLocator`, opt-in
  `TelemetryOdbcServiceDecorator` / `TelemetryOdbcDecorators`.
- **Opt-in helpers** — `LazyString`, `toTypedColumnar`, the `For`
  extensions for `Connection`-based call sites.

Application code should depend on `IOdbcService` (or a narrower
sub-interface) via `ServiceLocator`. Reach for `odbc_fast_native.dart`
only when you must talk to FFI types or assemble `OdbcRepositoryImpl`
yourself. See [`example/README.md`](../example/README.md) and
[`API_SURFACE.md`](API_SURFACE.md) §7.1.

## Service locator wiring (sync vs async stack)

```mermaid
flowchart LR
  Init[ServiceLocator.initialize\\nresolve OdbcUsageProfile] --> Mode{useAsync?}
  Mode -- yes --> Async[Construct AsyncNativeOdbcConnection\\nWrap in AsyncBackend\\nBuild OdbcRepositoryImpl async]
  Mode -- no --> Sync[Eagerly build NativeOdbcConnection\\nWrap in SyncBackend\\nBuild OdbcRepositoryImpl sync]
  Async --> AsyncSvc[AsyncOdbcService — primary]
  Sync --> SyncSvc[OdbcService]
  Async -. lazy .-> SyncSvc
  AsyncSvc & SyncSvc --> Consumers[Package consumers]
```

In legacy / sync mode the service locator builds the sync stack
eagerly. In async mode it defers sync construction until a consumer
explicitly asks for `service`, `syncService`, `nativeConnection`, or
`auditLogger` — avoiding a redundant ODBC environment init when the
async stack is the primary surface.

## Sealed `OdbcBackend`

```mermaid
flowchart LR
  Repo[OdbcRepositoryImpl] --> B{OdbcBackend\\nsealed}
  B --> S[SyncBackend\\nNativeOdbcConnection]
  B --> A[AsyncBackend\\nAsyncNativeOdbcConnection]
```

The repository never holds a `dynamic _native` — it owns a typed
[`OdbcBackend`](../lib/infrastructure/native/odbc_backend.dart) and
dispatches every call through exhaustive pattern matching:

```dart
switch (backend) {
  SyncBackend(:final connection) => connection.executeQuery(...),
  AsyncBackend(:final connection) => await connection.executeQuery(...),
}
```

This eliminates runtime casts, enables the analyzer to enforce that
new backends require explicit handling, and lets the runners (catalog,
bulk) accept a single `OdbcBackend` constructor argument instead of a
sync/async pair.

## Sub-interfaces of `IOdbcService`

```mermaid
flowchart TB
  IOdbcService --> IQuery[IQueryService\\nexecuteQuery, executeQueryNamed,\\nexecuteQueryColumnar, streamQuery*]
  IOdbcService --> ITxn[ITransactionService\\nbeginTransaction, commit, rollback,\\nrunInTransaction]
  IOdbcService --> IPool[IPoolService\\npoolCreate, poolGetConnection,\\npoolReleaseConnection, poolSetSize]
  IOdbcService --> IAdmin[IAdminService\\ninitialize, shutdown, getMetrics,\\ngetWorkerPoolStats, events]
```

`IOdbcService` also exposes aggregate-only helpers such as
`runInXaTransaction` (XA / 2PC ergonomics on top of `XaTransactionHandle`).
Prefer that over manual XA chaining in application code; see
`example/xa_2pc_demo.dart`.

Consumers that only need queries should depend on `IQueryService`;
consumers that only manage transactions should depend on
`ITransactionService`; etc. The aggregate `IOdbcService` keeps the
combined surface for backwards compatibility and for code that
genuinely needs multiple categories.

The opt-in `For` extension methods (`executeQueryFor(Connection conn,
...)`) live next to each sub-interface and let call sites take a
`Connection` instead of plumbing `connectionId` strings.

## Repository runners

```mermaid
flowchart LR
  Repo[OdbcRepositoryImpl\\nfaçade] --> State[OdbcRepositoryState]
  Repo --> Conn[OdbcConnectionRunner]
  Repo --> Query[OdbcQueryRunner / OdbcQuerySyncRunner]
  Repo --> Prep[OdbcQueryPreparedRunner]
  Repo --> Multi[OdbcQueryMultiRunner]
  Repo --> Stream[OdbcStreamRunner]
  Repo --> Txn[OdbcTransactionRunner]
  Repo --> Pool[OdbcPoolRunner]
  Repo --> Admin[OdbcAdminRunner]
  Repo --> Catalog[OdbcCatalogRunner]
  Repo --> Bulk[OdbcBulkRunner]
```

The repository is split into composition-first runners. Each runner is
**stateless**: it receives the `OdbcBackend`, a `nativeIdLookup` closure,
and helpers (`parseBuffer`, `convertError`) via constructor injection so the
façade keeps a single source of truth for cross-cutting concerns.

Runners shipped today:

- [`OdbcConnectionRunner`](../lib/infrastructure/repositories/runners/odbc_connection_runner.dart)
  — connect, disconnect, validate, driver capabilities.
- [`OdbcQueryRunner`](../lib/infrastructure/repositories/runners/odbc_query_runner.dart)
  / [`OdbcQuerySyncRunner`](../lib/infrastructure/repositories/runners/odbc_query_sync_runner.dart)
  — execute, columnar execute, named params.
- [`OdbcQueryPreparedRunner`](../lib/infrastructure/repositories/runners/odbc_query_prepared_runner.dart)
  — prepare, execute prepared, statement cache.
- [`OdbcQueryMultiRunner`](../lib/infrastructure/repositories/runners/odbc_query_multi_runner.dart)
  — multi-result execute paths.
- [`OdbcStreamRunner`](../lib/infrastructure/repositories/runners/odbc_stream_runner.dart)
  — `streamQuery*`, `streamQueryMulti`; uses
  [`StreamCapabilityPolicy`](../lib/infrastructure/repositories/runners/stream_capability_policy.dart)
  and [`StreamChunkDecoder`](../lib/infrastructure/repositories/runners/stream_chunk_decoder.dart).
- [`OdbcTransactionRunner`](../lib/infrastructure/repositories/runners/odbc_transaction_runner.dart)
  — transactions, savepoints, XA.
- [`OdbcPoolRunner`](../lib/infrastructure/repositories/runners/odbc_pool_runner.dart)
  — pool create/resize/health/checkout.
- [`OdbcAdminRunner`](../lib/infrastructure/repositories/runners/odbc_admin_runner.dart)
  — initialize, version, metrics, event bus.
- [`OdbcCatalogRunner`](../lib/infrastructure/repositories/runners/odbc_catalog_runner.dart)
  — `catalogTables`, `catalogColumns`, `catalogTypeInfo`,
  `catalogPrimaryKeys`, `catalogForeignKeys`, `catalogIndexes`.
- [`OdbcBulkRunner`](../lib/infrastructure/repositories/runners/odbc_bulk_runner.dart)
  — `bulkInsert`, `bulkInsertParallel` (with single-connection fallback when
  `parallelism <= 1`).

Shared helpers: [`OdbcFfiDispatch`](../lib/infrastructure/repositories/runners/odbc_ffi_dispatch.dart),
[`OdbcResultParser`](../lib/infrastructure/repositories/runners/odbc_result_parser.dart).
See `native/doc/repository_split_plan.md` for the long-term plan.

## Event bus pipeline

```mermaid
flowchart LR
  Repo[OdbcRepositoryImpl\\n_emit\\u2026] --> Ctrl[Broadcast StreamController\\\\nOdbcEvent]
  Ctrl --> Service[OdbcService bridge\\nlistens + republishes]
  Service --> Subs[Multiple consumers\\nlog, metrics, dashboards]
```

`IAdminService.events` is a broadcast `Stream<OdbcEvent>`. The
repository emits events at five points (today):

- `ConnectionLost` — `_withReconnect` detected a dropped connection.
- `AutoReconnectAttempted` — `_withReconnect` retried.
- `WorkerRecovered` — async worker pool recovered from a crash.
- `PoolResize` — `poolSetSize` changed pool capacity.
- `SlowQueryDetected` — query crossed `ConnectionOptions.slowQueryThreshold`
  (emitted from the repository when the threshold is configured).

Listeners do not back-pressure emission — they're observability
signals. The surface is sealed so adding a new event variant is a
deliberate, additive change.

## Related documents

- [`doc/ARCHITECTURE.md`](ARCHITECTURE.md)
  — Dart layers, barrels, DI, events.
- [`doc/README.md`](README.md) — documentation index.
- [`native/odbc_engine/ARCHITECTURE.md`](../native/odbc_engine/ARCHITECTURE.md)
  — Rust engine (workers, FFI, protocol, drivers).
- [`native/doc/ffi_api.md`](../native/doc/ffi_api.md) — exported FFI
  surface.
- [`native/doc/async_api_guide.md`](../native/doc/async_api_guide.md) —
  worker pool + recovery flow.
- [`native/doc/profile_selection_guide.md`](../native/doc/profile_selection_guide.md)
  — `OdbcUsageProfile` decision tree.
- [`CHANGELOG.md`](../CHANGELOG.md) — release notes per PR.
