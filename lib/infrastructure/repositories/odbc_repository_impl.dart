import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart'
    show AsyncWorkerPoolStats;
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/dart_side_metrics.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_admin_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_bulk_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_catalog_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_pool_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_stream_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_transaction_runner.dart';
import 'package:result_dart/result_dart.dart';

/// Thin façade over capability-focused runners implementing [IOdbcRepository].
class OdbcRepositoryImpl implements IOdbcRepository {
  OdbcRepositoryImpl(
    Object native, {
    ResultEncoding defaultResultEncoding = ResultEncoding.rowMajor,
  }) : this.fromBackend(
          OdbcBackend.fromNative(native),
          defaultResultEncoding: defaultResultEncoding,
        );

  OdbcRepositoryImpl.fromBackend(
    OdbcBackend backend, {
    ResultEncoding defaultResultEncoding = ResultEncoding.rowMajor,
  })  : _backend = backend,
        _ffi = OdbcFfiDispatch(backend),
        _state = OdbcRepositoryState(
          defaultResultEncoding: defaultResultEncoding,
        ) {
    _wireRunners();
    if (_backend case AsyncBackend(:final connection)) {
      connection.onWorkerRecovered = _connection.onWorkerRecovered;
    }
  }

  final OdbcBackend _backend;
  final OdbcFfiDispatch _ffi;
  final OdbcRepositoryState _state;
  final OdbcResultParser _parser = const OdbcResultParser();

  StreamController<OdbcEvent>? _eventsController;

  late final OdbcConnectionRunner _connection;
  late final OdbcQueryRunner _query;
  late final OdbcStreamRunner _stream;
  late final OdbcTransactionRunner _transaction;
  late final OdbcPoolRunner _pool;
  late final OdbcAdminRunner _admin;
  late final OdbcCatalogRunner _catalog;
  late final OdbcBulkRunner _bulk;

  /// Effective default for `executeQueryParamValues` when callers omit
  /// `resultEncoding`. Wired from [ServiceLocator] for server presets.
  @visibleForTesting
  ResultEncoding get defaultResultEncoding => _state.defaultResultEncoding;

  void _wireRunners() {
    _connection = OdbcConnectionRunner(
      ffi: _ffi,
      state: _state,
      emit: _emit,
      maybeEmitSlowQuery: _maybeEmitSlowQuery,
    );
    _query = OdbcQueryRunner(
      ffi: _ffi,
      state: _state,
      connection: _connection,
      parser: _parser,
    );
    _stream = OdbcStreamRunner(
      ffi: _ffi,
      state: _state,
      connection: _connection,
      parser: _parser,
      query: _query,
    );
    _query.streamNativeQueryWithFallback =
        _stream.streamNativeQueryWithFallback;
    _query.streamingFailureFromException =
        _stream.streamingFailureFromException;

    _transaction = OdbcTransactionRunner(ffi: _ffi, state: _state);
    _pool = OdbcPoolRunner(
      ffi: _ffi,
      state: _state,
      connection: _connection,
      emit: _emit,
    );
    _admin = OdbcAdminRunner(ffi: _ffi, state: _state);
    _catalog = OdbcCatalogRunner(
      backend: _backend,
      nativeIdLookup: (id) => _state.connectionIds[id],
      parseBuffer: _parser.parseBufferToQueryResult,
      convertQueryError: ({
        required fallbackMessage,
        nativeConnectionId,
      }) =>
          _ffi.convertNativeErrorToFailure<QueryResult>(
        errorFactory: odbcQueryErrorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      ),
    );
    _bulk = OdbcBulkRunner(
      backend: _backend,
      nativeIdLookup: (id) => _state.connectionIds[id],
      convertIntError: ({
        required fallbackMessage,
        nativeConnectionId,
      }) =>
          _ffi.convertNativeErrorToFailure<int>(
        errorFactory: odbcQueryErrorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      ),
    );
  }

  StreamController<OdbcEvent> _ensureEventsController() {
    return _eventsController ??=
        StreamController<OdbcEvent>.broadcast(sync: true);
  }

  void _emit(OdbcEvent event) {
    final c = _eventsController;
    if (c == null || c.isClosed) return;
    c.add(event);
  }

  void _maybeEmitSlowQuery({
    required String connectionId,
    required String? sql,
    required Stopwatch? stopwatch,
  }) {
    if (stopwatch == null || sql == null) return;
    stopwatch.stop();
    final threshold =
        _state.connectionOptions[connectionId]?.effectiveSlowQueryThreshold;
    if (threshold == null) return;
    final elapsed = stopwatch.elapsed;
    if (elapsed < threshold) return;
    _emit(
      SlowQueryDetected(
        timestamp: DateTime.now().toUtc(),
        connectionId: connectionId,
        sql: sql,
        durationMs: elapsed.inMilliseconds,
      ),
    );
  }

  @override
  Stream<OdbcEvent> get events => _ensureEventsController().stream;

  @override
  Future<Result<Unit>> initialize() => _connection.initialize();

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      _connection.connect(connectionString, options: options);

  @override
  Future<Result<Unit>> disconnect(String connectionId) =>
      _connection.disconnect(connectionId);

  @override
  Future<Result<QueryResult>> executeQuery(String connectionId, String sql) =>
      _query.executeQuery(connectionId, sql);

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _stream.streamQueryMulti(connectionId, sql);

  @override
  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) =>
      _stream.streamQuery(connectionId, sql);

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) =>
      _stream.streamQueryColumnar(connectionId, sql);

  @override
  bool isInitialized() => _connection.isInitialized();

  @override
  void dispose() {
    _connection.disposeNative();
    _state.clearAll();
  }

  DartSideMetrics dartSideMetrics() => _connection.dartSideMetrics();

  @override
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel, {
    SavepointDialect savepointDialect = SavepointDialect.auto,
    TransactionAccessMode accessMode = TransactionAccessMode.readWrite,
    Duration? lockTimeout,
  }) =>
      _transaction.beginTransaction(
        connectionId,
        isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );

  @override
  Future<Result<Unit>> commitTransaction(String connectionId, int txnId) =>
      _transaction.commitTransaction(connectionId, txnId);

  @override
  Future<Result<Unit>> rollbackTransaction(String connectionId, int txnId) =>
      _transaction.rollbackTransaction(connectionId, txnId);

  @override
  Future<Result<XaTransactionHandle>> xaStart(String connectionId, Xid xid) =>
      _transaction.xaStart(connectionId, xid);

  @override
  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _transaction.createSavepoint(connectionId, txnId, name);

  @override
  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _transaction.rollbackToSavepoint(connectionId, txnId, name);

  @override
  Future<Result<Unit>> releaseSavepoint(
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
      _query.executePreparedParamValues(connectionId, stmtId, params, options);

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
  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) =>
      _query.closeStatement(connectionId, stmtId);

  @override
  Future<Result<Unit>> cancelStatement(String connectionId, int stmtId) =>
      _query.cancelStatement(connectionId, stmtId);

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      _query.executeQueryParamValues(
        connectionId,
        sql,
        params,
        resultEncoding: resultEncoding ?? _state.defaultResultEncoding,
      );

  @override
  Future<Result<QueryResult>> executeQueryParamBuffer(
    String connectionId,
    String sql,
    Uint8List? paramBuffer, {
    ResultEncoding? resultEncoding,
  }) =>
      _query.executeQueryParamBuffer(
        connectionId,
        sql,
        paramBuffer,
        resultEncoding: resultEncoding ?? _state.defaultResultEncoding,
      );

  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      _query.executeQueryDirectedParams(connectionId, sql, params);

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
      _stream.streamQueryNamed(connectionId, sql, namedParams);

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
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _catalog.catalogTables(connectionId, catalog: catalog, schema: schema);

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _catalog.catalogColumns(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _catalog.catalogTypeInfo(connectionId);

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _catalog.catalogPrimaryKeys(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _catalog.catalogForeignKeys(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _catalog.catalogIndexes(connectionId, table);

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      _pool.poolCreate(connectionString, maxSize, options: options);

  @override
  Future<Result<Unit>> poolSetSize(int poolId, int newMaxSize) =>
      _pool.poolSetSize(poolId, newMaxSize);

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) =>
      _pool.poolGetConnection(poolId);

  @override
  Future<Result<Unit>> poolReleaseConnection(String connectionId) =>
      _pool.poolReleaseConnection(connectionId);

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) =>
      _pool.poolHealthCheck(poolId);

  @override
  Future<Result<PoolState>> poolGetState(int poolId) =>
      _pool.poolGetState(poolId);

  @override
  Future<Result<Unit>> poolClose(int poolId) => _pool.poolClose(poolId);

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      _bulk.bulkInsert(
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
      _bulk.bulkInsertParallel(
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
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      _admin.getWorkerPoolStats();

  @override
  Future<Result<Unit>> clearStatementCache() => _query.clearStatementCache();

  @override
  Future<Result<Unit>> clearAllStatements() => _query.clearAllStatements();

  @override
  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      _query.getPreparedStatementsMetrics();

  @override
  Future<Result<Map<String, String>>> getVersion() => _admin.getVersion();

  @override
  Future<Result<Unit>> validateConnectionString(String connectionString) =>
      _admin.validateConnectionString(connectionString);

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      _admin.getDriverCapabilities(connectionString);

  @override
  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      _admin.getConnectionDbmsInfo(connectionId);

  @override
  Future<Result<Unit>> setLogLevel(int level) => _admin.setLogLevel(level);

  @override
  Future<Result<Unit>> setAuditEnabled({required bool enabled}) =>
      _admin.setAuditEnabled(enabled: enabled);

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      _admin.getAuditStatus();

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({int limit = 0}) =>
      _admin.getAuditEvents(limit: limit);

  @override
  Future<Result<Unit>> clearAuditEvents() => _admin.clearAuditEvents();

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      _pool.poolGetStateDetailed(poolId);

  @override
  Future<Result<Unit>> metadataCacheEnable({
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
  Future<Result<Unit>> clearMetadataCache() => _admin.clearMetadataCache();

  @override
  Future<Result<Unit>> cancelStream(int streamId) =>
      _stream.cancelStream(streamId);

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      _stream.executeAsyncStart(connectionId, sql);

  @override
  Future<Result<int>> asyncPoll(int requestId) => _stream.asyncPoll(requestId);

  @override
  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      _stream.asyncGetResult(requestId, maxBufferBytes: maxBufferBytes);

  @override
  Future<Result<Unit>> asyncCancel(int requestId) =>
      _stream.asyncCancel(requestId);

  @override
  Future<Result<Unit>> asyncFree(int requestId) => _stream.asyncFree(requestId);

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _stream.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  @override
  Future<Result<int>> streamPollAsync(int streamId) =>
      _stream.streamPollAsync(streamId);

  @override
  Future<String?> detectDriver(String connectionString) =>
      _admin.detectDriver(connectionString);
}
