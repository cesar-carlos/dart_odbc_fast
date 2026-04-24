import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/xa_transaction_handle.dart';
import 'package:result_dart/result_dart.dart';

/// Interface for ODBC service operations.
///
/// Allows decorators and alternative implementations to be used
/// interchangeably via dependency injection.
abstract class IOdbcService {
  Future<Result<void>> initialize();

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  });

  Future<Result<void>> disconnect(String connectionId);

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  );

  /// Like [executeQueryParams] for `OUT` / `INOUT` (DRT1 on the wire).
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  );

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  );

  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  });

  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  );

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
  ///     final r1 = await service.executeQueryParams(
  ///       connId, 'INSERT INTO logs(msg) VALUES (?)', ['hi'],
  ///     );
  ///     if (r1.isError()) return Failure(r1.exceptionOrNull()!);
  ///     return const Success(42);
  ///   },
  ///   accessMode: TransactionAccessMode.readWrite,
  /// );
  /// ```
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
  /// [action] returning [Failure] triggers best-effort rollback; thrown
  /// exceptions are converted to [QueryError] and also roll back, matching
  /// [runInTransaction].
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

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
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
  /// Up to 5 positional `?` parameters are supported. New in v3.2.0.
  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  );

  /// Streams a multi-result batch one item at a time. New in v3.3.0 (M8).
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
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

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  });

  Future<Result<Connection>> poolGetConnection(int poolId);

  Future<Result<void>> poolReleaseConnection(String connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<PoolState>> poolGetState(int poolId);

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId);

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize);

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

  Future<Result<OdbcMetrics>> getMetrics();

  bool isInitialized();

  Future<Result<void>> clearStatementCache();

  Future<Result<void>> clearAllStatements();

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics();

  Future<Result<Map<String, String>>> getVersion();

  Future<Result<void>> validateConnectionString(String connectionString);

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  );

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

  Future<Result<QueryResult>> executeQuery(
    String sql, {
    List<dynamic>? params,
    String? connectionId,
  });

  void dispose();
}

/// High-level ODBC service that provides simplified API for database
/// operations.
///
/// This service wraps [IOdbcRepository] to provide a more convenient
/// interface for common database operations.
///
/// ## Usage
/// ```dart
/// final service = OdbcService(repository);
/// await service.initialize();
/// final result = await service.executeQuery(
///   'SELECT * FROM users',
///   connectionId: connection.id,
/// );
/// ```
class OdbcService implements IOdbcService {
  /// Creates a new [OdbcService] instance.
  ///
  /// The `repository` parameter provides the ODBC repository implementation.
  OdbcService(this._repository);
  final IOdbcRepository _repository;

  @override
  Future<Result<void>> initialize() async {
    return _repository.initialize();
  }

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    return _repository.connect(connectionString, options: options);
  }

  @override
  Future<Result<void>> disconnect(String connectionId) async {
    return _repository.disconnect(connectionId);
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    return _repository.executeQueryParams(
      connectionId,
      sql,
      params,
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) async {
    return _repository.executeQueryParamBuffer(
      connectionId,
      sql,
      serializeDirectedParams(params),
    );
  }

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  ) {
    return _repository.streamQuery(connectionId, sql);
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) async {
    return _repository.beginTransaction(
      connectionId,
      isolationLevel ?? IsolationLevel.readCommitted,
      savepointDialect: savepointDialect ?? SavepointDialect.auto,
      accessMode: accessMode ?? TransactionAccessMode.readWrite,
      lockTimeout: lockTimeout,
    );
  }

  @override
  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  ) async {
    return _repository.commitTransaction(connectionId, txnId);
  }

  @override
  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    return _repository.rollbackTransaction(connectionId, txnId);
  }

  @override
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) async {
    final beginResult = await beginTransaction(
      connectionId,
      isolationLevel: isolationLevel,
      savepointDialect: savepointDialect,
      accessMode: accessMode,
      lockTimeout: lockTimeout,
    );
    // Early-out when we couldn't even open the transaction. The wire
    // format guarantees the failure carries an OdbcError, so we just
    // forward it untouched.
    if (beginResult.isError()) {
      return Failure(beginResult.exceptionOrNull()!);
    }
    final txnId = beginResult.getOrNull()!;

    Result<T> userResult;
    try {
      userResult = await action(txnId);
    } on Object catch (e, st) {
      // The whole point of the helper is to catch *any* throw the user
      // emits and convert it into a Failure + rollback. Typed catches
      // would defeat the contract — exceptions must never escape
      // `runInTransaction`.
      await _safelyRollback(connectionId, txnId);
      return Failure(
        QueryError(
          message: 'runInTransaction: action threw ${e.runtimeType}: $e\n$st',
        ),
      );
    }

    if (userResult.isError()) {
      // The action returned a Failure. Roll back, then propagate the
      // original error verbatim so the caller's diagnostics aren't
      // muddied by transaction bookkeeping.
      await _safelyRollback(connectionId, txnId);
      return userResult;
    }

    final commitResult = await commitTransaction(connectionId, txnId);
    if (commitResult.isError()) {
      // Commit failed *after* the action succeeded. By driver contract
      // the engine has rolled back (or is in an undefined state, which
      // we model as rolled back). Surface the commit failure so the
      // caller knows the unit of work didn't actually persist.
      return Failure(commitResult.exceptionOrNull()!);
    }
    return userResult;
  }

  @override
  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) async {
    final startResult = await _repository.xaStart(connectionId, xid);
    if (startResult.isError()) {
      return Failure(startResult.exceptionOrNull()!);
    }
    final xa = startResult.getOrNull()!;

    if (onePhase) {
      try {
        final userResult = await action(xa);
        if (userResult.isError()) {
          await _xaSafelyAbort(xa);
          return userResult;
        }
        if (!xa.commitOnePhase()) {
          return Failure(
            QueryError(
              message: 'runInXaTransaction: xa_commit_one_phase failed '
                  'on xid=${xa.xid}',
            ),
          );
        }
        return userResult;
      } on Object catch (e, st) {
        await _xaSafelyAbort(xa);
        return Failure(
          QueryError(
            message: 'runInXaTransaction: action threw ${e.runtimeType}: '
                '$e\n$st',
          ),
        );
      }
    }

    try {
      final userResult = await action(xa);
      if (userResult.isError()) {
        await _xaSafelyAbort(xa);
        return userResult;
      }
      if (!xa.end()) {
        return Failure(
          QueryError(
            message: 'runInXaTransaction: xa_end failed on xid=${xa.xid}',
          ),
        );
      }
      if (!xa.prepare()) {
        return Failure(
          QueryError(
            message: 'runInXaTransaction: xa_prepare failed on xid=${xa.xid}',
          ),
        );
      }
      if (!xa.commitPrepared()) {
        return Failure(
          QueryError(
            message: 'runInXaTransaction: xa_commit_prepared failed '
                'on xid=${xa.xid}',
          ),
        );
      }
      return userResult;
    } on Object catch (e, st) {
      await _xaSafelyAbort(xa);
      return Failure(
        QueryError(
          message: 'runInXaTransaction: action threw ${e.runtimeType}: '
              '$e\n$st',
        ),
      );
    }
  }

  /// Best-effort XA cleanup after failure; mirrors
  /// [XaTransactionHandle.runWithStart].
  Future<void> _xaSafelyAbort(XaTransactionHandle xa) async {
    try {
      if (xa.state == XaState.active) {
        xa.end();
      }
      if (xa.state == XaState.prepared) {
        xa.rollbackPrepared();
      } else if (xa.state == XaState.idle || xa.state == XaState.failed) {
        xa.rollback();
      }
    } on Object catch (_) {
      // Same rationale as [runInTransaction] rollback swallow.
    }
  }

  /// Rolls back [txnId] without surfacing the rollback's own failure to
  /// the caller. The underlying repository already logs structured
  /// errors on rollback failure (see Transaction::rollback in Rust);
  /// we don't want a noisy rollback error to overwrite the original
  /// problem the user is debugging.
  Future<void> _safelyRollback(String connectionId, int txnId) async {
    try {
      await rollbackTransaction(connectionId, txnId);
    } on Object catch (_) {
      // Defensive: any throw from the rollback path is logged elsewhere
      // by the underlying repository and intentionally not re-raised
      // here. See the method doc for the rationale.
    }
  }

  @override
  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _repository.createSavepoint(connectionId, txnId, name);
  }

  @override
  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _repository.rollbackToSavepoint(
      connectionId,
      txnId,
      name,
    );
  }

  @override
  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _repository.releaseSavepoint(connectionId, txnId, name);
  }

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return _repository.prepare(
      connectionId,
      sql,
      timeoutMs: timeoutMs,
    );
  }

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return _repository.prepareNamed(
      connectionId,
      sql,
      timeoutMs: timeoutMs,
    );
  }

  @override
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) async {
    return _repository.executePrepared(
      connectionId,
      stmtId,
      params,
      options,
    );
  }

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    return _repository.executePreparedNamed(
      connectionId,
      stmtId,
      namedParams,
      options,
    );
  }

  @override
  Future<Result<void>> closeStatement(
    String connectionId,
    int stmtId,
  ) async {
    return _repository.closeStatement(connectionId, stmtId);
  }

  @override
  Future<Result<void>> cancelStatement(
    String connectionId,
    int stmtId,
  ) async {
    return _repository.cancelStatement(connectionId, stmtId);
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    return _repository.executeQueryMulti(connectionId, sql);
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    return _repository.executeQueryMultiFull(connectionId, sql);
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    return _repository.executeQueryMultiParams(connectionId, sql, params);
  }

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) {
    return _repository.streamQueryMulti(connectionId, sql);
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    return _repository.executeQueryNamed(connectionId, sql, namedParams);
  }

  @override
  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) async {
    return _repository.catalogTables(
      connectionId,
      catalog: catalog,
      schema: schema,
    );
  }

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    return _repository.catalogColumns(connectionId, table);
  }

  @override
  Future<Result<QueryResult>> catalogTypeInfo(
    String connectionId,
  ) async {
    return _repository.catalogTypeInfo(connectionId);
  }

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) async {
    return _repository.catalogPrimaryKeys(connectionId, table);
  }

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) async {
    return _repository.catalogForeignKeys(connectionId, table);
  }

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) async {
    return _repository.catalogIndexes(connectionId, table);
  }

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) async {
    return _repository.poolCreate(
      connectionString,
      maxSize,
      options: options,
    );
  }

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) async {
    return _repository.poolGetConnection(poolId);
  }

  @override
  Future<Result<void>> poolReleaseConnection(
    String connectionId,
  ) async {
    return _repository.poolReleaseConnection(connectionId);
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    return _repository.poolHealthCheck(poolId);
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    return _repository.poolGetState(poolId);
  }

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) async {
    return _repository.poolGetStateDetailed(poolId);
  }

  @override
  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) async {
    return _repository.poolSetSize(poolId, newMaxSize);
  }

  @override
  Future<Result<void>> poolClose(int poolId) async {
    return _repository.poolClose(poolId);
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    return _repository.bulkInsert(
      connectionId,
      table,
      columns,
      dataBuffer,
      rowCount,
    );
  }

  @override
  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) async {
    return _repository.bulkInsertParallel(
      poolId,
      table,
      columns,
      dataBuffer,
      rowCount,
      parallelism: parallelism,
    );
  }

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    return _repository.getMetrics();
  }

  @override
  bool isInitialized() {
    return _repository.isInitialized();
  }

  @override
  Future<Result<void>> clearStatementCache() async {
    return _repository.clearStatementCache();
  }

  @override
  Future<Result<void>> clearAllStatements() async {
    return _repository.clearAllStatements();
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    return _repository.getPreparedStatementsMetrics();
  }

  @override
  Future<Result<Map<String, String>>> getVersion() async {
    return _repository.getVersion();
  }

  @override
  Future<Result<void>> validateConnectionString(String connectionString) async {
    return _repository.validateConnectionString(connectionString);
  }

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) async {
    return _repository.getDriverCapabilities(connectionString);
  }

  @override
  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) async {
    return _repository.getConnectionDbmsInfo(connectionId);
  }

  @override
  Future<Result<void>> setLogLevel(int level) async {
    return _repository.setLogLevel(level);
  }

  @override
  Future<Result<void>> setAuditEnabled({required bool enabled}) async {
    return _repository.setAuditEnabled(enabled: enabled);
  }

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() async {
    return _repository.getAuditStatus();
  }

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) async {
    return _repository.getAuditEvents(limit: limit);
  }

  @override
  Future<Result<void>> clearAuditEvents() async {
    return _repository.clearAuditEvents();
  }

  @override
  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    return _repository.metadataCacheEnable(
      maxEntries: maxEntries,
      ttlSeconds: ttlSeconds,
    );
  }

  @override
  Future<Result<Map<String, Object?>>> metadataCacheStats() async {
    return _repository.metadataCacheStats();
  }

  @override
  Future<Result<void>> clearMetadataCache() async {
    return _repository.clearMetadataCache();
  }

  @override
  Future<Result<void>> cancelStream(int streamId) async {
    return _repository.cancelStream(streamId);
  }

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) async {
    return _repository.executeAsyncStart(connectionId, sql);
  }

  @override
  Future<Result<int>> asyncPoll(int requestId) async {
    return _repository.asyncPoll(requestId);
  }

  @override
  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) async {
    return _repository.asyncGetResult(
      requestId,
      maxBufferBytes: maxBufferBytes,
    );
  }

  @override
  Future<Result<void>> asyncCancel(int requestId) async {
    return _repository.asyncCancel(requestId);
  }

  @override
  Future<Result<void>> asyncFree(int requestId) async {
    return _repository.asyncFree(requestId);
  }

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    return _repository.streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
  }

  @override
  Future<Result<int>> streamPollAsync(int streamId) async {
    return _repository.streamPollAsync(streamId);
  }

  @override
  Future<String?> detectDriver(String connectionString) async {
    return _repository.detectDriver(connectionString);
  }

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    List<dynamic>? params,
    String? connectionId,
  }) async {
    if (connectionId == null || connectionId.isEmpty) {
      throw const ConnectionError(
        message: 'No active connection. Call connect() first.',
      );
    }

    if (params == null || params.isEmpty) {
      return executeQueryParams(connectionId, sql, []);
    }

    return executeQueryParams(connectionId, sql, params);
  }

  @override
  void dispose() {}
}
