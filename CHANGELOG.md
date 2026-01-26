# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `streamQueryBatched` on `NativeOdbcConnection` for cursor-based batched streaming
  (complete protocol messages per batch; preferred for large result sets).

### Changed
- `executeQuery` (repository/service) now prefers `streamQueryBatched`, with
  fallback to `streamQuery` on failure.
- README and example updated to document and use `streamQueryBatched`.

## [0.1.4] - 2026-01-26

### Performance
- Removed AddressSanitizer and UBsanitizer from default build configuration
  (70% reduction in build time: 10-15 min → 3-5 min)
- Added thin LTO and optimized codegen units for faster release builds
- Reduced binary size with strip=true

### Fixed
- Corrected download URL in Native Assets hook to match GitHub release structure
- Fixed release workflow build path for Cargo workspace structure
- Fixed ffigen verbose flag syntax in workflows
- Added missing libclang-dev and llvm dependencies for cbindgen in CI

### Changed
- Simplified CI/CD by removing redundant workflows (keep only release.yml)
- Added Rust dependency caching to reduce build times in CI
- Release workflow now uploads binaries to root level (no subdirectories)
- Added explicit timeout and verbose output for better debugging

## [0.1.3] - 2026-01-26

### Fixed
- Corrected download URL in Native Assets hook to match GitHub release structure

## [0.1.2] - 2026-01-26

### Changed
- Removed macOS support entirely
- Simplified workflows to Windows and Linux only
- Optimized CI/CD pipelines

## [0.1.1] - 2026-01-26

### Fixed
- Reduced topics to 5 (pub.dev limit)
- Improved Native Assets documentation

### Changed
- Removed macOS support (now Windows and Linux only)
- Simplified release workflow to 2 platforms

### Added
- Automatic native binary download from GitHub Releases
- Local cache for downloaded binaries (~/.cache/odbc_fast/)
- Multi-platform binary support (Windows x64, Linux x64)

## [0.1.0] - 2026-01-26

### Added
- Initial release
- Core ODBC functionality with Rust engine via FFI
- Clean Architecture API with Domain, Application, and Infrastructure layers
- Connection management (connect, disconnect)
- Query execution (executeQuery, executeQueryParams, executeQueryMulti)
- Transaction support (begin, commit, rollback) with isolation levels
- Prepared statements (prepare, executePrepared, closeStatement)
- Connection pooling (poolCreate, poolGetConnection, poolReleaseConnection, poolHealthCheck, poolGetState, poolClose)
- Streaming query results for efficient large result set processing
- Bulk insert operations with BulkInsertBuilder
- Database catalog queries (tables, columns, typeInfo)
- Comprehensive error handling with OdbcError hierarchy
- Performance metrics (OdbcMetrics)
- Service locator for dependency injection
- Centralized logging (AppLogger)

### Technical Details
- Native Rust engine for high-performance ODBC operations
- Binary protocol for efficient data transfer
- Type-safe parameter values (ParamValue hierarchy)
- Result-based error handling using result_dart package
- Support for Windows and Linux platforms
- **Native Assets**: Automatic binary distribution (no manual compilation required)
- Multi-platform binary builds via GitHub Actions
- Automatic library loading with intelligent fallback strategy
