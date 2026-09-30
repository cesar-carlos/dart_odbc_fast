import 'package:odbc_fast/application/services/i_admin_service.dart';
import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:result_dart/result_dart.dart';

/// Admin-shaped telemetry decorator implementing [IAdminService].
class TelemetryOdbcAdminDecorator implements IAdminService {
  /// Creates an admin telemetry decorator.
  TelemetryOdbcAdminDecorator(
    IAdminService admin,
    this._ops, [
    IOdbcService? aggregate,
  ])  : _admin = admin,
        _aggregate = aggregate ?? (admin is IOdbcService ? admin : null);

  final IAdminService _admin;
  final TelemetryOdbcOperations _ops;
  final IOdbcService? _aggregate;

  IOdbcService get _service => _aggregate ?? _admin as IOdbcService;

  @override
  Stream<OdbcEvent> get events => _admin.events;

  @override
  Future<Result<void>> initialize() => OdbcErrorBoundary.runVoid(
        'initialize',
        () => _ops.inOperation('ODBC.initialize', _admin.initialize),
      );

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      OdbcErrorBoundary.run(
        'connect',
        () => _ops.inOperation(
          'ODBC.connect',
          () => _admin.connect(connectionString, options: options),
        ),
      );

  @override
  Future<Result<void>> disconnect(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'disconnect',
        () => _ops.inOperation(
          'ODBC.disconnect',
          () => _admin.disconnect(connectionId),
        ),
      );

  @override
  Future<Result<OdbcMetrics>> getMetrics() => OdbcErrorBoundary.run(
        'getMetrics',
        () => _ops.inOperation('ODBC.getMetrics', _admin.getMetrics),
      );

  bool isInitialized() => _service.isInitialized();

  Future<Result<void>> clearStatementCache() => OdbcErrorBoundary.runVoid(
        'clearStatementCache',
        () => _ops.inOperation(
          'ODBC.clearStatementCache',
          _service.clearStatementCache,
        ),
      );

  Future<Result<void>> clearAllStatements() => OdbcErrorBoundary.runVoid(
        'clearAllStatements',
        () => _ops.inOperation(
          'ODBC.clearAllStatements',
          _service.clearAllStatements,
        ),
      );

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      OdbcErrorBoundary.run(
        'getPreparedStatementsMetrics',
        () => _ops.inOperation(
          'ODBC.getPreparedStatementsMetrics',
          _service.getPreparedStatementsMetrics,
        ),
      );

  Future<Result<Map<String, String>>> getVersion() => OdbcErrorBoundary.run(
        'getVersion',
        () => _ops.inOperation('ODBC.getVersion', _service.getVersion),
      );

  @override
  Future<Result<void>> validateConnectionString(String connectionString) =>
      OdbcErrorBoundary.runVoid(
        'validateConnectionString',
        () => _ops.inOperation(
          'ODBC.validateConnectionString',
          () => _admin.validateConnectionString(connectionString),
        ),
      );

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      OdbcErrorBoundary.run(
        'getDriverCapabilities',
        () => _ops.inOperation(
          'ODBC.getDriverCapabilities',
          () => _admin.getDriverCapabilities(connectionString),
        ),
      );

  @override
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      _admin.getWorkerPoolStats();

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'getConnectionDbmsInfo',
        () => _ops.inOperation(
          'ODBC.getConnectionDbmsInfo',
          () => _service.getConnectionDbmsInfo(connectionId),
        ),
      );

  Future<Result<void>> setLogLevel(int level) => OdbcErrorBoundary.runVoid(
        'setLogLevel',
        () => _ops.inOperation(
          'ODBC.setLogLevel',
          () => _service.setLogLevel(level),
        ),
      );

  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      OdbcErrorBoundary.runVoid(
        'setAuditEnabled',
        () => _ops.inOperation(
          'ODBC.setAuditEnabled',
          () => _service.setAuditEnabled(enabled: enabled),
        ),
      );

  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      OdbcErrorBoundary.run(
        'getAuditStatus',
        () => _ops.inOperation('ODBC.getAuditStatus', _service.getAuditStatus),
      );

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) =>
      OdbcErrorBoundary.run(
        'getAuditEvents',
        () => _ops.inOperation(
          'ODBC.getAuditEvents',
          () => _service.getAuditEvents(limit: limit),
        ),
      );

  Future<Result<void>> clearAuditEvents() => OdbcErrorBoundary.runVoid(
        'clearAuditEvents',
        () => _ops.inOperation(
          'ODBC.clearAuditEvents',
          _service.clearAuditEvents,
        ),
      );

  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      OdbcErrorBoundary.runVoid(
        'metadataCacheEnable',
        () => _ops.inOperation(
          'ODBC.metadataCacheEnable',
          () => _service.metadataCacheEnable(
            maxEntries: maxEntries,
            ttlSeconds: ttlSeconds,
          ),
        ),
      );

  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      OdbcErrorBoundary.run(
        'metadataCacheStats',
        () => _ops.inOperation(
          'ODBC.metadataCacheStats',
          _service.metadataCacheStats,
        ),
      );

  Future<Result<void>> clearMetadataCache() => OdbcErrorBoundary.runVoid(
        'clearMetadataCache',
        () => _ops.inOperation(
          'ODBC.clearMetadataCache',
          _service.clearMetadataCache,
        ),
      );

  Future<Result<void>> cancelStream(int streamId) => OdbcErrorBoundary.runVoid(
        'cancelStream',
        () => _ops.inOperation(
          'ODBC.cancelStream',
          () => _service.cancelStream(streamId),
        ),
      );

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      OdbcErrorBoundary.run(
        'executeAsyncStart',
        () => _ops.inOperation(
          'ODBC.executeAsyncStart',
          () => _service.executeAsyncStart(connectionId, sql),
        ),
      );

  Future<Result<int>> asyncPoll(int requestId) => OdbcErrorBoundary.run(
        'asyncPoll',
        () => _ops.inOperation(
          'ODBC.asyncPoll',
          () => _service.asyncPoll(requestId),
        ),
      );

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      OdbcErrorBoundary.run(
        'asyncGetResult',
        () => _ops.inOperation(
          'ODBC.asyncGetResult',
          () => _service.asyncGetResult(
            requestId,
            maxBufferBytes: maxBufferBytes,
          ),
        ),
      );

  Future<Result<void>> asyncCancel(int requestId) => OdbcErrorBoundary.runVoid(
        'asyncCancel',
        () => _ops.inOperation(
          'ODBC.asyncCancel',
          () => _service.asyncCancel(requestId),
        ),
      );

  Future<Result<void>> asyncFree(int requestId) => OdbcErrorBoundary.runVoid(
        'asyncFree',
        () => _ops.inOperation(
          'ODBC.asyncFree',
          () => _service.asyncFree(requestId),
        ),
      );

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.run(
        'streamStartAsync',
        () => _ops.inOperation(
          'ODBC.streamStartAsync',
          () => _service.streamStartAsync(
            connectionId,
            sql,
            fetchSize: fetchSize,
            chunkSize: chunkSize,
          ),
        ),
      );

  Future<Result<int>> streamPollAsync(int streamId) => OdbcErrorBoundary.run(
        'streamPollAsync',
        () => _ops.inOperation(
          'ODBC.streamPollAsync',
          () => _service.streamPollAsync(streamId),
        ),
      );

  Future<String?> detectDriver(String connectionString) => _ops.inOperation(
        'ODBC.detectDriver',
        () => _service.detectDriver(connectionString),
      );
}
