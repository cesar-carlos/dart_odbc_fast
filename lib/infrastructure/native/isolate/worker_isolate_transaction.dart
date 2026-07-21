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

      case XaStartRequest():
        final xid = Xid(
          formatId: request.formatId,
          gtrid: request.gtrid,
          bqual: request.bqual,
        );
        final handle = conn.xaStart(request.connectionId, xid);
        sendPort.send(
          IntResponse(request.requestId, handle?.xaId ?? 0),
        );

      case XaIdRequest():
        final native = conn.native;
        final rc = switch (request.type) {
          RequestType.xaEnd => native.xaEnd(request.xaId),
          RequestType.xaPrepare => native.xaPrepare(request.xaId),
          RequestType.xaCommitPrepared => native.xaCommitPrepared(request.xaId),
          RequestType.xaRollbackPrepared =>
            native.xaRollbackPrepared(request.xaId),
          RequestType.xaCommitOnePhase => native.xaCommitOnePhase(request.xaId),
          RequestType.xaRollbackActive => native.xaRollbackActive(request.xaId),
          _ => -1,
        };
        sendPort.send(IntResponse(request.requestId, rc));

      case XaRecoverRequest():
        final recovered = conn.xaRecover(request.connectionId);
        if (recovered == null) {
          sendPort.send(
            XaRecoverResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        } else {
          sendPort.send(
            XaRecoverResponse(
              request.requestId,
              entries: [
                for (final xid in recovered)
                  XaRecoverEntry(
                    formatId: xid.formatId,
                    gtrid: xid.gtrid,
                    bqual: xid.bqual,
                  ),
              ],
            ),
          );
        }

      case XaResumePreparedRequest():
        final xid = Xid(
          formatId: request.formatId,
          gtrid: request.gtrid,
          bqual: request.bqual,
        );
        final handle = conn.xaResumePrepared(request.connectionId, xid);
        sendPort.send(
          IntResponse(request.requestId, handle?.xaId ?? 0),
        );

      default:
        throw StateError('Unexpected transaction request: ${request.type}');
    }
  }
}
