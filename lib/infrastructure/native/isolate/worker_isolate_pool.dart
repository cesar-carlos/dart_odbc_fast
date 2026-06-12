part of 'worker_isolate.dart';

mixin _WorkerIsolatePool on _WorkerIsolateState {
  void dispatchPool(
    WorkerRequest request,
    SendPort sendPort,
    NativeOdbcConnection conn,
  ) {
    switch (request) {
      case PoolCreateRequest():
        final poolId = request.optionsJson == null
            ? conn.poolCreate(request.connectionString, request.maxSize)
            : conn.poolCreateWithOptions(
                request.connectionString,
                request.maxSize,
                optionsJson: request.optionsJson,
              );
        sendPort.send(IntResponse(request.requestId, poolId));

      case PoolGetConnectionRequest():
        final connId = conn.poolGetConnection(request.poolId);
        sendPort.send(IntResponse(request.requestId, connId));

      case PoolReleaseConnectionRequest():
        final ok = conn.poolReleaseConnection(request.connectionId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolHealthCheckRequest():
        final ok = conn.poolHealthCheck(request.poolId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolGetStateRequest():
        final state = conn.poolGetState(request.poolId);
        if (state != null) {
          sendPort.send(
            PoolStateResponse(
              request.requestId,
              size: state.size,
              idle: state.idle,
            ),
          );
        } else {
          sendPort.send(
            PoolStateResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case PoolGetStateJsonRequest():
        final payload = conn.poolGetStateJson(request.poolId);
        if (payload != null) {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              payload: jsonEncode(payload),
            ),
          );
        } else {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case PoolSetSizeRequest():
        final ok = conn.poolSetSize(request.poolId, request.newMaxSize);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolCloseRequest():
        final ok = conn.poolClose(request.poolId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      default:
        throw StateError('Unexpected pool request: ${request.type}');
    }
  }
}
