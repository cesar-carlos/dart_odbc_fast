/// Mock [IOdbcRepository] for testing OdbcService and related layers.
library;

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
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Mock ODBC repository for testing.
class MockOdbcRepository implements IOdbcRepository {
  Connection _connection = Connection(
    id: 'test-connection',
    connectionString: 'init',
    createdAt: DateTime.now(),
  );

  bool initializeCalled = false;
  bool connectCalled = false;
  bool disconnectCalled = false;
  bool executeQueryCalled = false;
  bool streamQueryCalled = false;
  bool executeQueryParamsCalled = false;
  bool executeQueryNamedCalled = false;
  bool executeQueryMultiFullCalled = false;
  bool beginTransactionCalled = false;
  bool commitTransactionCalled = false;
  bool rollbackTransactionCalled = false;
  bool clearStatementCacheCalled = false;
  bool metadataCacheEnableCalled = false;
  bool metadataCacheStatsCalled = false;
  bool clearMetadataCacheCalled = false;
  bool cancelStreamCalled = false;
  bool getVersionCalled = false;
  bool validateConnectionStringCalled = false;
  bool getDriverCapabilitiesCalled = false;
  bool setAuditEnabledCalled = false;
  bool getAuditStatusCalled = false;
  bool getAuditEventsCalled = false;
  bool clearAuditEventsCalled = false;
  bool poolGetStateDetailedCalled = false;
  bool executeAsyncStartCalled = false;
  bool asyncPollCalled = false;
  bool asyncGetResultCalled = false;
  bool asyncCancelCalled = false;
  bool asyncFreeCalled = false;
  bool streamStartAsyncCalled = false;
  bool streamPollAsyncCalled = false;
  bool prepareNamedCalled = false;
  bool executePreparedNamedCalled = false;
  int _queryCount = 0;

  @override
  Future<Result<Unit>> initialize() async {
    initializeCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    connectCalled = true;
    _connection = Connection(
      id: 'test-connection-2',
      connectionString: connectionString,
      createdAt: DateTime.now(),
    );
    return Success(_connection);
  }

  @override
  Future<Result<Unit>> disconnect(String connectionId) async {
    disconnectCalled = true;
    if (connectionId == _connection.id) {
      _connection = Connection(
        id: '',
        connectionString: '',
        createdAt: DateTime.now(),
      );
      return const Success(unit);
    }
    return const Failure(
      ConnectionError(message: 'Connection ID does not match'),
    );
  }

  @override
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    executeQueryCalled = true;
    _queryCount++;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Alice'],
          [2, 'Bob'],
        ],
        rowCount: 2,
      ),
    );
  }

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  ) async* {
    streamQueryCalled = true;
    _queryCount++;
    yield const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Alice'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    executeQueryParamsCalled = true;
    _queryCount++;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Charlie'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    executeQueryNamedCalled = true;
    _queryCount++;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Charlie'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return const Success(1);
  }

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    prepareNamedCalled = true;
    return const Success(2);
  }

  @override
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    executePreparedNamedCalled = true;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Charlie'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) async {
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> cancelStatement(String connectionId, int stmtId) async {
    return const Failure(
      UnsupportedFeatureError(
        message: 'Statement cancellation is not supported',
      ),
    );
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel, {
    SavepointDialect savepointDialect = SavepointDialect.auto,
    TransactionAccessMode accessMode = TransactionAccessMode.readWrite,
  }) async {
    beginTransactionCalled = true;
    return const Success(1);
  }

  @override
  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  ) async {
    commitTransactionCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    rollbackTransactionCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Dave'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    executeQueryMultiFullCalled = true;
    return executeQueryMultiFull(connectionId, sql);
  }

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) async* {
    final full = await executeQueryMultiFull(connectionId, sql);
    if (full.isError()) {
      final err = full.exceptionOrNull();
      yield Failure<QueryResultMultiItem, OdbcError>(
        err is OdbcError ? err : QueryError(message: err.toString()),
      );
      return;
    }
    for (final item in full.getOrNull()!.items) {
      yield Success<QueryResultMultiItem, OdbcError>(item);
    }
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    executeQueryMultiFullCalled = true;
    return const Success(
      QueryResultMulti(
        items: [
          QueryResultMultiItem.resultSet(
            QueryResult(
              columns: ['id', 'name'],
              rows: [
                [1, 'Dave'],
              ],
              rowCount: 1,
            ),
          ),
          QueryResultMultiItem.rowCount(1),
        ],
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    return const Success(1);
  }

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) async {
    return Success(
      Connection(
        id: 'pooled',
        connectionString: 'pool',
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<Result<Unit>> poolReleaseConnection(String connectionId) async {
    return const Success(unit);
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    return const Success(true);
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    return const Success(PoolState(size: 1, idle: 0));
  }

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) async {
    poolGetStateDetailedCalled = true;
    return const Success({
      'total_connections': 1,
      'idle_connections': 0,
      'active_connections': 1,
      'max_size': 4,
    });
  }

  @override
  Future<Result<Unit>> poolClose(int poolId) async {
    return const Success(unit);
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    return const Success(0);
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
    return const Success(0);
  }

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    return Success(
      OdbcMetrics(
        queryCount: _queryCount,
        errorCount: 0,
        uptimeSecs: 10,
        totalLatencyMillis: 100,
        avgLatencyMillis: 25,
      ),
    );
  }

  @override
  bool isInitialized() {
    return _connection.id.isNotEmpty;
  }

  @override
  Future<Result<Unit>> clearStatementCache() async {
    clearStatementCacheCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    return const Success(
      PreparedStatementMetrics(
        cacheSize: 0,
        cacheMaxSize: 100,
        cacheHits: 0,
        cacheMisses: 0,
        totalPrepares: 0,
        totalExecutions: 0,
        memoryUsageBytes: 0,
        avgExecutionsPerStmt: 0,
      ),
    );
  }

  @override
  Future<Result<Map<String, String>>> getVersion() async {
    getVersionCalled = true;
    return const Success({'api': '0.1.0', 'abi': '1.0.0'});
  }

  @override
  Future<Result<Unit>> validateConnectionString(String connectionString) async {
    validateConnectionStringCalled = true;
    if (connectionString.trim().isEmpty) {
      return const Failure(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    return const Success(unit);
  }

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) async {
    getDriverCapabilitiesCalled = true;
    return const Success({
      'driver_name': 'mock',
      'driver_version': '1.0',
      'supports_prepared_statements': true,
      'supports_batch_operations': true,
      'supports_streaming': true,
      'max_row_array_size': 1000,
    });
  }

  @override
  Future<Result<Unit>> setAuditEnabled({required bool enabled}) async {
    setAuditEnabledCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() async {
    getAuditStatusCalled = true;
    return const Success({'enabled': true, 'event_count': 0});
  }

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) async {
    getAuditEventsCalled = true;
    return const Success([]);
  }

  @override
  Future<Result<Unit>> clearAuditEvents() async {
    clearAuditEventsCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    metadataCacheEnableCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Map<String, Object?>>> metadataCacheStats() async {
    metadataCacheStatsCalled = true;
    return const Success({
      'hits': 0,
      'misses': 0,
      'size': 0,
      'max_size': 0,
      'ttl_secs': 0,
    });
  }

  @override
  Future<Result<Unit>> clearMetadataCache() async {
    clearMetadataCacheCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> cancelStream(int streamId) async {
    cancelStreamCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) async {
    executeAsyncStartCalled = true;
    return const Success(1);
  }

  @override
  Future<Result<int>> asyncPoll(int requestId) async {
    asyncPollCalled = true;
    return const Success(1);
  }

  @override
  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) async {
    asyncGetResultCalled = true;
    return const Success(
      QueryResult(
        columns: ['id'],
        rows: [
          [1],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<Unit>> asyncCancel(int requestId) async {
    asyncCancelCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> asyncFree(int requestId) async {
    asyncFreeCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    streamStartAsyncCalled = true;
    return const Success(1);
  }

  @override
  Future<Result<int>> streamPollAsync(int streamId) async {
    streamPollAsyncCalled = true;
    return const Success(1);
  }

  @override
  Future<String?> detectDriver(String connectionString) async {
    return 'mock';
  }

  void dispose() {
    _connection = Connection(
      id: '',
      connectionString: '',
      createdAt: DateTime.now(),
    );
  }
}
