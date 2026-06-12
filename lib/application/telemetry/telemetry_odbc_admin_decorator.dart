import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:result_dart/result_dart.dart';

/// Admin-shaped telemetry delegate for the ODBC service decorator façade.
class TelemetryOdbcAdminDecorator {
  /// Creates an admin telemetry delegate.
  TelemetryOdbcAdminDecorator(this._service, this._ops);

  final IOdbcService _service;
  final TelemetryOdbcOperations _ops;

  Stream<OdbcEvent> get events => _service.events;

  Future<Result<void>> initialize() =>
      _ops.inOperation('ODBC.initialize', _service.initialize);

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      _ops.inOperation(
        'ODBC.connect',
        () => _service.connect(connectionString, options: options),
      );

  Future<Result<void>> disconnect(String connectionId) => _ops.inOperation(
        'ODBC.disconnect',
        () => _service.disconnect(connectionId),
      );

  Future<Result<OdbcMetrics>> getMetrics() =>
      _ops.inOperation('ODBC.getMetrics', _service.getMetrics);

  @Deprecated(
    'Use getWorkerPoolStats() — returns null in sync mode. '
    'Will be removed alongside the IOdbcService deprecation.',
  )
  Future<Result<AsyncWorkerPoolStats>> getAsyncWorkerPoolStats() =>
      _ops.inOperation(
        'ODBC.getAsyncWorkerPoolStats',
        _service.getAsyncWorkerPoolStats,
      );

  bool isInitialized() => _service.isInitialized();

  Future<Result<void>> clearStatementCache() => _ops.inOperation(
        'ODBC.clearStatementCache',
        _service.clearStatementCache,
      );

  Future<Result<void>> clearAllStatements() =>
      _ops.inOperation('ODBC.clearAllStatements', _service.clearAllStatements);

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      _ops.inOperation(
        'ODBC.getPreparedStatementsMetrics',
        _service.getPreparedStatementsMetrics,
      );

  Future<Result<Map<String, String>>> getVersion() =>
      _ops.inOperation('ODBC.getVersion', _service.getVersion);

  Future<Result<void>> validateConnectionString(String connectionString) =>
      _ops.inOperation(
        'ODBC.validateConnectionString',
        () => _service.validateConnectionString(connectionString),
      );

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      _ops.inOperation(
        'ODBC.getDriverCapabilities',
        () => _service.getDriverCapabilities(connectionString),
      );

  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      _service.getWorkerPoolStats();

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      _ops.inOperation(
        'ODBC.getConnectionDbmsInfo',
        () => _service.getConnectionDbmsInfo(connectionId),
      );

  Future<Result<void>> setLogLevel(int level) => _ops.inOperation(
        'ODBC.setLogLevel',
        () => _service.setLogLevel(level),
      );

  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      _ops.inOperation(
        'ODBC.setAuditEnabled',
        () => _service.setAuditEnabled(enabled: enabled),
      );

  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      _ops.inOperation('ODBC.getAuditStatus', _service.getAuditStatus);

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) =>
      _ops.inOperation(
        'ODBC.getAuditEvents',
        () => _service.getAuditEvents(limit: limit),
      );

  Future<Result<void>> clearAuditEvents() =>
      _ops.inOperation('ODBC.clearAuditEvents', _service.clearAuditEvents);

  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      _ops.inOperation(
        'ODBC.metadataCacheEnable',
        () => _service.metadataCacheEnable(
          maxEntries: maxEntries,
          ttlSeconds: ttlSeconds,
        ),
      );

  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      _ops.inOperation('ODBC.metadataCacheStats', _service.metadataCacheStats);

  Future<Result<void>> clearMetadataCache() =>
      _ops.inOperation('ODBC.clearMetadataCache', _service.clearMetadataCache);

  Future<Result<void>> cancelStream(int streamId) => _ops.inOperation(
        'ODBC.cancelStream',
        () => _service.cancelStream(streamId),
      );

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      _ops.inOperation(
        'ODBC.executeAsyncStart',
        () => _service.executeAsyncStart(connectionId, sql),
      );

  Future<Result<int>> asyncPoll(int requestId) => _ops.inOperation(
        'ODBC.asyncPoll',
        () => _service.asyncPoll(requestId),
      );

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      _ops.inOperation(
        'ODBC.asyncGetResult',
        () => _service.asyncGetResult(
          requestId,
          maxBufferBytes: maxBufferBytes,
        ),
      );

  Future<Result<void>> asyncCancel(int requestId) => _ops.inOperation(
        'ODBC.asyncCancel',
        () => _service.asyncCancel(requestId),
      );

  Future<Result<void>> asyncFree(int requestId) => _ops.inOperation(
        'ODBC.asyncFree',
        () => _service.asyncFree(requestId),
      );

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _ops.inOperation(
        'ODBC.streamStartAsync',
        () => _service.streamStartAsync(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<int>> streamPollAsync(int streamId) => _ops.inOperation(
        'ODBC.streamPollAsync',
        () => _service.streamPollAsync(streamId),
      );

  Future<String?> detectDriver(String connectionString) => _ops.inOperation(
        'ODBC.detectDriver',
        () => _service.detectDriver(connectionString),
      );
}
