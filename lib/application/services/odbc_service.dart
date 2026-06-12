import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/odbc_admin_service.dart';
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
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

export 'package:odbc_fast/application/services/i_admin_service.dart';
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
  OdbcService(IOdbcRepository repository)
      : _admin = OdbcAdminService(repository),
        _query = OdbcQueryService(repository),
        _pool = OdbcPoolService(repository),
        _transaction = OdbcTransactionService(repository),
        _repository = repository;

  final IOdbcRepository _repository;
  final OdbcAdminService _admin;
  final OdbcQueryService _query;
  final OdbcPoolService _pool;
  final OdbcTransactionService _transaction;

  /// Closes the internal event bridge. Call from owners that explicitly
  /// dispose the service. Safe to call multiple times.
  Future<void> closeEvents() => _admin.closeEvents();

  @override
  Stream<OdbcEvent> get events => _admin.events;

  @override
  Future<Result<void>> initialize() => _admin.initialize();

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      _admin.connect(connectionString, options: options);

  @override
  Future<Result<void>> disconnect(String connectionId) =>
      _admin.disconnect(connectionId);

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _query.executeQueryParamValues(
        connectionId,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      _query.executeQueryDirectedParams(connectionId, sql, params);

  @override
  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) =>
      _query.streamQuery(connectionId, sql);

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      _transaction.beginTransaction(
        connectionId,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );

  @override
  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      _transaction.commitTransaction(connectionId, txnId);

  @override
  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      _transaction.rollbackTransaction(connectionId, txnId);

  @override
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      _transaction.runInTransaction(
        connectionId,
        action,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );

  @override
  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) =>
      _transaction.runInXaTransaction(
        connectionId,
        xid,
        action,
        onePhase: onePhase,
      );

  @override
  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _transaction.createSavepoint(connectionId, txnId, name);

  @override
  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _transaction.rollbackToSavepoint(connectionId, txnId, name);

  @override
  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _transaction.releaseSavepoint(connectionId, txnId, name);

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _query.prepare(connectionId, sql, timeoutMs: timeoutMs);

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _query.prepareNamed(connectionId, sql, timeoutMs: timeoutMs);

  @override
  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  ) =>
      _query.executePreparedParamValues(
        connectionId,
        stmtId,
        params,
        options,
      );

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      _query.executePreparedNamed(
        connectionId,
        stmtId,
        namedParams,
        options,
      );

  @override
  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      _query.closeStatement(connectionId, stmtId);

  @override
  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      _query.cancelStatement(connectionId, stmtId);

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _query.executeQueryMulti(connectionId, sql);

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      _query.executeQueryMultiFull(connectionId, sql);

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      _query.executeQueryMultiParamValues(connectionId, sql, params);

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _query.streamQueryMulti(connectionId, sql);

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _query.executeQueryNamed(connectionId, sql, namedParams);

  @override
  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _query.streamQueryNamed(connectionId, sql, namedParams);

  @override
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      _query.executeQueryColumnarParamValues(
        connectionId,
        sql,
        params: params,
      );

  @override
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) =>
      _query.streamQueryColumnar(connectionId, sql);

  @override
  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      _query.catalogTables(
        connectionId: connectionId,
        catalog: catalog,
        schema: schema,
      );

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _query.catalogColumns(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _query.catalogTypeInfo(connectionId);

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _query.catalogPrimaryKeys(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _query.catalogForeignKeys(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _query.catalogIndexes(connectionId, table);

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      _pool.poolCreate(connectionString, maxSize, options: options);

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) =>
      _pool.poolGetConnection(poolId);

  @override
  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      _pool.poolReleaseConnection(connectionId);

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) =>
      _pool.poolHealthCheck(poolId);

  @override
  Future<Result<PoolState>> poolGetState(int poolId) =>
      _pool.poolGetState(poolId);

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      _pool.poolGetStateDetailed(poolId);

  @override
  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      _pool.poolSetSize(poolId, newMaxSize);

  @override
  Future<Result<void>> poolClose(int poolId) => _pool.poolClose(poolId);

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      _query.bulkInsert(
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
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
      _query.bulkInsertParallel(
        poolId,
        table,
        columns,
        dataBuffer,
        rowCount,
        parallelism: parallelism,
      );

  @override
  Future<Result<OdbcMetrics>> getMetrics() => _admin.getMetrics();

  @override
  bool isInitialized() => _admin.isInitialized();

  @override
  Future<Result<void>> clearStatementCache() => _admin.clearStatementCache();

  @override
  Future<Result<void>> clearAllStatements() => _admin.clearAllStatements();

  @override
  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      _admin.getPreparedStatementsMetrics();

  @override
  Future<Result<Map<String, String>>> getVersion() => _admin.getVersion();

  @override
  Future<Result<void>> validateConnectionString(String connectionString) =>
      _admin.validateConnectionString(connectionString);

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      _admin.getDriverCapabilities(connectionString);

  @override
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      _admin.getWorkerPoolStats();

  @override
  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      _admin.getConnectionDbmsInfo(connectionId);

  @override
  Future<Result<void>> setLogLevel(int level) => _admin.setLogLevel(level);

  @override
  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      _admin.setAuditEnabled(enabled: enabled);

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      _admin.getAuditStatus();

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({int limit = 0}) =>
      _admin.getAuditEvents(limit: limit);

  @override
  Future<Result<void>> clearAuditEvents() => _admin.clearAuditEvents();

  @override
  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      _admin.metadataCacheEnable(
        maxEntries: maxEntries,
        ttlSeconds: ttlSeconds,
      );

  @override
  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      _admin.metadataCacheStats();

  @override
  Future<Result<void>> clearMetadataCache() => _admin.clearMetadataCache();

  @override
  Future<Result<void>> cancelStream(int streamId) =>
      _admin.cancelStream(streamId);

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      _admin.executeAsyncStart(connectionId, sql);

  @override
  Future<Result<int>> asyncPoll(int requestId) => _admin.asyncPoll(requestId);

  @override
  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      _admin.asyncGetResult(requestId, maxBufferBytes: maxBufferBytes);

  @override
  Future<Result<void>> asyncCancel(int requestId) =>
      _admin.asyncCancel(requestId);

  @override
  Future<Result<void>> asyncFree(int requestId) => _admin.asyncFree(requestId);

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _admin.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  @override
  Future<Result<int>> streamPollAsync(int streamId) =>
      _admin.streamPollAsync(streamId);

  @override
  Future<String?> detectDriver(String connectionString) =>
      _admin.detectDriver(connectionString);

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  }) =>
      _query.executeQuery(sql, connectionId: connectionId);

  @override
  void dispose() => _repository.dispose();
}
