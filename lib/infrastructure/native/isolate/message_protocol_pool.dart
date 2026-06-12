part of 'message_protocol.dart';

class PoolCreateRequest extends WorkerRequest {
  const PoolCreateRequest(
    int requestId,
    this.connectionString,
    this.maxSize, {
    this.optionsJson,
  }) : super(requestId, RequestType.poolCreate);
  final String connectionString;
  final int maxSize;
  final String? optionsJson;
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

/// Get detailed pool state JSON payload.
class PoolGetStateJsonRequest extends WorkerRequest {
  const PoolGetStateJsonRequest(int requestId, this.poolId)
      : super(requestId, RequestType.poolGetStateJson);
  final int poolId;
}

/// Resize pool.
class PoolSetSizeRequest extends WorkerRequest {
  const PoolSetSizeRequest(int requestId, this.poolId, this.newMaxSize)
      : super(requestId, RequestType.poolSetSize);
  final int poolId;
  final int newMaxSize;
}

/// Close pool.
class PoolCloseRequest extends WorkerRequest {
  const PoolCloseRequest(int requestId, this.poolId)
      : super(requestId, RequestType.poolClose);
  final int poolId;
}

/// Bulk insert.
class PoolStateResponse extends WorkerResponse {
  const PoolStateResponse(super.requestId, {this.size, this.idle, this.error});
  final int? size;
  final int? idle;
  final String? error;
}

/// Response for metrics (sendable record).
