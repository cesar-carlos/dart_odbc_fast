import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:result_dart/result_dart.dart';

/// Admin-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServiceAdminForwards on TelemetryOdbcServiceDecoratorBase {
  Future<Result<void>> initialize() => admin.initialize();

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      admin.connect(connectionString, options: options);

  Future<Result<void>> disconnect(String connectionId) =>
      admin.disconnect(connectionId);

  Future<Result<OdbcMetrics>> getMetrics() => admin.getMetrics();

  bool isInitialized() => admin.isInitialized();

  Future<Result<void>> clearStatementCache() => admin.clearStatementCache();

  Future<Result<void>> clearAllStatements() => admin.clearAllStatements();

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      admin.getPreparedStatementsMetrics();

  Future<Result<Map<String, String>>> getVersion() => admin.getVersion();

  Future<Result<void>> validateConnectionString(String connectionString) =>
      admin.validateConnectionString(connectionString);

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      admin.getDriverCapabilities(connectionString);

  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      admin.getWorkerPoolStats();

  Stream<OdbcEvent> get events => admin.events;

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      admin.getConnectionDbmsInfo(connectionId);

  Future<Result<void>> setLogLevel(int level) => admin.setLogLevel(level);

  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      admin.setAuditEnabled(enabled: enabled);

  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      admin.getAuditStatus();

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) =>
      admin.getAuditEvents(limit: limit);

  Future<Result<void>> clearAuditEvents() => admin.clearAuditEvents();

  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      admin.metadataCacheEnable(
        maxEntries: maxEntries,
        ttlSeconds: ttlSeconds,
      );

  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      admin.metadataCacheStats();

  Future<Result<void>> clearMetadataCache() => admin.clearMetadataCache();

  Future<Result<void>> cancelStream(int streamId) =>
      admin.cancelStream(streamId);

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      admin.executeAsyncStart(connectionId, sql);

  Future<Result<int>> asyncPoll(int requestId) => admin.asyncPoll(requestId);

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      admin.asyncGetResult(requestId, maxBufferBytes: maxBufferBytes);

  Future<Result<void>> asyncCancel(int requestId) =>
      admin.asyncCancel(requestId);

  Future<Result<void>> asyncFree(int requestId) => admin.asyncFree(requestId);

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      admin.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Future<Result<int>> streamPollAsync(int streamId) =>
      admin.streamPollAsync(streamId);

  Future<String?> detectDriver(String connectionString) =>
      admin.detectDriver(connectionString);
}
