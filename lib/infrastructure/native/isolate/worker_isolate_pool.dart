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
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, poolId),
        );

      case PoolGetConnectionRequest():
        final connId = conn.poolGetConnection(request.poolId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, connId),
        );

      case PoolReleaseConnectionRequest():
        final ok = conn.poolReleaseConnection(request.connectionId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case PoolHealthCheckRequest():
        final ok = conn.poolHealthCheck(request.poolId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case PoolGetStateRequest():
        final state = conn.poolGetState(request.poolId);
        if (state != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            PoolStateResponse(
              request.requestId,
              size: state.size,
              idle: state.idle,
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            PoolStateResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case PoolGetStateJsonRequest():
        final payload = conn.poolGetStateJson(request.poolId);
        if (payload != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              payload: jsonEncode(payload),
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case PoolSetSizeRequest():
        final ok = conn.poolSetSize(request.poolId, request.newMaxSize);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case PoolCloseRequest():
        final ok = conn.poolClose(request.poolId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      default:
        throw StateError('Unexpected pool request: ${request.type}');
    }
  }
}
