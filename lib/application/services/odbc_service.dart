import 'dart:async';

import 'package:odbc_fast/application/services/i_dialect_service.dart';
import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/odbc_admin_service.dart';
import 'package:odbc_fast/application/services/odbc_dialect_service.dart';
import 'package:odbc_fast/application/services/odbc_pool_service.dart';
import 'package:odbc_fast/application/services/odbc_query_service.dart';
import 'package:odbc_fast/application/services/odbc_transaction_service.dart';
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
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart'
    hide OdbcMetrics;
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';
import 'package:result_dart/result_dart.dart';

export 'package:odbc_fast/application/services/i_admin_service.dart';
export 'package:odbc_fast/application/services/i_dialect_service.dart';
export 'package:odbc_fast/application/services/i_odbc_service.dart';
export 'package:odbc_fast/application/services/i_pool_service.dart';
export 'package:odbc_fast/application/services/i_query_service.dart';
export 'package:odbc_fast/application/services/i_transaction_service.dart';

/// High-level ODBC service that provides simplified API for database
/// operations.
///
/// This service wraps [IOdbcRepository] to provide a more convenient
/// interface for common database operations. Implementation is split
/// across capability delegates ([OdbcQueryService], [OdbcPoolService],
/// [OdbcAdminService], [OdbcTransactionService]); this class is a thin
/// façade that forwards each call.
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
  OdbcService(
    IOdbcRepository repository, {
    IDialectService? dialect,
  })  : _admin = OdbcAdminService(repository),
        _query = OdbcQueryService(repository),
        _pool = OdbcPoolService(repository),
        _transaction = OdbcTransactionService(repository),
        _dialect = dialect ??
            OdbcDialectService(
              OdbcDriverFeatures(OdbcNative()),
            ),
        _repository = repository;

  final IOdbcRepository _repository;
  final OdbcAdminService _admin;
  final OdbcQueryService _query;
  final OdbcPoolService _pool;
  final OdbcTransactionService _transaction;
  final IDialectService _dialect;

  /// Closes the internal event bridge. Call from owners that explicitly
  /// dispose the service. Safe to call multiple times.
  Future<void> closeEvents() => _admin.closeEvents();

  @override
  Stream<OdbcEvent> get events => _admin.events;

  @override
  Future<Result<void>> initialize() =>
      OdbcErrorBoundary.runVoid('initialize', _admin.initialize);

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      OdbcErrorBoundary.run(
        'connect',
        () => _admin.connect(connectionString, options: options),
      );

  @override
  Future<Result<void>> disconnect(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'disconnect',
        () => _admin.disconnect(connectionId),
      );

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryParamValues',
        () => _query.executeQueryParamValues(
          connectionId,
          sql,
          params,
          resultEncoding: resultEncoding,
        ),
      );

  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryDirectedParams',
        () => _query.executeQueryDirectedParams(connectionId, sql, params),
      );

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQuery',
        () => _query.streamQuery(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'beginTransaction',
        () => _transaction.beginTransaction(
          connectionId,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  @override
  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      OdbcErrorBoundary.runVoid(
        'commitTransaction',
        () => _transaction.commitTransaction(connectionId, txnId),
      );

  @override
  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      OdbcErrorBoundary.runVoid(
        'rollbackTransaction',
        () => _transaction.rollbackTransaction(connectionId, txnId),
      );

  @override
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'runInTransaction',
        () => _transaction.runInTransaction(
          connectionId,
          action,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  @override
  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) =>
      OdbcErrorBoundary.run(
        'runInXaTransaction',
        () => _transaction.runInXaTransaction(
          connectionId,
          xid,
          action,
          onePhase: onePhase,
        ),
      );

  @override
  Future<Result<List<Xid>>> xaRecover(String connectionId) =>
      OdbcErrorBoundary.run(
        'xaRecover',
        () => _transaction.xaRecover(connectionId),
      );

  @override
  Future<Result<XaTransactionHandle>> xaResumePrepared(
    String connectionId,
    Xid xid,
  ) =>
      OdbcErrorBoundary.run(
        'xaResumePrepared',
        () => _transaction.xaResumePrepared(connectionId, xid),
      );

  @override
  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      OdbcErrorBoundary.runVoid(
        'createSavepoint',
        () => _transaction.createSavepoint(connectionId, txnId, name),
      );

  @override
  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      OdbcErrorBoundary.runVoid(
        'rollbackToSavepoint',
        () => _transaction.rollbackToSavepoint(connectionId, txnId, name),
      );

  @override
  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      OdbcErrorBoundary.runVoid(
        'releaseSavepoint',
        () => _transaction.releaseSavepoint(connectionId, txnId, name),
      );

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      OdbcErrorBoundary.run(
        'prepare',
        () => _query.prepare(connectionId, sql, timeoutMs: timeoutMs),
      );

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      OdbcErrorBoundary.run(
        'prepareNamed',
        () => _query.prepareNamed(connectionId, sql, timeoutMs: timeoutMs),
      );

  @override
  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executePreparedParamValues',
        () => _query.executePreparedParamValues(
          connectionId,
          stmtId,
          params,
          options,
          resultEncoding: resultEncoding,
        ),
      );

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      OdbcErrorBoundary.run(
        'executePreparedNamed',
        () => _query.executePreparedNamed(
          connectionId,
          stmtId,
          namedParams,
          options,
        ),
      );

  @override
  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      OdbcErrorBoundary.runVoid(
        'closeStatement',
        () => _query.closeStatement(connectionId, stmtId),
      );

  @override
  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      OdbcErrorBoundary.runVoid(
        'cancelStatement',
        () => _query.cancelStatement(connectionId, stmtId),
      );

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMulti',
        () => _query.executeQueryMulti(connectionId, sql),
      );

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiFull',
        () => _query.executeQueryMultiFull(connectionId, sql),
      );

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiParamValues',
        () => _query.executeQueryMultiParamValues(connectionId, sql, params),
      );

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMulti',
        () => _query.streamQueryMulti(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiParamValues',
        () => _query.streamQueryMultiParamValues(
          connectionId,
          sql,
          params,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatchesParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatchesParamValues',
        () => _query.streamQueryMultiBatchesParamValues(
          connectionId,
          sql,
          params,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatches(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatches',
        () => _query.streamQueryMultiBatches(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryNamed',
        () => _query.executeQueryNamed(connectionId, sql, namedParams),
      );

  @override
  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryNamed',
        () => _query.streamQueryNamed(
          connectionId,
          sql,
          namedParams,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryColumnarParamValues',
        () => _query.executeQueryColumnarParamValues(
          connectionId,
          sql,
          params: params,
        ),
      );

  @override
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryColumnar',
        () => _query.streamQueryColumnar(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      OdbcErrorBoundary.run(
        'catalogTables',
        () => _query.catalogTables(
          connectionId: connectionId,
          catalog: catalog,
          schema: schema,
        ),
      );

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogColumns',
        () => _query.catalogColumns(connectionId, table),
      );

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'catalogTypeInfo',
        () => _query.catalogTypeInfo(connectionId),
      );

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogPrimaryKeys',
        () => _query.catalogPrimaryKeys(connectionId, table),
      );

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogForeignKeys',
        () => _query.catalogForeignKeys(connectionId, table),
      );

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogIndexes',
        () => _query.catalogIndexes(connectionId, table),
      );

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  }) =>
      OdbcErrorBoundary.run(
        'poolCreate',
        () => _pool.poolCreate(
          connectionString,
          maxSize,
          options: options,
          connectionOptions: connectionOptions,
        ),
      );

  @override
  Future<Result<Connection>> poolGetConnection(
    int poolId, {
    ConnectionOptions? options,
  }) =>
      OdbcErrorBoundary.run(
        'poolGetConnection',
        () => _pool.poolGetConnection(poolId, options: options),
      );

  @override
  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'poolReleaseConnection',
        () => _pool.poolReleaseConnection(connectionId),
      );

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) => OdbcErrorBoundary.run(
        'poolHealthCheck',
        () => _pool.poolHealthCheck(poolId),
      );

  @override
  Future<Result<PoolState>> poolGetState(int poolId) =>
      OdbcErrorBoundary.run('poolGetState', () => _pool.poolGetState(poolId));

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      OdbcErrorBoundary.run(
        'poolGetStateDetailed',
        () => _pool.poolGetStateDetailed(poolId),
      );

  @override
  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      OdbcErrorBoundary.runVoid(
        'poolSetSize',
        () => _pool.poolSetSize(poolId, newMaxSize),
      );

  @override
  Future<Result<void>> poolClose(int poolId) =>
      OdbcErrorBoundary.runVoid('poolClose', () => _pool.poolClose(poolId));

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      OdbcErrorBoundary.run(
        'bulkInsert',
        () => _query.bulkInsert(
          connectionId,
          table,
          columns,
          dataBuffer,
          rowCount,
        ),
      );

  @override
  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) =>
      OdbcErrorBoundary.run(
        'bulkInsertParallel',
        () => _query.bulkInsertParallel(
          poolId,
          table,
          columns,
          dataBuffer,
          rowCount,
          parallelism: parallelism,
        ),
      );

  @override
  Future<Result<OdbcMetrics>> getMetrics() =>
      OdbcErrorBoundary.run('getMetrics', _admin.getMetrics);

  @override
  bool isInitialized() => _admin.isInitialized();

  @override
  Future<Result<void>> clearStatementCache() => OdbcErrorBoundary.runVoid(
        'clearStatementCache',
        _admin.clearStatementCache,
      );

  @override
  Future<Result<void>> clearAllStatements() => OdbcErrorBoundary.runVoid(
        'clearAllStatements',
        _admin.clearAllStatements,
      );

  @override
  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      OdbcErrorBoundary.run(
        'getPreparedStatementsMetrics',
        _admin.getPreparedStatementsMetrics,
      );

  @override
  Future<Result<Map<String, String>>> getVersion() =>
      OdbcErrorBoundary.run('getVersion', _admin.getVersion);

  @override
  Future<Result<void>> validateConnectionString(String connectionString) =>
      OdbcErrorBoundary.runVoid(
        'validateConnectionString',
        () => _admin.validateConnectionString(connectionString),
      );

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      OdbcErrorBoundary.run(
        'getDriverCapabilities',
        () => _admin.getDriverCapabilities(connectionString),
      );

  @override
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      _admin.getWorkerPoolStats();

  @override
  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'getConnectionDbmsInfo',
        () => _admin.getConnectionDbmsInfo(connectionId),
      );

  @override
  Future<Result<void>> setLogLevel(int level) =>
      OdbcErrorBoundary.runVoid('setLogLevel', () => _admin.setLogLevel(level));

  @override
  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      OdbcErrorBoundary.runVoid(
        'setAuditEnabled',
        () => _admin.setAuditEnabled(enabled: enabled),
      );

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      OdbcErrorBoundary.run('getAuditStatus', _admin.getAuditStatus);

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({int limit = 0}) =>
      OdbcErrorBoundary.run(
        'getAuditEvents',
        () => _admin.getAuditEvents(limit: limit),
      );

  @override
  Future<Result<void>> clearAuditEvents() => OdbcErrorBoundary.runVoid(
        'clearAuditEvents',
        _admin.clearAuditEvents,
      );

  @override
  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      OdbcErrorBoundary.runVoid(
        'metadataCacheEnable',
        () => _admin.metadataCacheEnable(
          maxEntries: maxEntries,
          ttlSeconds: ttlSeconds,
        ),
      );

  @override
  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      OdbcErrorBoundary.run(
        'metadataCacheStats',
        _admin.metadataCacheStats,
      );

  @override
  Future<Result<void>> clearMetadataCache() => OdbcErrorBoundary.runVoid(
        'clearMetadataCache',
        _admin.clearMetadataCache,
      );

  @override
  Future<Result<void>> cancelStream(int streamId) => OdbcErrorBoundary.runVoid(
        'cancelStream',
        () => _admin.cancelStream(streamId),
      );

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      OdbcErrorBoundary.run(
        'executeAsyncStart',
        () => _admin.executeAsyncStart(connectionId, sql),
      );

  @override
  Future<Result<int>> asyncPoll(int requestId) =>
      OdbcErrorBoundary.run('asyncPoll', () => _admin.asyncPoll(requestId));

  @override
  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      OdbcErrorBoundary.run(
        'asyncGetResult',
        () => _admin.asyncGetResult(requestId, maxBufferBytes: maxBufferBytes),
      );

  @override
  Future<Result<void>> asyncCancel(int requestId) => OdbcErrorBoundary.runVoid(
        'asyncCancel',
        () => _admin.asyncCancel(requestId),
      );

  @override
  Future<Result<void>> asyncFree(int requestId) =>
      OdbcErrorBoundary.runVoid('asyncFree', () => _admin.asyncFree(requestId));

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.run(
        'streamStartAsync',
        () => _admin.streamStartAsync(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<int>> streamPollAsync(int streamId) => OdbcErrorBoundary.run(
        'streamPollAsync',
        () => _admin.streamPollAsync(streamId),
      );

  @override
  Future<String?> detectDriver(String connectionString) =>
      _admin.detectDriver(connectionString);

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  }) =>
      OdbcErrorBoundary.run(
        'executeQuery',
        () => _query.executeQuery(sql, connectionId: connectionId),
      );

  @override
  bool get supportsDialectApi => _dialect.supportsDialectApi;

  @override
  String? buildUpsertSql({
    required String connectionString,
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String>? updateColumns,
  }) =>
      _dialect.buildUpsertSql(
        connectionString: connectionString,
        table: table,
        columns: columns,
        conflictColumns: conflictColumns,
        updateColumns: updateColumns,
      );

  @override
  String? appendReturningClause({
    required String connectionString,
    required String sql,
    required DmlVerb verb,
    required List<String> columns,
  }) =>
      _dialect.appendReturningClause(
        connectionString: connectionString,
        sql: sql,
        verb: verb,
        columns: columns,
      );

  @override
  List<String>? getSessionInitSql({
    required String connectionString,
    SessionOptions? options,
  }) =>
      _dialect.getSessionInitSql(
        connectionString: connectionString,
        options: options,
      );

  @override
  void dispose() {
    unawaited(closeEvents());
    _repository.dispose();
  }
}
