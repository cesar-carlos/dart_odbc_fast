import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:result_dart/result_dart.dart';

/// Administrative, observability, and async-lifecycle operations for the ODBC
/// repository.
abstract interface class IAdminRepository {
  Future<Result<OdbcMetrics>> getMetrics();

  Future<AsyncWorkerPoolStats?> getWorkerPoolStats();

  Stream<OdbcEvent> get events;

  void dispose();

  Future<Result<Map<String, String>>> getVersion();

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  );

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId);

  Future<Result<Unit>> setLogLevel(int level);

  Future<Result<Unit>> setAuditEnabled({required bool enabled});

  Future<Result<Map<String, Object?>>> getAuditStatus();

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({int limit = 0});

  Future<Result<Unit>> clearAuditEvents();

  Future<Result<Unit>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  });

  Future<Result<Map<String, Object?>>> metadataCacheStats();

  Future<Result<Unit>> clearMetadataCache();

  Future<Result<Unit>> cancelStream(int streamId);

  Future<Result<int>> executeAsyncStart(String connectionId, String sql);

  Future<Result<int>> asyncPoll(int requestId);

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  });

  Future<Result<Unit>> asyncCancel(int requestId);

  Future<Result<Unit>> asyncFree(int requestId);

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  });

  Future<Result<int>> streamPollAsync(int streamId);
}
