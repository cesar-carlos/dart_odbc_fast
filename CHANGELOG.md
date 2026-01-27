# Changelog

## [0.2.0] - 2026-01-27

### Added – true non-blocking implementation

- **Worker isolate**: Long-lived background isolate for all FFI operations
- **Message protocol**: SendPort/ReceivePort-based request/response system
- **True parallelism**: Multiple requests are queued and processed by the worker
- **Lifecycle management**: Proper isolate spawn, initialization, and shutdown
- **Error recovery**: [WorkerCrashRecovery](lib/infrastructure/native/isolate/error_recovery.dart) for worker crash handling
- **ServiceLocator.shutdown()**: Cleanup worker isolate on app exit when using async

### Changed – breaking

- `AsyncNativeOdbcConnection()` now takes no constructor argument (worker owns its native connection)
- `ServiceLocator.initialize(useAsync: true)` required for async; use `locator.asyncService` when async
- All async operations run in the worker isolate (main thread stays responsive)
- Call `ServiceLocator().shutdown()` on app exit when using async

### Fixed

- UI freezing during long queries in Flutter applications
- Tests that did not validate true non-blocking behavior
- Documentation that claimed non-blocking while operations were still synchronous

### Performance

- One-time worker spawn: ~50–100ms
- Per-operation overhead: ~1–3ms
- Event loop ticks normally during database operations

### Migration

- No breaking API changes for **sync** users. For **async** users:
  1. Use `AsyncNativeOdbcConnection()` with no argument
  2. Call `await service.initialize()` before first use (unchanged)
  3. Call `ServiceLocator().shutdown()` on app exit when using async
  4. See [doc/MIGRATION_ASYNC.md](doc/MIGRATION_ASYNC.md) for details
