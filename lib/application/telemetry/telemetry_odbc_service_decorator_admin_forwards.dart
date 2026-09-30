import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:result_dart/result_dart.dart';

/// Admin-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServiceAdminForwards on TelemetryOdbcServiceDecoratorBase {
  Future<Result<void>> initialize() =>
      OdbcErrorBoundary.runVoid('initialize', () => admin.initialize());

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      OdbcErrorBoundary.run(
        'connect',
        () => admin.connect(connectionString, options: options),
      );

  Future<Result<void>> disconnect(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'disconnect',
        () => admin.disconnect(connectionId),
      );

  Future<Result<OdbcMetrics>> getMetrics() =>
      OdbcErrorBoundary.run('getMetrics', () => admin.getMetrics());

  bool isInitialized() => admin.isInitialized();

  Future<Result<void>> clearStatementCache() => OdbcErrorBoundary.runVoid(
        'clearStatementCache',
        () => admin.clearStatementCache(),
      );

  Future<Result<void>> clearAllStatements() => OdbcErrorBoundary.runVoid(
        'clearAllStatements',
        () => admin.clearAllStatements(),
      );

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      OdbcErrorBoundary.run(
        'getPreparedStatementsMetrics',
        () => admin.getPreparedStatementsMetrics(),
      );

  Future<Result<Map<String, String>>> getVersion() =>
      OdbcErrorBoundary.run('getVersion', () => admin.getVersion());

  Future<Result<void>> validateConnectionString(String connectionString) =>
      OdbcErrorBoundary.runVoid(
        'validateConnectionString',
        () => admin.validateConnectionString(connectionString),
      );

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      OdbcErrorBoundary.run(
        'getDriverCapabilities',
        () => admin.getDriverCapabilities(connectionString),
      );

  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      admin.getWorkerPoolStats();

  Stream<OdbcEvent> get events => admin.events;

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'getConnectionDbmsInfo',
        () => admin.getConnectionDbmsInfo(connectionId),
      );

  Future<Result<void>> setLogLevel(int level) =>
      OdbcErrorBoundary.runVoid('setLogLevel', () => admin.setLogLevel(level));

  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      OdbcErrorBoundary.runVoid(
        'setAuditEnabled',
        () => admin.setAuditEnabled(enabled: enabled),
      );

  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      OdbcErrorBoundary.run('getAuditStatus', () => admin.getAuditStatus());

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) =>
      OdbcErrorBoundary.run(
        'getAuditEvents',
        () => admin.getAuditEvents(limit: limit),
      );

  Future<Result<void>> clearAuditEvents() => OdbcErrorBoundary.runVoid(
        'clearAuditEvents',
        () => admin.clearAuditEvents(),
      );

  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      OdbcErrorBoundary.runVoid(
        'metadataCacheEnable',
        () => admin.metadataCacheEnable(
          maxEntries: maxEntries,
          ttlSeconds: ttlSeconds,
        ),
      );

  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      OdbcErrorBoundary.run(
        'metadataCacheStats',
        () => admin.metadataCacheStats(),
      );

  Future<Result<void>> clearMetadataCache() => OdbcErrorBoundary.runVoid(
        'clearMetadataCache',
        () => admin.clearMetadataCache(),
      );

  Future<Result<void>> cancelStream(int streamId) => OdbcErrorBoundary.runVoid(
        'cancelStream',
        () => admin.cancelStream(streamId),
      );

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      OdbcErrorBoundary.run(
        'executeAsyncStart',
        () => admin.executeAsyncStart(connectionId, sql),
      );

  Future<Result<int>> asyncPoll(int requestId) =>
      OdbcErrorBoundary.run('asyncPoll', () => admin.asyncPoll(requestId));

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      OdbcErrorBoundary.run(
        'asyncGetResult',
        () => admin.asyncGetResult(requestId, maxBufferBytes: maxBufferBytes),
      );

  Future<Result<void>> asyncCancel(int requestId) => OdbcErrorBoundary.runVoid(
        'asyncCancel',
        () => admin.asyncCancel(requestId),
      );

  Future<Result<void>> asyncFree(int requestId) =>
      OdbcErrorBoundary.runVoid('asyncFree', () => admin.asyncFree(requestId));

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.run(
        'streamStartAsync',
        () => admin.streamStartAsync(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<int>> streamPollAsync(int streamId) => OdbcErrorBoundary.run(
        'streamPollAsync',
        () => admin.streamPollAsync(streamId),
      );

  Future<String?> detectDriver(String connectionString) =>
      admin.detectDriver(connectionString);
}
