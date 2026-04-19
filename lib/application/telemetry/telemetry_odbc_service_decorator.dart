import 'package:odbc_fast/application/services/odbc_service.dart';
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
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:result_dart/result_dart.dart';

/// Decorator that adds telemetry to all OdbcService operations.
///
/// This decorator wraps [OdbcService] to add distributed tracing,
/// metrics collection, and event logging without modifying the core
/// service logic.
/// It follows the Decorator design pattern to separate cross-cutting concerns.
///
/// ## Usage
/// ```dart
/// final service = OdbcService(repository);
/// final telemetry = SimpleTelemetryService(repository: telemetryRepository);
/// final decoratedService = TelemetryOdbcServiceDecorator(service, telemetry);
/// ```
///
/// ## Features
/// - Traces all database operations with unique trace IDs
/// - Spans for each operation with timing and attributes
/// - Metrics for queries, errors, and connection counts
/// - Events for logging with severity levels
class TelemetryOdbcServiceDecorator implements IOdbcService {
  /// Creates a new decorated ODBC service.
  ///
  /// The first parameter provides the core ODBC functionality; the second
  /// provides distributed tracing and metrics.
  TelemetryOdbcServiceDecorator(this._service, this._telemetry);
  final OdbcService _service;
  final SimpleTelemetryService _telemetry;

  @override
  Future<Result<void>> initialize() async {
    return _telemetry.inOperation(
      'ODBC.initialize',
      _service.initialize,
    );
  }

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    return _telemetry.inOperation(
      'ODBC.connect',
      () => _service.connect(connectionString, options: options),
    );
  }

  @override
  Future<Result<void>> disconnect(String connectionId) async {
    return _telemetry.inOperation(
      'ODBC.disconnect',
      () => _service.disconnect(connectionId),
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executeQueryParams',
      () => _service.executeQueryParams(connectionId, sql, params),
    );
  }

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  ) {
    return _service.streamQuery(connectionId, sql);
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) async {
    return _telemetry.inOperation(
      'ODBC.beginTransaction',
      () => _service.beginTransaction(
        connectionId,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      ),
    );
  }

  @override
  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  ) async {
    return _telemetry.inOperation(
      'ODBC.commitTransaction',
      () => _service.commitTransaction(connectionId, txnId),
    );
  }

  @override
  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    return _telemetry.inOperation(
      'ODBC.rollbackTransaction',
      () => _service.rollbackTransaction(connectionId, txnId),
    );
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
    // Wrap the whole unit of work in a single span so traces show the
    // transaction lifecycle as one logical operation. Inner
    // beginTransaction / commit / rollback calls each get their own
    // child span via the wrapped service's method delegates.
    return _telemetry.inOperation(
      'ODBC.runInTransaction',
      () => _service.runInTransaction<T>(
        connectionId,
        action,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      ),
    );
  }

  @override
  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _telemetry.inOperation(
      'ODBC.createSavepoint',
      () => _service.createSavepoint(connectionId, txnId, name),
    );
  }

  @override
  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _telemetry.inOperation(
      'ODBC.rollbackToSavepoint',
      () => _service.rollbackToSavepoint(connectionId, txnId, name),
    );
  }

  @override
  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _telemetry.inOperation(
      'ODBC.releaseSavepoint',
      () => _service.releaseSavepoint(connectionId, txnId, name),
    );
  }

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return _telemetry.inOperation(
      'ODBC.prepare',
      () => _service.prepare(connectionId, sql, timeoutMs: timeoutMs),
    );
  }

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return _telemetry.inOperation(
      'ODBC.prepareNamed',
      () => _service.prepareNamed(connectionId, sql, timeoutMs: timeoutMs),
    );
  }

  @override
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executePrepared',
      () => _service.executePrepared(connectionId, stmtId, params, options),
    );
  }

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executePreparedNamed',
      () => _service.executePreparedNamed(
        connectionId,
        stmtId,
        namedParams,
        options,
      ),
    );
  }

  @override
  Future<Result<void>> closeStatement(
    String connectionId,
    int stmtId,
  ) async {
    return _telemetry.inOperation(
      'ODBC.closeStatement',
      () => _service.closeStatement(connectionId, stmtId),
    );
  }

  @override
  Future<Result<void>> cancelStatement(
    String connectionId,
    int stmtId,
  ) async {
    return _telemetry.inOperation(
      'ODBC.cancelStatement',
      () => _service.cancelStatement(connectionId, stmtId),
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executeQueryMulti',
      () => _service.executeQueryMulti(connectionId, sql),
    );
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executeQueryMultiFull',
      () => _service.executeQueryMultiFull(connectionId, sql),
    );
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executeQueryMultiParams',
      () => _service.executeQueryMultiParams(connectionId, sql, params),
    );
  }

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) {
    // Telemetry per-stream is tricky because a stream can be long-lived.
    // We surface the underlying stream as-is and let the consumer decide.
    return _service.streamQueryMulti(connectionId, sql);
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    return _telemetry.inOperation(
      'ODBC.executeQueryNamed',
      () => _service.executeQueryNamed(connectionId, sql, namedParams),
    );
  }

  @override
  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) async {
    return _telemetry.inOperation(
      'ODBC.catalogTables',
      () => _service.catalogTables(
        connectionId: connectionId,
        catalog: catalog,
        schema: schema,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    return _telemetry.inOperation(
      'ODBC.catalogColumns',
      () => _service.catalogColumns(connectionId, table),
    );
  }

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) async {
    return _telemetry.inOperation(
      'ODBC.catalogTypeInfo',
      () => _service.catalogTypeInfo(connectionId),
    );
  }

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) async {
    return _telemetry.inOperation(
      'ODBC.catalogPrimaryKeys',
      () => _service.catalogPrimaryKeys(connectionId, table),
    );
  }

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) async {
    return _telemetry.inOperation(
      'ODBC.catalogForeignKeys',
      () => _service.catalogForeignKeys(connectionId, table),
    );
  }

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) async {
    return _telemetry.inOperation(
      'ODBC.catalogIndexes',
      () => _service.catalogIndexes(connectionId, table),
    );
  }

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    return _telemetry.inOperation(
      'ODBC.poolCreate',
      () => _service.poolCreate(connectionString, maxSize),
    );
  }

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) async {
    return _telemetry.inOperation(
      'ODBC.poolGetConnection',
      () => _service.poolGetConnection(poolId),
    );
  }

  @override
  Future<Result<void>> poolReleaseConnection(String connectionId) async {
    return _telemetry.inOperation(
      'ODBC.poolReleaseConnection',
      () => _service.poolReleaseConnection(connectionId),
    );
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    return _telemetry.inOperation(
      'ODBC.poolHealthCheck',
      () => _service.poolHealthCheck(poolId),
    );
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    return _telemetry.inOperation(
      'ODBC.poolGetState',
      () => _service.poolGetState(poolId),
    );
  }

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) async {
    return _telemetry.inOperation(
      'ODBC.poolGetStateDetailed',
      () => _service.poolGetStateDetailed(poolId),
    );
  }

  @override
  Future<Result<void>> poolClose(int poolId) async {
    return _telemetry.inOperation(
      'ODBC.poolClose',
      () => _service.poolClose(poolId),
    );
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    return _telemetry.inOperation(
      'ODBC.bulkInsert',
      () => _service.bulkInsert(
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      ),
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
    return _telemetry.inOperation(
      'ODBC.bulkInsertParallel',
      () => _service.bulkInsertParallel(
        poolId,
        table,
        columns,
        dataBuffer,
        rowCount,
        parallelism: parallelism,
      ),
    );
  }

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    return _telemetry.inOperation(
      'ODBC.getMetrics',
      _service.getMetrics,
    );
  }

  @override
  bool isInitialized() {
    return _service.isInitialized();
  }

  @override
  Future<Result<void>> clearStatementCache() async {
    return _telemetry.inOperation(
      'ODBC.clearStatementCache',
      _service.clearStatementCache,
    );
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    return _telemetry.inOperation(
      'ODBC.getPreparedStatementsMetrics',
      _service.getPreparedStatementsMetrics,
    );
  }

  @override
  Future<Result<Map<String, String>>> getVersion() async {
    return _telemetry.inOperation(
      'ODBC.getVersion',
      _service.getVersion,
    );
  }

  @override
  Future<Result<void>> validateConnectionString(String connectionString) async {
    return _telemetry.inOperation(
      'ODBC.validateConnectionString',
      () => _service.validateConnectionString(connectionString),
    );
  }

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) async {
    return _telemetry.inOperation(
      'ODBC.getDriverCapabilities',
      () => _service.getDriverCapabilities(connectionString),
    );
  }

  @override
  Future<Result<void>> setAuditEnabled({required bool enabled}) async {
    return _telemetry.inOperation(
      'ODBC.setAuditEnabled',
      () => _service.setAuditEnabled(enabled: enabled),
    );
  }

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() async {
    return _telemetry.inOperation(
      'ODBC.getAuditStatus',
      _service.getAuditStatus,
    );
  }

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) async {
    return _telemetry.inOperation(
      'ODBC.getAuditEvents',
      () => _service.getAuditEvents(limit: limit),
    );
  }

  @override
  Future<Result<void>> clearAuditEvents() async {
    return _telemetry.inOperation(
      'ODBC.clearAuditEvents',
      _service.clearAuditEvents,
    );
  }

  @override
  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    return _telemetry.inOperation(
      'ODBC.metadataCacheEnable',
      () => _service.metadataCacheEnable(
        maxEntries: maxEntries,
        ttlSeconds: ttlSeconds,
      ),
    );
  }

  @override
  Future<Result<Map<String, Object?>>> metadataCacheStats() async {
    return _telemetry.inOperation(
      'ODBC.metadataCacheStats',
      _service.metadataCacheStats,
    );
  }

  @override
  Future<Result<void>> clearMetadataCache() async {
    return _telemetry.inOperation(
      'ODBC.clearMetadataCache',
      _service.clearMetadataCache,
    );
  }

  @override
  Future<Result<void>> cancelStream(int streamId) async {
    return _telemetry.inOperation(
      'ODBC.cancelStream',
      () => _service.cancelStream(streamId),
    );
  }

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) async {
    return _telemetry.inOperation(
      'ODBC.executeAsyncStart',
      () => _service.executeAsyncStart(connectionId, sql),
    );
  }

  @override
  Future<Result<int>> asyncPoll(int requestId) async {
    return _telemetry.inOperation(
      'ODBC.asyncPoll',
      () => _service.asyncPoll(requestId),
    );
  }

  @override
  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) async {
    return _telemetry.inOperation(
      'ODBC.asyncGetResult',
      () => _service.asyncGetResult(
        requestId,
        maxBufferBytes: maxBufferBytes,
      ),
    );
  }

  @override
  Future<Result<void>> asyncCancel(int requestId) async {
    return _telemetry.inOperation(
      'ODBC.asyncCancel',
      () => _service.asyncCancel(requestId),
    );
  }

  @override
  Future<Result<void>> asyncFree(int requestId) async {
    return _telemetry.inOperation(
      'ODBC.asyncFree',
      () => _service.asyncFree(requestId),
    );
  }

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    return _telemetry.inOperation(
      'ODBC.streamStartAsync',
      () => _service.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      ),
    );
  }

  @override
  Future<Result<int>> streamPollAsync(int streamId) async {
    return _telemetry.inOperation(
      'ODBC.streamPollAsync',
      () => _service.streamPollAsync(streamId),
    );
  }

  @override
  Future<String?> detectDriver(String connectionString) async {
    return _telemetry.inOperation(
      'ODBC.detectDriver',
      () => _service.detectDriver(connectionString),
    );
  }

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    List<dynamic>? params,
    String? connectionId,
  }) async {
    return _telemetry.inOperation(
      'ODBC.executeQuery',
      () => _service.executeQuery(
        sql,
        params: params,
        connectionId: connectionId,
      ),
    );
  }

  @override
  void dispose() {
    _service.dispose();
  }
}
