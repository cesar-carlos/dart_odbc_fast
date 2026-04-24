# Superfície de API exposta — `odbc_engine` v3.5.x

Documento que cataloga **tudo** o que o crate Rust expõe, em três camadas:

1. **FFI C ABI** (`extern "C"`) — consumida pelo Dart e por qualquer cliente C.
2. **API Rust pública** — quando `odbc_engine` é usado como `rlib`.
3. **Telemetria OpenTelemetry** — funções FFI separadas para integração OTel.

> **Fonte de verdade:** os cabeçalhos gerados por `cbindgen` e o arquivo
> `native/odbc_engine/src/ffi/mod.rs`. Execute `dart run ffigen -v info` para
> regenerar os bindings Dart após mudanças no ABI.

---

## 1. FFI — Superfície C ABI

**92 funções `extern "C"`** distribuídas em:
- `src/ffi/mod.rs` (84)
- `src/ffi/columnar_decompress.rs` (2)
- `src/observability/telemetry/mod.rs` (6)

Convenção geral:
- `c_uint` > 0 = ID de handle (conn, txn, stream, pool, request, statement, xa)
- `c_uint` = 0 = falha (ler `odbc_get_error*` para detalhes)
- `c_int` = 0 = sucesso, negativo = código `FfiError`

### 1.1 Bootstrap & introspecção (4)

| Função | Propósito |
|---|---|
| `odbc_init() -> c_int` | Inicializa runtime async + ambiente ODBC singleton. Idempotente. |
| `odbc_set_log_level(level) -> c_int` | Define nível global do `log` (0=off … 5=trace). |
| `odbc_get_version(buf, buf_len) -> c_int` | Retorna `{api_version, abi_version, protocol_version, crate}` em JSON. |
| `odbc_validate_connection_string(conn_str, ...) -> c_int` | Valida sintaxe da connection string sem conectar. |

### 1.2 Conexões diretas (3)

| Função | Propósito |
|---|---|
| `odbc_connect(conn_str) -> conn_id` | Abre conexão. |
| `odbc_connect_with_timeout(conn_str, timeout_ms) -> conn_id` | Idem com login timeout. |
| `odbc_disconnect(conn_id) -> c_int` | Fecha conexão e libera handles dependentes. |

### 1.3 Pool de conexões r2d2 (9)

| Função | Propósito |
|---|---|
| `odbc_pool_create(conn_str, max_size) -> pool_id` | Cria pool com `PoolAutocommitCustomizer`. |
| `odbc_pool_create_with_options(conn_str, max_size, idle_timeout_ms, max_lifetime_ms, connection_timeout_ms) -> pool_id` | Cria pool com opções de ciclo de vida (v3.4+). |
| `odbc_pool_get_connection(pool_id) -> conn_id` | Checkout sem segurar mutex global. |
| `odbc_pool_release_connection(conn_id) -> c_int` | Devolve ao pool com rollback + autocommit. |
| `odbc_pool_health_check(pool_id) -> c_int` | 1=saudável, 0=falha. |
| `odbc_pool_get_state(pool_id, ...)` | Métricas binárias do pool (size, idle, wait). |
| `odbc_pool_get_state_json(pool_id, ...)` | Mesmo conteúdo em JSON estruturado. |
| `odbc_pool_set_size(pool_id, new_max) -> c_int` | Resize dinâmico. |
| `odbc_pool_close(pool_id) -> c_int` | Drena checkouts antes de remover. |

### 1.4 Transações & savepoints (8)

| Função | Propósito |
|---|---|
| `odbc_transaction_begin(conn_id, isolation, dialect) -> txn_id` | Inicia transação (v1 — sem access mode / lock timeout). |
| `odbc_transaction_begin_v2(conn_id, isolation, dialect, access_mode) -> txn_id` | Idem com `TransactionAccessMode` (v3.1+). |
| `odbc_transaction_begin_v3(conn_id, isolation, dialect, access_mode, lock_timeout_ms) -> txn_id` | Idem com `LockTimeout` (v3.4+). |
| `odbc_transaction_commit(txn_id) -> c_int` | Commit. |
| `odbc_transaction_rollback(txn_id) -> c_int` | Rollback. |
| `odbc_savepoint_create(txn_id, name) -> c_int` | Nome validado/quotado. |
| `odbc_savepoint_rollback(txn_id, name) -> c_int` | Rollback para savepoint nomeado. |
| `odbc_savepoint_release(txn_id, name) -> c_int` | SQL-92 `RELEASE`; no-op em SQL Server. |

### 1.5 X/Open XA — 2PC (10)

Adicionados em v3.4.0 (PostgreSQL, MySQL/MariaDB, DB2) e v3.4.1 (Oracle via `DBMS_XA`).
`xa-dtc` (v3.4.0b) cobre SQL Server / MSDTC (Windows-only).

| Função | Propósito |
|---|---|
| `odbc_xa_start(conn_id, format_id, gtrid, bqual, ...) -> xa_id` | Demarca início de ramo XA. |
| `odbc_xa_end(xa_id) -> c_int` | Desassocia o ramo da thread. |
| `odbc_xa_prepare(xa_id) -> c_int` | Phase 1 — prepara (pode retornar `XA_RDONLY`). |
| `odbc_xa_commit_prepared(xa_id) -> c_int` | Phase 2 — commit. |
| `odbc_xa_rollback_prepared(xa_id) -> c_int` | Phase 2 — rollback. |
| `odbc_xa_commit_one_phase(xa_id) -> c_int` | Commit de fase única (1RM optimization). |
| `odbc_xa_rollback_active(xa_id) -> c_int` | Rollback enquanto o ramo ainda está ativo. |
| `odbc_xa_recover_count(conn_id) -> c_int` | Popula o cache de ramos in-doubt; retorna contagem. |
| `odbc_xa_recover_get(conn_id, idx, ...) -> c_int` | Lê ramo in-doubt do cache por índice. |
| `odbc_xa_resume_prepared(conn_id, format_id, gtrid, bqual, ...) -> xa_id` | Reconecta a ramo prepared para Phase 2. |

### 1.6 Diagnóstico de erro (3)

| Função | Propósito |
|---|---|
| `odbc_get_error(buf, buf_len) -> c_int` | Mensagem simples (legacy). |
| `odbc_get_structured_error(buf, ...) -> c_int` | `{sqlstate[5], native_code, message}` binário. |
| `odbc_get_structured_error_for_connection(conn_id, ...)` | Filtra por conn_id (sem race). |

### 1.7 Auditoria (4)

| Função | Propósito |
|---|---|
| `odbc_audit_enable(enabled) -> c_int` | Ativa/desativa coleta. |
| `odbc_audit_get_events(buf, ...) -> c_int` | Despeja eventos como JSON. |
| `odbc_audit_clear() -> c_int` | Limpa buffer in-memory. |
| `odbc_audit_get_status(buf, ...) -> c_int` | JSON com contadores e estado. |

### 1.8 Métricas (2)

| Função | Propósito |
|---|---|
| `odbc_get_metrics(buf, ...) -> c_int` | Snapshot JSON: `{query_count, error_count, latency_p50/p95/p99, ...}`. |
| `odbc_get_cache_metrics(buf, ...) -> c_int` | Hits/misses do prepared cache + statement cache. |

### 1.9 Caches de metadata (4)

| Função | Propósito |
|---|---|
| `odbc_metadata_cache_enable(max_size, ttl_secs) -> c_int` | Liga cache LRU+TTL de metadata. |
| `odbc_metadata_cache_stats(buf, ...) -> c_int` | Estatísticas do cache de schemas. |
| `odbc_metadata_cache_clear() -> c_int` | Invalida cache de schemas. |
| `odbc_clear_statement_cache() -> c_int` | Limpa cache de prepared statements. |

### 1.10 Detecção de driver (3)

| Função | Propósito |
|---|---|
| `odbc_detect_driver(conn_str, buf, ...) -> c_int` | Heurístico via connection string. |
| `odbc_get_driver_capabilities(conn_str, buf, ...) -> c_int` | JSON com `{engine, driver_name, prepared, batch, ...}`. |
| `odbc_get_connection_dbms_info(conn_id, buf, ...) -> c_int` | Detecção real via `SQLGetInfo` em conexão aberta. |

### 1.11 Geração de SQL por dialeto (3)

Adicionados em v3.0.0. Despacham via `PluginRegistry` — sem I/O, geradores puros de SQL.

| Função | Propósito |
|---|---|
| `odbc_build_upsert_sql(conn_str, ...) -> c_int` | Gera UPSERT no dialeto do driver. |
| `odbc_append_returning_sql(conn_str, ...) -> c_int` | Adiciona cláusula RETURNING/OUTPUT. |
| `odbc_get_session_init_sql(conn_str, ...) -> c_int` | JSON array com SQL de pós-conexão. |

### 1.12 Execução de queries (3)

| Função | Propósito |
|---|---|
| `odbc_exec_query(conn_id, sql, buf, ...) -> c_int` | Sync, sem parâmetros. |
| `odbc_exec_query_params(conn_id, sql, params, ...) -> c_int` | Sync, com `ParamValue` / DRT1 serializado. |
| `odbc_exec_query_multi(conn_id, sql, buf, ...) -> c_int` | Multi-resultset (batch `;`). |

### 1.13 Multi-resultset com parâmetros (1)

| Função | Propósito |
|---|---|
| `odbc_exec_query_multi_params(conn_id, sql, params, ...) -> c_int` | Multi-resultset + parâmetros DRT1 (v3.2+). |

### 1.14 Execução assíncrona (5)

| Função | Propósito |
|---|---|
| `odbc_execute_async(conn_id, sql) -> request_id` | Submete para Tokio runtime. |
| `odbc_async_poll(request_id, &out_status) -> c_int` | Pendente/Pronto/Erro. |
| `odbc_async_get_result(request_id, buf, ...) -> c_int` | Recupera buffer quando pronto. |
| `odbc_async_cancel(request_id) -> c_int` | `JoinHandle::abort()` cooperativo. |
| `odbc_async_free(request_id) -> c_int` | Libera slot do `AsyncRequestManager`. |

### 1.15 Statements preparados (5)

| Função | Propósito |
|---|---|
| `odbc_prepare(conn_id, sql, timeout_ms) -> stmt_id` | Prepara e cacheia. |
| `odbc_execute(stmt_id, params, buf, ...) -> c_int` | Executa com bind. |
| `odbc_cancel(stmt_id) -> c_int` | `SQLCancel`; gera erro estruturado se driver não suporta. |
| `odbc_close_statement(stmt_id) -> c_int` | Fecha e remove do cache. |
| `odbc_clear_all_statements() -> c_int` | Limpa todos os statements (shutdown helper). |

### 1.16 Streaming de resultados (9)

| Função | Propósito |
|---|---|
| `odbc_stream_start(conn_id, sql, fetch_size, ...) -> stream_id` | Cursor síncrono. |
| `odbc_stream_start_batched(conn_id, sql, fetch_size, chunk_size, ...) -> stream_id` | Worker thread + `mpsc`. |
| `odbc_stream_start_async(conn_id, sql, ...) -> stream_id` | Worker + status async. |
| `odbc_stream_multi_start_batched(conn_id, sql, ...) -> stream_id` | Multi-result batched (v3.3+). Cada frame é `[tag:u8][len:u32][payload]`. |
| `odbc_stream_multi_start_async(conn_id, sql, ...) -> stream_id` | Multi-result async (v3.3+). |
| `odbc_stream_poll_async(stream_id, &out_status) -> c_int` | Pending/Ready/Done/Cancelled/Error. |
| `odbc_stream_fetch(stream_id, buf, buf_len, &out_written, &has_more) -> c_int` | Lê próximo chunk. |
| `odbc_stream_cancel(stream_id) -> c_int` | Cancelamento cooperativo. |
| `odbc_stream_close(stream_id) -> c_int` | Libera worker e arquivos spill. |

### 1.17 Catálogo (6)

| Função | Propósito |
|---|---|
| `odbc_catalog_tables(conn_id, ...) -> c_int` | `SQLTables`. |
| `odbc_catalog_columns(conn_id, table, ...) -> c_int` | `SQLColumns`. |
| `odbc_catalog_type_info(conn_id, ...) -> c_int` | `SQLGetTypeInfo`. |
| `odbc_catalog_primary_keys(conn_id, ...) -> c_int` | `SQLPrimaryKeys`. |
| `odbc_catalog_foreign_keys(conn_id, ...) -> c_int` | `SQLForeignKeys`. |
| `odbc_catalog_indexes(conn_id, ...) -> c_int` | `SQLStatistics`. |

### 1.18 Bulk insert (2)

| Função | Propósito |
|---|---|
| `odbc_bulk_insert_array(conn_id, table, payload, ...) -> c_int` | Array binding (`SQL_ATTR_PARAMSET_SIZE`). |
| `odbc_bulk_insert_parallel(pool_id, payload, parallelism, ...) -> c_int` | rayon + N conexões com `BulkPartialFailure` estruturado. |

### 1.19 Columnar decompress (2)

| Função | Propósito |
|---|---|
| `odbc_columnar_decompress(algo, in_ptr, in_len, out, out_len, out_cap) -> c_int` | Descomprime coluna (zstd=1, lz4=2) retornando buffer alocado pelo Rust. |
| `odbc_columnar_decompress_free(p, len, cap)` | Libera buffer retornado por `odbc_columnar_decompress`. |

### 1.20 Telemetria OpenTelemetry (6)

| Função | Propósito |
|---|---|
| `otel_init(endpoint, attrs, ...) -> i32` | Inicializa exporter (OTLP HTTP ou Console). |
| `otel_export_trace(trace_json, len) -> i32` | Envia spans em JSON. |
| `otel_export_trace_to_string(buf, len) -> i32` | Snapshot string para teste. |
| `otel_get_last_error(buf, len) -> i32` | Último erro do exporter. |
| `otel_cleanup_strings()` | No-op para compatibilidade ABI. |
| `otel_shutdown()` | Flush + drop do exporter. |

---

## 2. API Rust pública (rlib)

Reexportada por `lib.rs` (crate-root re-exports):

```rust
pub use engine::{
    execute_multi_result, execute_query_with_connection, execute_query_with_params,
    OdbcConnection, OdbcEnvironment,
};
pub use error::{OdbcError, Result, StructuredError};
pub use protocol::{
    decode_multi, deserialize_params, encode_multi, serialize_params,
    BinaryProtocolDecoder, ColumnInfo, DecodedResult, MultiResultItem, ParamValue,
};
// Gated features:
// #[cfg(feature = "columnar-v2")]  pub use protocol::columnar_v2;
// #[cfg(feature = "ffi-tests")]    pub use ffi::{ odbc_connect, odbc_init, ... };
```

Os demais módulos (`engine`, `plugins`, `pool`, `protocol`, `security`, `observability`, `versioning`) são públicos mas acessados como `odbc_engine::module::Item`.

### 2.1 `engine::` — núcleo de execução

| Item | Tipo | Descrição |
|---|---|---|
| `OdbcEnvironment` | struct | Ambiente ODBC singleton (Box::leak). |
| `OdbcConnection` | struct | Wrapper de `Connection<'static>` com lifecycle gerenciado. |
| `Transaction`, `IsolationLevel`, `SavepointDialect`, `TransactionState` | structs/enums | Transações com isolamento + dialeto. |
| `LockTimeout` | struct | Typed wrapper para lock timeout por transação (v3.4+). |
| `Savepoint` | struct | Savepoint nominal validado via `quote_identifier`. |
| `StatementHandle` | struct | Wrapper de prepared statement com TTL. |
| `StreamingExecutor`, `StreamState`, `BatchedStreamingState`, `AsyncStreamingState`, `StreamingState`, `AsyncStreamStatus` | streaming | Três modos: sync buffer, batched (mpsc), async batched (Tokio). |
| `list_tables`, `list_columns`, `list_primary_keys`, `list_foreign_keys`, `list_indexes`, `get_type_info` | fn | Catálogo high-level. |
| `execute_multi_result`, `execute_query_with_connection`, `execute_query_with_params`, `execute_query_with_params_and_timeout`, `execute_query_with_cached_connection`, `get_global_metrics` | fn | Helpers de query. |

### 2.2 `engine::core::` — engines e adapters internos

| Item | Descrição |
|---|---|
| `ExecutionEngine` | Engine de query com `SpanGuard`, prepared cache, plugin dispatch. |
| `ConnectionManager` | Gerencia ciclo de vida de `CachedConnection`. |
| `BatchExecutor`, `BatchParam`, `BatchQuery` | Execução em lote. |
| `ArrayBinding` | Bulk INSERT via `SQL_ATTR_PARAMSET_SIZE` com identifiers quotados. |
| `BulkCopyExecutor`, `BulkCopyFormat` | SQL Server BCP wrapper (feature `sqlserver-bcp`). |
| `ParallelBulkInsert` (`ParallelMode::{Independent, PerChunkTransactional}`) | rayon + chunked insert. |
| `QueryPipeline`, `QueryPlan` | DAG simples para encadear operações. |
| `MemoryEngine` | Buffer pool com quota global. |
| `MetadataCache`, `TableSchema`, `ColumnMetadata` | LRU+TTL de schemas. |
| `PreparedStatementCache`, `PreparedStatementMetrics` | Cache de SQL strings. |
| `DiskSpillStream`, `DiskSpillWriter`, `SpillReadSource` | Spill em disco com Drop seguro. |
| `DriverCapabilities` | Capacidades por engine. |
| `ProtocolEngine`, `ProtocolVersion` | Selector de protocolo wire. |
| `SecurityLayer`, `SecureBuffer` | Camada de segurança. |

### 2.3 `engine::identifier::` — validação e quoting

| Item | Descrição |
|---|---|
| `validate_identifier(name) -> Result<()>` | Whitelist `[A-Za-z_][A-Za-z0-9_]{0,127}`. |
| `quote_identifier(name, style)` | Quoting per-DB (`""`, `[]`, `` ` ``). |
| `quote_identifier_default(name)` | Atalho SQL-92 com `""`. |
| `quote_qualified_default(qualified)` | `schema.table` → `"schema"."table"`. |
| `IdentifierQuoting::{DoubleQuote, Brackets, Backtick}` | Estilo de quoting. |
| `MAX_IDENTIFIER_LEN = 128` | Limite conservador. |

### 2.4 `error::` — sistema de erros estruturados

```rust
pub enum OdbcError {
    OdbcApi(String),
    InvalidHandle(u32),
    EmptyConnectionString,
    EnvironmentNotInitialized,
    Structured { sqlstate: [u8; 5], native_code: i32, message: String },
    PoolError(String),
    InternalError(String),
    ValidationError(String),
    UnsupportedFeature(String),
    NoMoreResults,
    MalformedPayload(String),
    RollbackFailed(String),
    ResourceLimitReached(String),
    Cancelled,
    WorkerCrashed(String),
    BulkPartialFailure { rows_inserted_before_failure, failed_chunks, detail },
}

pub enum ErrorCategory { Transient, Fatal, Validation, ConnectionLost }
```

Métodos: `sqlstate()`, `native_code()`, `message()`, `is_retryable()`,
`is_connection_error()`, `error_category()`, `to_structured()`.

### 2.5 `protocol::` — codecs binários

| Item | Descrição |
|---|---|
| `RowBuffer`, `ColumnMetadata` | Buffer linha-orientado. |
| `RowBufferV2`, `ColumnBlock`, `ColumnData`, `CompressionType` | Buffer columnar v2 com compressão. |
| `RowBufferEncoder`, `ColumnarEncoder` | Encoders para os dois formatos. |
| `BinaryProtocolDecoder`, `DecodedResult`, `ColumnInfo` | Decoder do formato wire. |
| `compress`, `decompress` | Zstd/Lz4. |
| `Arena` | Bump allocator para hot path. |
| `row_buffer_to_columnar` | Converte row → columnar com bind binário. |
| `MultiResultItem`, `encode_multi`, `decode_multi` | Multi-resultset. |
| `OdbcType` | Enum com 19 variantes, mapeamento SQL ↔ Rust (discriminantes 1–19 estáveis). |
| `BulkInsertPayload`, `BulkColumnSpec`, `BulkColumnData`, `BulkColumnType`, `BulkTimestamp` | Payload de bulk insert. |
| `parse_bulk_insert_payload`, `serialize_bulk_insert_payload` | Round-trip com caps `MAX_BULK_*`. |
| `null_bitmap_size`, `is_null`, `is_null_strict` | Bitmap helpers. |
| `ParamValue`, `serialize_params`, `deserialize_params`, `param_values_to_strings` | Sistema de parâmetros (v0). |

### 2.6 `pool::` — connection pool

| Item | Descrição |
|---|---|
| `ConnectionPool` | Wrapper r2d2 com `PoolAutocommitCustomizer`. |
| `PoolOptions` | `{idle_timeout, max_lifetime, connection_timeout}`. |
| `PooledConnectionWrapper` | Acessores `get_connection`/`get_connection_mut`. |

### 2.7 `plugins::` — sistema de drivers

| Item | Descrição |
|---|---|
| `DriverPlugin` (trait) | `name`, `get_capabilities`, `map_type`, `optimize_query`, `get_optimization_rules`. |
| `DriverCapabilities` | `{prepared, batch, streaming, array_fetch, max_row_array_size, name, version}`. |
| `OptimizationRule::*` | Hints de otimização por engine. |
| `PluginRegistry` | Registro thread-safe com `is_supported()` e `plugin_id_for_dbms_name()`. |
| Implementações | `SqlServerPlugin`, `OraclePlugin`, `PostgresPlugin`, `MySqlPlugin`, `MariaDbPlugin`, `SybasePlugin`, `SqlitePlugin`, `Db2Plugin`, `SnowflakePlugin` (9 plugins). |

### 2.8 `security::` — secrets & sanitização

| Item | Descrição |
|---|---|
| `Secret`, `SecretManager` | Storage zerável; `with_secret()`. |
| `SecureBuffer` | Buffer zerável; `with_bytes()`. |
| `AuditLogger` | Eventos in-memory com truncagem. |
| `sanitize_connection_string` | Respeita `{...}`, 14 chaves secretas. |

### 2.9 `observability::` — métricas, traces, logs

| Item | Descrição |
|---|---|
| `Metrics`, `QueryMetrics`, `PoolMetrics` | Contadores e histograma fixo (1 000 amostras). |
| `Tracer`, `QuerySpan` | Spans por query com metadata. |
| `SpanGuard` | RAII para evitar leak em error paths. |
| `StructuredLogger` | Logger com sanitização de SQL. |
| `sanitize_sql_for_log` | Mascara literais; opt-out via `ODBC_FAST_LOG_RAW_SQL=1`. |

### 2.10 `observability::telemetry::` — OpenTelemetry

| Item | Descrição |
|---|---|
| `ConsoleExporter` | Exporter para stdout. |
| `OtlpExporter` | Exporter HTTP OTLP (feature `observability`). |
| `TelemetryExporter` (trait) | Interface comum. |
| FFI: `otel_init` … `otel_shutdown` | Bindings OpenTelemetry (ver §1.20). |

### 2.11 `versioning::` — protocolo & ABI

| Item | Descrição |
|---|---|
| `ApiVersion::current()` | Lê `env!("CARGO_PKG_VERSION")`. |
| `AbiVersion::current()` | ABI estável (1.0). |
| `ProtocolVersion::current()` | Wire format (V2). |
| Métodos | `is_compatible_with`, `is_breaking_change`. |

### 2.12 `ffi::guard::` — wrappers de segurança FFI

| Item | Descrição |
|---|---|
| `call_int<F>`, `call_id<F, U>`, `call_ptr<F, T>`, `call_size<F>` | Wrappers `catch_unwind` para os tipos de retorno. |
| `FfiError` (`#[repr(i32)]`) | Códigos negativos: `NullPointer (-1)` … `Cancelled (-9)`, `Generic (-100)`. |
| `ffi_guard_int!`, `ffi_guard_id!`, `ffi_guard_ptr!` | Açúcar sintático. |

---

## 3. Capacidades por feature flag (`Cargo.toml`)

| Feature | Default | Adiciona |
|---|---|---|
| `observability` | ✓ | `OtlpExporter` (HTTP via `ureq`). |
| `test-helpers` | ✓ | `load_dotenv()` para carregar `.env` em testes. |
| `sqlserver-bcp` | ✗ | `BulkCopyExecutor` (Windows + DLL `bcp.dll`). |
| `statement-handle-reuse` | ✗ | LRU de `Prepared<'static>` (usa `transmute` — experimental). |
| `ffi-tests` | ✗ | Habilita `tests/ffi_compatibility_test.rs` e expõe FFI no `lib`. |
| `xa-dtc` | ✗ | XA / 2PC no SQL Server via MSDTC (Windows-only, COM + `windows` crate). |
| `xa-oci` | ✗ | XA / 2PC no Oracle via `libclntsh` / `oci.dll` (carregado dinamicamente). |
| `columnar-v2` | ✗ | Constantes de protocolo columnar v2 e bench de referência. |

---

## 4. Mapeamento Dart ↔ FFI (resumo)

O package Dart `odbc_fast` consome a ABI C via `dart:ffi`. Os helpers de mais alto nível em Dart cobrem:

| Capacidade Rust FFI | Helper Dart típico |
|---|---|
| `odbc_connect*` / `odbc_disconnect` | `OdbcConnection` |
| `odbc_pool_*` | `OdbcConnectionPool` |
| `odbc_transaction_*` / `odbc_savepoint_*` | `OdbcTransaction`, `Savepoint`, `TransactionHandle` |
| `odbc_xa_*` | `XaTransactionHandle` |
| `odbc_exec_query*` / `odbc_exec_query_multi*` | `query()`, `queryMulti()`, `executeQueryDirectedParams()` |
| `odbc_execute_async`, `odbc_async_*` | `Future<Result>` |
| `odbc_stream_*` | `Stream<Row>` chunked, `streamQueryMulti()` |
| `odbc_bulk_insert_*` | `bulkInsert()`, `bulkInsertParallel()` |
| `odbc_catalog_*` | `Catalog` API |
| `odbc_build_upsert_sql` / `odbc_append_returning_sql` / `odbc_get_session_init_sql` | `OdbcDriverFeatures` |
| `otel_*` | OpenTelemetry export bridge |
| `odbc_columnar_decompress*` | `columnarDecompressWithNative()` |

---

## 5. Itens NÃO expostos (intencionalmente internos)

- `engine::core::sqlserver_bcp` — só compilado em Windows + feature `sqlserver-bcp`.
- `handles::CachedConnection` — interno do pool.
- `async_bridge` — runtime Tokio compartilhado.
- `ffi::guard::*` (call_*) — APIs internas para implementar `extern "C"`.
- `engine::core::pipeline::QueryPipeline` — DAG em desenvolvimento.
- `engine::core::memory_engine::MemoryEngine` — buffer pool interno.

---

## 6. Estatísticas

| Categoria | Quantidade |
|---|---|
| FFI `extern "C"` total | **92** |
| — em `ffi/mod.rs` | 84 |
| — em `ffi/columnar_decompress.rs` | 2 |
| — em `observability/telemetry/mod.rs` | 6 |
| Módulos públicos | 9 (`engine`, `error`, `ffi`, `observability`, `plugins`, `pool`, `protocol`, `security`, `versioning`) |
| Plugins de driver implementados | 9 (`sqlserver`, `postgres`, `mysql`, `mariadb`, `oracle`, `sybase`, `sqlite`, `db2`, `snowflake`) |
| Variantes de `OdbcError` | 16 |
| Modos de streaming | 5 (sync buffer, batched mpsc, async Tokio, multi batched, multi async) |
| Modos de bulk insert | 4 (`ArrayBinding`, `BulkCopy` BCP, `ParallelBulkInsert::Independent`, `ParallelBulkInsert::PerChunkTransactional`) |
| Códigos `FfiError` | 10 |
| Feature flags | 8 (`observability`, `test-helpers`, `sqlserver-bcp`, `statement-handle-reuse`, `ffi-tests`, `xa-dtc`, `xa-oci`, `columnar-v2`) |
| `OdbcType` variantes | 19 (discriminantes 1–19 estáveis) |
| `SqlDataType` kinds (Dart) | 27 implementados |

---

## 7. Suplemento Dart / protocolo

| Área | Arquivo(s) |
|---|---|
| 27 kinds `SqlDataType` + `intervalYearToMonth` / `geometry` | `lib/infrastructure/native/protocol/param_value.dart` |
| `ParamDirection` | `lib/domain/types/param_direction.dart` |
| `DirectedParam` / `serializeDirectedParams` (DRT1) | `lib/infrastructure/native/protocol/directed_param.dart` |
| Flags columnar v2 (detecção de cabeçalho) | `lib/infrastructure/native/protocol/columnar_v2_flags.dart` |
| `OdbcDriverFeatures` (upsert/returning/session init) | `lib/infrastructure/native/driver_capabilities_v3.dart` |
| `XaTransactionHandle` | `lib/infrastructure/native/wrappers/xa_transaction_handle.dart` |

---

*Atualizado para v3.5.3. Para cada funcionalidade com "fix" há um teste de regressão correspondente em `native/odbc_engine/tests/regression/`.*
