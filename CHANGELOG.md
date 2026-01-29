# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.8] - 2026-01-29

### Added

- `scripts/copy_odbc_dll.ps1`: copies `odbc_engine.dll` from package (pub cache) to project root and Flutter runner folders (Debug/Release) for consumers who need the DLL manually

### Changed

- Publish `hook/` and `scripts/` in the package (removed from `.pubignore`): Native Assets hook runs for consumers so the DLL can be downloaded/cached automatically; script `copy_odbc_dll.ps1` is available in the package

### Fixed

- Async API (worker isolate): empty result (DDL/DML, SELECT with no rows) is now returned as `Result.ok(QueryResult(columns: [], rows: [], rowCount: 0))` instead of `Result.err(QueryError("No error", ...))` (fixes "No error" when executing CREATE TABLE, INSERT, ALTER, etc.)

## [0.2.7] - 2026-01-29

### Fixed

- Native DLL cache now keyed by package version (`~/.cache/odbc_fast/<version>/`) to avoid loading an older DLL when upgrading the package (fixes symbol lookup error 127 for new symbols e.g. `odbc_savepoint_create`)

## [0.2.6] - 2026-01-29

### Added

- README: "Support the project" section with Pix (buy developer a coffee)

### Changed

- Exclude `test/my_test/` from pub package via `.pubignore` (domain-specific tests)
- README: installation example updated to `^0.2.6`

## [0.2.5] - 2026-01-29

### Added

- Database type detection in tests: `detectDatabaseType()`, `skipIfDatabase()`, `skipUnlessDatabase()`
- Test helpers for conditional execution by database (SQL Server, PostgreSQL, MySQL, Oracle)
- `test/helpers/README.md` with usage and examples

### Changed

- Dart tests run sequentially (`--concurrency=1`) to avoid resource contention (ServiceLocator, worker isolates)
- Savepoint release test skipped on SQL Server (RELEASE SAVEPOINT not supported)

### Fixed

- Rust FFI E2E: `ffi_test_dsn()` loads `.env` and checks `ENABLE_E2E_TESTS`; invalid stream ID race in tests
- Dart integration test timeouts when running in parallel

## [0.2.4] - 2026-01-27

### Added

- Examples: multi-result, timeouts, typed params, and low-level wrappers

### Changed

- README: refresh API coverage and fix broken links

## [0.2.3] - 2026-01-27

### Changed

- CI: run only unit tests that do not require real ODBC connection (domain, protocol, errors)
- CI: exclude stress, integration/e2e, and native-dependent tests from publish pipeline

## [0.2.2] - 2026-01-27

### Changed

- Version bump for release

## [0.2.1] - 2026-01-27

### Fixed

- Fixed Native Assets hook to read package version from correct pubspec.yaml
- Fixed test helper to properly handle empty environment variables
- Fixed GitHub Actions cache paths and key format

### Changed

- Improved CI workflow: now builds Rust library before running tests
- Split unit and integration tests in CI for better organization
- Enhanced GitHub Actions workflows with proper dependency installation

## [0.2.0] - 2026-01-27

### Added

- Savepoints (nested transaction markers)
- Automatic retry with exponential backoff for transient errors
- Connection timeouts (login/connection timeout configuration)
- Connection String Builder (fluent API)
- Backpressure control in streaming queries

### Changed

- Async API with worker isolate for non-blocking operations
- Comprehensive E2E Rust tests with coverage reporting
- Improved documentation and troubleshooting guides

### Fixed

- Various lint issues (very_good_analysis compliance)
- Code formatting and cleanup

## [0.1.6] - 2025-12-XX

### Added

- Initial stable release
- Core ODBC functionality
- Streaming queries
- Connection pooling
- Prepared statements
- Transaction support
- Bulk insert operations
- Metrics and observability

[0.2.6]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/cesar-carlos/dart_odbc_fast/releases/tag/v0.1.6
