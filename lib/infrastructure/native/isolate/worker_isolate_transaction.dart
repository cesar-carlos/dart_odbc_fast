part of 'worker_isolate.dart';

mixin _WorkerIsolateTransaction on _WorkerIsolateState {
  void dispatchTransaction(
    WorkerRequest request,
    SendPort sendPort,
    NativeOdbcConnection conn,
  ) {
    switch (request) {
      case BeginTransactionRequest():
        final txnId = conn.beginTransaction(
          request.connectionId,
          request.isolationLevel,
          savepointDialect: request.savepointDialect,
          accessMode: request.accessMode,
          lockTimeoutMs: request.lockTimeoutMs,
        );
        sendPort.send(IntResponse(request.requestId, txnId));

      case CommitTransactionRequest():
        final ok = conn.commitTransaction(request.txnId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case RollbackTransactionRequest():
        final ok = conn.rollbackTransaction(request.txnId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case SavepointCreateRequest():
        final ok = conn.createSavepoint(request.txnId, request.name);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case SavepointRollbackRequest():
        final ok = conn.rollbackToSavepoint(request.txnId, request.name);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case SavepointReleaseRequest():
        final ok = conn.releaseSavepoint(request.txnId, request.name);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      default:
        throw StateError('Unexpected transaction request: ${request.type}');
    }
  }
}
