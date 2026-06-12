part of 'worker_isolate.dart';

mixin _WorkerIsolateStream on _WorkerIsolateState {
  void dispatchStream(
    WorkerRequest request,
    SendPort sendPort,
    NativeOdbcConnection conn,
  ) {
    switch (request) {
      case StreamStartRequest():
        final streamId = conn.streamStart(
          request.connectionId,
          request.sql,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId));

      case StreamStartBatchedRequest():
        final streamId = conn.streamStartBatched(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId));

      case StreamStartAsyncRequest():
        final streamId = conn.streamStartAsync(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamMultiStartBatchedRequest():
        final streamId = conn.streamMultiStartBatched(
          request.connectionId,
          request.sql,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamMultiStartAsyncRequest():
        final streamId = conn.streamMultiStartAsync(
          request.connectionId,
          request.sql,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamPollAsyncRequest():
        final status = conn.streamPollAsync(request.streamId);
        sendPort.send(IntResponse(request.requestId, status ?? -1));

      case StreamFetchRequest():
        final result = conn.streamFetch(request.streamId);
        sendPort.send(
          streamDataResponse(
            requestId: request.requestId,
            success: result.success,
            data: result.data,
            hasMore: result.hasMore,
            error: result.success ? null : conn.getError(),
          ),
        );

      case StreamCancelRequest():
        final ok = conn.streamCancel(request.streamId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case StreamCloseRequest():
        final ok = conn.streamClose(request.streamId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      default:
        throw StateError('Unexpected stream request: ${request.type}');
    }
  }
}
