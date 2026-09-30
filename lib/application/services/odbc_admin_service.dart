import 'dart:async';

import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Admin / lifecycle capability delegate for the ODBC service façade.
class OdbcAdminService {
  OdbcAdminService(this._repository) {
    _repoEventsSub = _repository.events.listen(_eventsController.add);
  }

  final IOdbcRepository _repository;

  final StreamController<OdbcEvent> _eventsController =
      StreamController<OdbcEvent>.broadcast();
  late final StreamSubscription<OdbcEvent> _repoEventsSub;

  Stream<OdbcEvent> get events => _eventsController.stream;

  Future<void> closeEvents() async {
    await _repoEventsSub.cancel();
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  Future<Result<void>> initialize() =>
      OdbcErrorBoundary.runVoid('initialize', _repository.initialize);

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) =>
      OdbcErrorBoundary.run(
        'connect',
        () => _repository.connect(connectionString, options: options),
      );

  Future<Result<void>> disconnect(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'disconnect',
        () => _repository.disconnect(connectionId),
      );

  Future<Result<OdbcMetrics>> getMetrics() =>
      OdbcErrorBoundary.run('getMetrics', _repository.getMetrics);

  bool isInitialized() => _repository.isInitialized();

  Future<Result<void>> clearStatementCache() => OdbcErrorBoundary.runVoid(
        'clearStatementCache',
        _repository.clearStatementCache,
      );

  Future<Result<void>> clearAllStatements() => OdbcErrorBoundary.runVoid(
        'clearAllStatements',
        _repository.clearAllStatements,
      );

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      OdbcErrorBoundary.run(
        'getPreparedStatementsMetrics',
        _repository.getPreparedStatementsMetrics,
      );

  Future<Result<Map<String, String>>> getVersion() =>
      OdbcErrorBoundary.run('getVersion', _repository.getVersion);

  Future<Result<void>> validateConnectionString(String connectionString) =>
      OdbcErrorBoundary.runVoid(
        'validateConnectionString',
        () => _repository.validateConnectionString(connectionString),
      );

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) =>
      OdbcErrorBoundary.run(
        'getDriverCapabilities',
        () => _repository.getDriverCapabilities(connectionString),
      );

  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() =>
      _repository.getWorkerPoolStats();

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'getConnectionDbmsInfo',
        () => _repository.getConnectionDbmsInfo(connectionId),
      );

  Future<Result<void>> setLogLevel(int level) => OdbcErrorBoundary.runVoid(
        'setLogLevel',
        () => _repository.setLogLevel(level),
      );

  Future<Result<void>> setAuditEnabled({required bool enabled}) =>
      OdbcErrorBoundary.runVoid(
        'setAuditEnabled',
        () => _repository.setAuditEnabled(enabled: enabled),
      );

  Future<Result<Map<String, Object?>>> getAuditStatus() =>
      OdbcErrorBoundary.run(
        'getAuditStatus',
        _repository.getAuditStatus,
      );

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({int limit = 0}) =>
      OdbcErrorBoundary.run(
        'getAuditEvents',
        () => _repository.getAuditEvents(limit: limit),
      );

  Future<Result<void>> clearAuditEvents() => OdbcErrorBoundary.runVoid(
        'clearAuditEvents',
        _repository.clearAuditEvents,
      );

  Future<Result<void>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      OdbcErrorBoundary.runVoid(
        'metadataCacheEnable',
        () => _repository.metadataCacheEnable(
          maxEntries: maxEntries,
          ttlSeconds: ttlSeconds,
        ),
      );

  Future<Result<Map<String, Object?>>> metadataCacheStats() =>
      OdbcErrorBoundary.run(
        'metadataCacheStats',
        _repository.metadataCacheStats,
      );

  Future<Result<void>> clearMetadataCache() => OdbcErrorBoundary.runVoid(
        'clearMetadataCache',
        _repository.clearMetadataCache,
      );

  Future<Result<void>> cancelStream(int streamId) => OdbcErrorBoundary.runVoid(
        'cancelStream',
        () => _repository.cancelStream(streamId),
      );

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      OdbcErrorBoundary.run(
        'executeAsyncStart',
        () => _repository.executeAsyncStart(connectionId, sql),
      );

  Future<Result<int>> asyncPoll(int requestId) => OdbcErrorBoundary.run(
        'asyncPoll',
        () => _repository.asyncPoll(requestId),
      );

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      OdbcErrorBoundary.run(
        'asyncGetResult',
        () => _repository.asyncGetResult(
          requestId,
          maxBufferBytes: maxBufferBytes,
        ),
      );

  Future<Result<void>> asyncCancel(int requestId) => OdbcErrorBoundary.runVoid(
        'asyncCancel',
        () => _repository.asyncCancel(requestId),
      );

  Future<Result<void>> asyncFree(int requestId) => OdbcErrorBoundary.runVoid(
        'asyncFree',
        () => _repository.asyncFree(requestId),
      );

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.run(
        'streamStartAsync',
        () => _repository.streamStartAsync(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<int>> streamPollAsync(int streamId) => OdbcErrorBoundary.run(
        'streamPollAsync',
        () => _repository.streamPollAsync(streamId),
      );

  Future<String?> detectDriver(String connectionString) =>
      _repository.detectDriver(connectionString);
}
