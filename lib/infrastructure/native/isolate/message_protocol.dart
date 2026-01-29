import 'dart:typed_data';

/// Request types for worker isolate communication.
///
/// All values must be sendable across isolate boundaries.
enum RequestType {
  initialize,
  connect,
  disconnect,
  executeQueryParams,
  executeQueryMulti,
  beginTransaction,
  commitTransaction,
  rollbackTransaction,
  savepointCreate,
  savepointRollback,
  savepointRelease,
  prepare,
  executePrepared,
  closeStatement,
  poolCreate,
  poolGetConnection,
  poolReleaseConnection,
  poolHealthCheck,
  poolGetState,
  poolClose,
  bulkInsertArray,
  getMetrics,
  catalogTables,
  catalogColumns,
  catalogTypeInfo,
  getError,
  getStructuredError,
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

/// Execute parameterized query. Params sent as serialized Uint8List.
class ExecuteQueryParamsRequest extends WorkerRequest {
  const ExecuteQueryParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    this.serializedParams, {
    this.maxResultBufferBytes,
  }) : super(requestId, RequestType.executeQueryParams);
  final int connectionId;
  final String sql;
  final Uint8List serializedParams;
  final int? maxResultBufferBytes;
}

/// Execute query returning multiple result sets.
class ExecuteQueryMultiRequest extends WorkerRequest {
  const ExecuteQueryMultiRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.maxResultBufferBytes,
  }) : super(requestId, RequestType.executeQueryMulti);
  final int connectionId;
  final String sql;
  final int? maxResultBufferBytes;
}

/// Begin transaction.
class BeginTransactionRequest extends WorkerRequest {
  const BeginTransactionRequest(
    int requestId,
    this.connectionId,
    this.isolationLevel,
  ) : super(requestId, RequestType.beginTransaction);
  final int connectionId;
  final int isolationLevel;
}

/// Commit transaction.
class CommitTransactionRequest extends WorkerRequest {
  const CommitTransactionRequest(int requestId, this.txnId)
      : super(requestId, RequestType.commitTransaction);
  final int txnId;
}

/// Rollback transaction.
class RollbackTransactionRequest extends WorkerRequest {
  const RollbackTransactionRequest(int requestId, this.txnId)
      : super(requestId, RequestType.rollbackTransaction);
  final int txnId;
}

/// Create savepoint.
class SavepointCreateRequest extends WorkerRequest {
  const SavepointCreateRequest(int requestId, this.txnId, this.name)
      : super(requestId, RequestType.savepointCreate);
  final int txnId;
  final String name;
}

/// Rollback to savepoint.
class SavepointRollbackRequest extends WorkerRequest {
  const SavepointRollbackRequest(int requestId, this.txnId, this.name)
      : super(requestId, RequestType.savepointRollback);
  final int txnId;
  final String name;
}

/// Release savepoint.
class SavepointReleaseRequest extends WorkerRequest {
  const SavepointReleaseRequest(int requestId, this.txnId, this.name)
      : super(requestId, RequestType.savepointRelease);
  final int txnId;
  final String name;
}

/// Prepare SQL statement.
class PrepareRequest extends WorkerRequest {
  const PrepareRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.timeoutMs = 0,
  }) : super(requestId, RequestType.prepare);
  final int connectionId;
  final String sql;
  final int timeoutMs;
}

/// Execute prepared statement. Params sent as serialized Uint8List.
class ExecutePreparedRequest extends WorkerRequest {
  const ExecutePreparedRequest(
    int requestId,
    this.stmtId,
    this.serializedParams,
  ) : super(requestId, RequestType.executePrepared);
  final int stmtId;
  final Uint8List serializedParams;
}

/// Close prepared statement.
class CloseStatementRequest extends WorkerRequest {
  const CloseStatementRequest(int requestId, this.stmtId)
      : super(requestId, RequestType.closeStatement);
  final int stmtId;
}

/// Create connection pool.
class PoolCreateRequest extends WorkerRequest {
  const PoolCreateRequest(
    int requestId,
    this.connectionString,
    this.maxSize,
  ) : super(requestId, RequestType.poolCreate);
  final String connectionString;
  final int maxSize;
}

/// Get connection from pool.
class PoolGetConnectionRequest extends WorkerRequest {
  const PoolGetConnectionRequest(int requestId, this.poolId)
      : super(requestId, RequestType.poolGetConnection);
  final int poolId;
}

/// Release connection to pool.
class PoolReleaseConnectionRequest extends WorkerRequest {
  const PoolReleaseConnectionRequest(int requestId, this.connectionId)
      : super(requestId, RequestType.poolReleaseConnection);
  final int connectionId;
}

/// Health check on pool.
class PoolHealthCheckRequest extends WorkerRequest {
  const PoolHealthCheckRequest(int requestId, this.poolId)
      : super(requestId, RequestType.poolHealthCheck);
  final int poolId;
}

/// Get pool state.
class PoolGetStateRequest extends WorkerRequest {
  const PoolGetStateRequest(int requestId, this.poolId)
      : super(requestId, RequestType.poolGetState);
  final int poolId;
}

/// Close pool.
class PoolCloseRequest extends WorkerRequest {
  const PoolCloseRequest(int requestId, this.poolId)
      : super(requestId, RequestType.poolClose);
  final int poolId;
}

/// Bulk insert.
class BulkInsertArrayRequest extends WorkerRequest {
  const BulkInsertArrayRequest(
    int requestId,
    this.connectionId,
    this.table,
    this.columns,
    this.dataBuffer,
    this.rowCount,
  ) : super(requestId, RequestType.bulkInsertArray);
  final int connectionId;
  final String table;
  final List<String> columns;
  final Uint8List dataBuffer;
  final int rowCount;
}

/// Get metrics.
class GetMetricsRequest extends WorkerRequest {
  const GetMetricsRequest(int requestId)
      : super(requestId, RequestType.getMetrics);
}

/// Catalog tables.
class CatalogTablesRequest extends WorkerRequest {
  const CatalogTablesRequest(
    int requestId,
    this.connectionId, {
    this.catalog = '',
    this.schema = '',
  }) : super(requestId, RequestType.catalogTables);
  final int connectionId;
  final String catalog;
  final String schema;
}

/// Catalog columns.
class CatalogColumnsRequest extends WorkerRequest {
  const CatalogColumnsRequest(int requestId, this.connectionId, this.table)
      : super(requestId, RequestType.catalogColumns);
  final int connectionId;
  final String table;
}

/// Catalog type info.
class CatalogTypeInfoRequest extends WorkerRequest {
  const CatalogTypeInfoRequest(int requestId, this.connectionId)
      : super(requestId, RequestType.catalogTypeInfo);
  final int connectionId;
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
  const QueryResponse(super.requestId, {this.data, this.error});
  final Uint8List? data;
  final String? error;
}

/// Response for operations returning int (stmtId, poolId, connId, rowCount).
class IntResponse extends WorkerResponse {
  const IntResponse(super.requestId, this.value);
  final int value;
}

/// Response for pool state.
class PoolStateResponse extends WorkerResponse {
  const PoolStateResponse(super.requestId, {this.size, this.idle, this.error});
  final int? size;
  final int? idle;
  final String? error;
}

/// Response for metrics (sendable record).
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
