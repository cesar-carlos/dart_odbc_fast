# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-01-26

### Fixed
- Reduced topics to 5 (pub.dev limit)
- Improved Native Assets documentation

### Added
- Automatic native binary download from GitHub Releases
- Local cache for downloaded binaries (~/.cache/odbc_fast/)
- Multi-platform binary support (Windows x64, Linux x64, macOS x64/ARM)

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
- Support for Windows, Linux, and macOS platforms
- **Native Assets**: Automatic binary distribution (no manual compilation required)
- Multi-platform binary builds via GitHub Actions
- Automatic library loading with intelligent fallback strategy
