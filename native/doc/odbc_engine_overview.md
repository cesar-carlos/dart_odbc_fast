# ODBC Engine (Rust) — overview

## What it is

`native/odbc_engine` is a Rust library exposing:

- A **Rust API** (types like `OdbcEnvironment`, `OdbcConnection`, protocol encoders/decoders).
- A **C ABI / FFI surface** (functions `odbc_*`) intended to be consumed from Dart/Flutter.

It is built around:

- **ODBC access** via `odbc_api`
- **Binary protocol** to return results as a compact buffer (instead of per-row callbacks)
- **Optional streaming** (chunked copy-out via FFI) and a **batched streaming** executor (bounded memory)
- **Connection pooling** via `r2d2`
- **Transactions** with isolation levels + RAII auto-rollback and SQL savepoints

## Architecture

The authoritative module map and design decisions are in
[Engine architecture](../odbc_engine/ARCHITECTURE.md). Execution and buffer
flows are described in [Data paths](data_paths.md).

## Key Rust entrypoints

From `src/lib.rs` the crate re-exports:

- `OdbcEnvironment` and `OdbcConnection`
- `execute_query_with_connection`
- `BinaryProtocolDecoder`, `DecodedResult`, `ColumnInfo`
- `OdbcError`, `Result<T>`

From `engine::core` (re-exported as `engine::core::*`) there are additional building blocks:

- `DiskSpillStream` (spill-to-disk for large buffers)
- `MetadataCache` + types (`TableSchema`, `ColumnMetadata`) (TTL + LRU)
- `PreparedStatementCache` (LRU cache keyed by SQL)
- `ProtocolEngine` + `ProtocolVersion` (protocol version negotiation)
- `ConnectionManager` (pool registry)
- `ParallelBulkInsert` (rayon + pool + array binding)
- `SecurityLayer` + `SecureBuffer` (zeroize wrapper for sensitive byte buffers)

Other public modules:

- `observability::*` (`Metrics`, `StructuredLogger`, `Tracer`, etc.)
- `security::*` (`SecretManager`, `Secret`, `AuditLogger`, secure buffers)
- `plugins::*` (`DriverPlugin`, `OptimizationRule`, `PluginRegistry`)

## Result format (binary protocol)

Queries return a `Vec<u8>` with the engine’s binary protocol. On the Rust side you can decode it with:

- `protocol::BinaryProtocolDecoder` → `protocol::DecodedResult`

This is also the primary format used across the FFI boundary.

## Where to look next

- For the complete FFI entrypoints and their semantics, see `src/ffi/mod.rs` and
  the curated [FFI reference](ffi_api.md).
- For throughput-oriented APIs (streaming/pool/array binding/transactions), see:
  [Data paths](data_paths.md).
