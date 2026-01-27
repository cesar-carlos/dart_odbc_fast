# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/cesar-carlos/dart_odbc_fast/releases/tag/v0.1.6
