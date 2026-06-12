part of 'message_protocol.dart';

enum RequestType {
  initialize,
  setLogLevel,
  validateConnectionString,
  getDriverCapabilities,
  getConnectionDbmsInfo,
  connect,
  disconnect,
  executeQueryParams,
  executeQueryMulti,
  executeQueryMultiParams,
  beginTransaction,
  commitTransaction,
  rollbackTransaction,
  savepointCreate,
  savepointRollback,
  savepointRelease,
  prepare,
  executePrepared,
  cancelStatement,
  closeStatement,
  streamStart,
  streamStartBatched,
  streamStartAsync,
  streamMultiStartBatched,
  streamMultiStartAsync,
  streamPollAsync,
  streamFetch,
  streamCancel,
  streamClose,
  clearAllStatements,
  poolCreate,
  poolGetConnection,
  poolReleaseConnection,
  poolHealthCheck,
  poolGetState,
  poolGetStateJson,
  poolSetSize,
  poolClose,
  bulkInsertArray,
  bulkInsertParallel,
  getVersion,
  getMetrics,
  getCacheMetrics,
  clearCache,
  metadataCacheEnable,
  metadataCacheStats,
  metadataCacheClear,
  catalogTables,
  catalogColumns,
  catalogTypeInfo,
  catalogPrimaryKeys,
  catalogForeignKeys,
  catalogIndexes,
  getError,
  getStructuredError,
  getStructuredErrorForConnection,
  detectDriver,
  auditEnable,
  auditGetEvents,
  auditGetStatus,
  auditClear,
  executeAsyncStart,
  executeAsyncStartParams,
  asyncPoll,
  asyncGetResult,
  asyncCancel,
  asyncFree,
}

/// Base class for worker requests. All subclasses must be sendable.
sealed class WorkerRequest {
  const WorkerRequest(this.requestId, this.type);
  final int requestId;
  final RequestType type;
}

/// Initialize ODBC environment.
class InitializeRequest extends WorkerRequest {
  const InitializeRequest(int requestId)
      : super(requestId, RequestType.initialize);
}

/// Set native engine log verbosity.
class SetLogLevelRequest extends WorkerRequest {
  const SetLogLevelRequest(int requestId, this.level)
      : super(requestId, RequestType.setLogLevel);
  final int level;
}

/// Validate connection string without connecting.
class ValidateConnectionStringRequest extends WorkerRequest {
  const ValidateConnectionStringRequest(int requestId, this.connectionString)
      : super(requestId, RequestType.validateConnectionString);
  final String connectionString;
}

/// Get driver capabilities JSON payload from connection string.
class GetDriverCapabilitiesRequest extends WorkerRequest {
  const GetDriverCapabilitiesRequest(int requestId, this.connectionString)
      : super(requestId, RequestType.getDriverCapabilities);
  final String connectionString;
}

/// Get live DBMS information JSON payload for an open native connection.
class GetConnectionDbmsInfoRequest extends WorkerRequest {
  const GetConnectionDbmsInfoRequest(int requestId, this.connectionId)
      : super(requestId, RequestType.getConnectionDbmsInfo);
  final int connectionId;
}

/// Establish database connection.
class ConnectRequest extends WorkerRequest {
  const ConnectRequest(
    int requestId,
    this.connectionString, {
    this.timeoutMs = 0,
  }) : super(requestId, RequestType.connect);
  final String connectionString;
  final int timeoutMs;
}

/// Disconnect and close connection.
class DisconnectRequest extends WorkerRequest {
  const DisconnectRequest(int requestId, this.connectionId)
      : super(requestId, RequestType.disconnect);
  final int connectionId;
}

/// Get engine version (api + abi).
class GetVersionRequest extends WorkerRequest {
  const GetVersionRequest(int requestId)
      : super(requestId, RequestType.getVersion);
}

/// Get metrics.
class GetMetricsRequest extends WorkerRequest {
  const GetMetricsRequest(int requestId)
      : super(requestId, RequestType.getMetrics);
}

/// Get cache metrics.
class GetCacheMetricsRequest extends WorkerRequest {
  const GetCacheMetricsRequest(int requestId)
      : super(requestId, RequestType.getCacheMetrics);
}

/// Clear cache.
class ClearCacheRequest extends WorkerRequest {
  const ClearCacheRequest(int requestId)
      : super(requestId, RequestType.clearCache);
}

/// Enable/reconfigure metadata cache.
class MetadataCacheEnableRequest extends WorkerRequest {
  const MetadataCacheEnableRequest(
    int requestId, {
    required this.maxEntries,
    required this.ttlSeconds,
  }) : super(requestId, RequestType.metadataCacheEnable);

  final int maxEntries;
  final int ttlSeconds;
}

/// Get metadata cache stats as JSON payload.
class MetadataCacheStatsRequest extends WorkerRequest {
  const MetadataCacheStatsRequest(int requestId)
      : super(requestId, RequestType.metadataCacheStats);
}

/// Clear metadata cache entries.
class MetadataCacheClearRequest extends WorkerRequest {
  const MetadataCacheClearRequest(int requestId)
      : super(requestId, RequestType.metadataCacheClear);
}

/// Get last error message.
class GetErrorRequest extends WorkerRequest {
  const GetErrorRequest(int requestId) : super(requestId, RequestType.getError);
}

/// Get structured error.
class GetStructuredErrorRequest extends WorkerRequest {
  const GetStructuredErrorRequest(int requestId)
      : super(requestId, RequestType.getStructuredError);
}

/// Get structured error scoped to a specific connection.
class GetStructuredErrorForConnectionRequest extends WorkerRequest {
  const GetStructuredErrorForConnectionRequest(int requestId, this.connectionId)
      : super(requestId, RequestType.getStructuredErrorForConnection);

  final int connectionId;
}

/// Detect database driver from connection string.
class DetectDriverRequest extends WorkerRequest {
  const DetectDriverRequest(int requestId, this.connectionString)
      : super(requestId, RequestType.detectDriver);
  final String connectionString;
}

/// Enable/disable audit logging.
class AuditEnableRequest extends WorkerRequest {
  const AuditEnableRequest(int requestId, {required this.enabled})
      : super(requestId, RequestType.auditEnable);
  final bool enabled;
}

/// Get audit events JSON payload.
class AuditGetEventsRequest extends WorkerRequest {
  const AuditGetEventsRequest(int requestId, {this.limit = 0})
      : super(requestId, RequestType.auditGetEvents);
  final int limit;
}

/// Get audit status JSON payload.
class AuditGetStatusRequest extends WorkerRequest {
  const AuditGetStatusRequest(int requestId)
      : super(requestId, RequestType.auditGetStatus);
}

/// Clear all audit events.
class AuditClearRequest extends WorkerRequest {
  const AuditClearRequest(int requestId)
      : super(requestId, RequestType.auditClear);
}

/// Base class for worker responses. All subclasses must be sendable.
sealed class WorkerResponse {
  const WorkerResponse(this.requestId);
  final int requestId;
}

/// Response for initialize.
class InitializeResponse extends WorkerResponse {
  const InitializeResponse(super.requestId, {required this.success});
  final bool success;
}

/// Response for connect.
class ConnectResponse extends WorkerResponse {
  const ConnectResponse(super.requestId, this.connectionId, {this.error});
  final int connectionId;
  final String? error;
}

/// Response for operations returning bool.
class BoolResponse extends WorkerResponse {
  const BoolResponse(super.requestId, {required this.value});
  final bool value;
}

/// Response for query/exec operations returning binary or error.
class QueryResponse extends WorkerResponse {
  QueryResponse(
    super.requestId, {
    Uint8List? data,
    TransferableTypedData? transferableData,
    this.error,
  })  : _data = data,
        _transferableData = transferableData;

  Uint8List? _data;
  final TransferableTypedData? _transferableData;
  final String? error;

  Uint8List? get data {
    final data = _data;
    if (data != null) {
      return data;
    }
    final transferableData = _transferableData;
    if (transferableData == null) {
      return null;
    }
    return _data = transferableData.materialize().asUint8List();
  }
}

/// Response for operations returning int (stmtId, poolId, connId, rowCount).
class IntResponse extends WorkerResponse {
  const IntResponse(super.requestId, this.value);
  final int value;
}

/// Response for pool state.
class MetricsResponse extends WorkerResponse {
  const MetricsResponse(
    super.requestId, {
    this.queryCount = 0,
    this.errorCount = 0,
    this.uptimeSecs = 0,
    this.totalLatencyMillis = 0,
    this.avgLatencyMillis = 0,
    this.error,
  });
  final int queryCount;
  final int errorCount;
  final int uptimeSecs;
  final int totalLatencyMillis;
  final int avgLatencyMillis;
  final String? error;
}

/// Response for cache metrics (sendable record).
class CacheMetricsResponse extends WorkerResponse {
  const CacheMetricsResponse(
    super.requestId, {
    this.cacheSize = 0,
    this.cacheMaxSize = 0,
    this.cacheHits = 0,
    this.cacheMisses = 0,
    this.totalPrepares = 0,
    this.totalExecutions = 0,
    this.memoryUsageBytes = 0,
    this.avgExecutionsPerStmt = 0.0,
    this.error,
  });
  final int cacheSize;
  final int cacheMaxSize;
  final int cacheHits;
  final int cacheMisses;
  final int totalPrepares;
  final int totalExecutions;
  final int memoryUsageBytes;
  final double avgExecutionsPerStmt;
  final String? error;
}

/// Response for clear cache.
class ClearCacheResponse extends WorkerResponse {
  const ClearCacheResponse(super.requestId, {this.error});
  final String? error;
}

/// Response for engine version.
class VersionResponse extends WorkerResponse {
  const VersionResponse(super.requestId, {this.api = '', this.abi = ''});
  final String api;
  final String abi;
}

/// Response for getError.
class GetErrorResponse extends WorkerResponse {
  const GetErrorResponse(super.requestId, this.message);
  final String message;
}

/// Response for getStructuredError (sendable fields only).
class StructuredErrorResponse extends WorkerResponse {
  const StructuredErrorResponse(
    super.requestId, {
    this.message = '',
    this.sqlStateString,
    this.nativeCode,
    this.error,
  });
  final String message;
  final String? sqlStateString;
  final int? nativeCode;
  final String? error;
}

/// Response for detectDriver.
class DetectDriverResponse extends WorkerResponse {
  const DetectDriverResponse(super.requestId, this.driverName);
  final String? driverName;
}

/// Response carrying JSON payload for audit operations.
class AuditPayloadResponse extends WorkerResponse {
  const AuditPayloadResponse(super.requestId, {this.payload, this.error});
  final String? payload;
  final String? error;
}

/// Response for connection string validation.
class ValidateConnectionStringResponse extends WorkerResponse {
  const ValidateConnectionStringResponse(
    super.requestId, {
    required this.isValid,
    this.errorMessage,
  });

  final bool isValid;
  final String? errorMessage;
}

/// Response for stream fetch operation.
