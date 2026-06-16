import 'package:meta/meta.dart';
import 'package:odbc_fast/application/services/i_admin_service.dart';
import 'package:odbc_fast/application/services/i_pool_service.dart';
import 'package:odbc_fast/application/services/i_query_service.dart';
import 'package:odbc_fast/application/services/i_transaction_service.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';

/// Interface for ODBC service operations.
///
/// Allows decorators and alternative implementations to be used
/// interchangeably via dependency injection.
///
/// Aggregates four narrower sub-interfaces:
///
/// - [IQueryService] — query / stream operations.
/// - [ITransactionService] — local 2PC + XA lifecycle.
/// - [IPoolService] — connection pool management.
/// - [IAdminService] — initialization, metrics, capabilities.
///
/// New consumers are encouraged to depend on the narrowest sub-interface
/// they need (Interface Segregation Principle). Existing code that types
/// against `IOdbcService` keeps working unchanged because every member
/// stays declared at the aggregate level.
abstract class IOdbcService
    implements IQueryService, ITransactionService, IPoolService, IAdminService {
  @override
  Future<Result<void>> initialize();

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  });

  @override
  Future<Result<void>> disconnect(String connectionId);

  /// Typed positional parameters via [ParamValue] wire tags.
  ///
  /// Same FFI path as positional `executeQueryParams`; avoids
  /// `List<dynamic>` at call sites while preserving the untyped API.
  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  });

  /// Like positional `executeQueryParams` for `OUT` / `INOUT` (DRT1 on the wire).
  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  );

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  );

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  });

  @override
  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  );

  @override
  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  );

  /// Runs [action] inside a transaction with automatic commit on success
  /// and rollback on any failure (returned `Failure` or thrown exception).
  ///
  /// Sprint 4.4 — ergonomic helper that captures the begin/commit/rollback
  /// dance behind a single call so application code never has to manage
  /// the `txnId` lifecycle by hand.
  ///
  /// - `action` receives the live `txnId` and returns a `Result<T>`.
  ///   Returning `Success(value)` triggers `commitTransaction`; returning
  ///   `Failure(error)` triggers `rollbackTransaction` and the original
  ///   error is propagated.
  /// - When [action] throws, the transaction is rolled back and the
  ///   exception is converted to a `QueryError`. The original exception
  ///   is preserved in the error message for diagnostics.
  /// - When the rollback itself fails, the original error wins; the
  ///   rollback failure is logged via the underlying repository (which
  ///   already does this in [rollbackTransaction]).
  /// - Default isolation is `IsolationLevel.readCommitted`,
  ///   default dialect is `SavepointDialect.auto`, default access mode
  ///   is `TransactionAccessMode.readWrite` — same defaults as
  ///   [beginTransaction].
  ///
  /// Example:
  /// ```dart
  /// final result = await service.runInTransaction<int>(
  ///   connId,
  ///   (txnId) async {
  ///     final r1 = await service.executeQueryParamValues(
  ///       connId,
  ///       'INSERT INTO logs(msg) VALUES (?)',
  ///       [ParamValueString('hi')],
  ///     );
  ///     if (r1.isError()) return Failure(r1.exceptionOrNull()!);
  ///     return const Success(42);
  ///   },
  ///   accessMode: TransactionAccessMode.readWrite,
  /// );
  /// ```
  @override
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  });

  /// Runs [action] inside a distributed XA / 2PC branch on [connectionId].
  ///
  /// Two-phase (default): `xa_start` → [action] → `xa_end` → `xa_prepare` →
  /// `xa_commit_prepared`. Set [onePhase] to use `xa_commit_one_phase` after
  /// [action] instead (single-RM shortcut only).
  ///
  /// `action` returning `Failure` triggers best-effort rollback; thrown
  /// exceptions are converted to `QueryError` and also roll back, matching
  /// `runInTransaction`.
  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  });

  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  );

  Future<Result<void>> closeStatement(
    String connectionId,
    int stmtId,
  );

  /// Requests cancellation of an in-flight prepared statement.
  ///
  /// {@template odbc_fast.cancel_statement_experimental}
  /// **Experimental:** native statement cancellation is not fully implemented
  /// in the Rust engine. The call may return [UnsupportedFeatureError] on many
  /// drivers. For reliable query interruption, prefer
  /// [ConnectionOptions.queryTimeout], which maps to the driver's native
  /// `SQL_ATTR_QUERY_TIMEOUT` where supported.
  /// {@endtemplate}
  @experimental
  Future<Result<void>> cancelStatement(
    String connectionId,
    int stmtId,
  );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  );

  /// Executes a parameterised batch SQL and returns all multi-result items.
  ///
  /// Supports positional `?` parameters using the same wire format as
  /// [executeQueryMultiFull]. New in v3.2.0.
  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  );

  /// Streams a multi-result batch one item at a time. New in v3.3.0 (M8).
  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  );

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  /// Executes a named-parameter query and returns results as a stream.
  ///
  /// Supports `@name` and `:name` syntax. Because the parameterized execute
  /// path does not support incremental batched streaming at the FFI level, the
  /// result is buffered and yielded as a single [QueryResult] chunk. On
  /// failure, emits a single `Failure` item and closes the stream.
  @override
  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  @override
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  });

  /// Batched streaming with columnar v2 wire when supported
  /// (`odbc_stream_start_batched_options`).
  /// See [IQueryService.streamQueryColumnar] for semantics and fallbacks.
  @override
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  });

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId);

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  );

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  });

  @override
  Future<Result<Connection>> poolGetConnection(
    int poolId, {
    ConnectionOptions? options,
  });

  @override
  Future<Result<void>> poolReleaseConnection(String connectionId);

  @override
  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<PoolState>> poolGetState(int poolId);

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId);

  @override
  Future<Result<void>> poolSetSize(int poolId, int newMaxSize);

  @override
  Future<Result<void>> poolClose(int poolId);

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  );

  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  });

  @override
  Future<Result<OdbcMetrics>> getMetrics();

  bool isInitialized();

  Future<Result<void>> clearStatementCache();

  Future<Result<void>> clearAllStatements();

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics();

  Future<Result<Map<String, String>>> getVersion();

  @override
  Future<Result<void>> validateConnectionString(String connectionString);

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  );

  @override
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats();

  @override
  Stream<OdbcEvent> get events;

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId);

  Future<Result<void>> setLogLevel(int level);

  Future<Result<void>> setAuditEnabled({required bool enabled});

  Future<Result<Map<String, Object?>>> getAuditStatus();

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({int limit = 0});

  Future<Result<void>> clearAuditEvents();

  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  });

  Future<Result<Map<String, Object?>>> metadataCacheStats();

  Future<Result<void>> clearMetadataCache();

  Future<Result<void>> cancelStream(int streamId);

  Future<Result<int>> executeAsyncStart(String connectionId, String sql);

  Future<Result<int>> asyncPoll(int requestId);

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  });

  Future<Result<void>> asyncCancel(int requestId);

  Future<Result<void>> asyncFree(int requestId);

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  });

  Future<Result<int>> streamPollAsync(int streamId);

  Future<String?> detectDriver(String connectionString);

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  });

  void dispose();
}
