import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
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

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  );

  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
  });

  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  );

  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  );

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
    int maxSize,
  );

  Future<Result<Connection>> poolGetConnection(int poolId);

  Future<Result<void>> poolReleaseConnection(String connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<PoolState>> poolGetState(int poolId);

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId);

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

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics();

  Future<Result<Map<String, String>>> getVersion();

  Future<Result<void>> validateConnectionString(String connectionString);

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  );

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
  }) async {
    return _repository.beginTransaction(
      connectionId,
      isolationLevel ?? IsolationLevel.readCommitted,
      savepointDialect: savepointDialect ?? SavepointDialect.auto,
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
    int maxSize,
  ) async {
    return _repository.poolCreate(connectionString, maxSize);
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
