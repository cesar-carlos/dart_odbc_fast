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
          resultEncodingWire: request.resultEncodingWire,
          paramsBuffer: request.paramsBuffer,
        );
        sendPort.send(IntResponse(request.requestId, streamId));

      case StreamStartAsyncRequest():
        final streamId = conn.streamStartAsync(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
          resultEncodingWire: request.resultEncodingWire,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamMultiStartBatchedRequest():
        final params = Uint8List.fromList(request.serializedParams);
        final streamId = params.isEmpty
            ? conn.streamMultiStartBatched(
                request.connectionId,
                request.sql,
                fetchSize: request.fetchSize,
                chunkSize: request.chunkSize,
                resultEncodingWire: request.resultEncodingWire,
              )
            : conn.streamMultiStartBatchedParams(
                request.connectionId,
                request.sql,
                params,
                fetchSize: request.fetchSize,
                chunkSize: request.chunkSize,
                resultEncodingWire: request.resultEncodingWire,
              );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamMultiStartAsyncRequest():
        final params = Uint8List.fromList(request.serializedParams);
        final streamId = params.isEmpty
            ? conn.streamMultiStartAsync(
                request.connectionId,
                request.sql,
                fetchSize: request.fetchSize,
                chunkSize: request.chunkSize,
                resultEncodingWire: request.resultEncodingWire,
              )
            : conn.streamMultiStartAsyncParams(
                request.connectionId,
                request.sql,
                params,
                fetchSize: request.fetchSize,
                chunkSize: request.chunkSize,
                resultEncodingWire: request.resultEncodingWire,
              );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamPollAsyncRequest():
        final status = conn.streamPollAsync(request.streamId);
        sendPort.send(IntResponse(request.requestId, status ?? -1));

      case StreamPollFetchRequest():
        final status = conn.streamPollAsync(request.streamId) ?? -1;
        if (status != 1) {
          // Not ready: return status only (pending / done / error / cancelled).
          sendPort.send(
            StreamPollFetchResponse(request.requestId, status: status),
          );
          break;
        }
        final result = conn.streamFetch(
          request.streamId,
          bufferSize: request.bufferSize,
        );
        sendPort.send(
          isolateStreamPollFetchResponse(
            requestId: request.requestId,
            status: status,
            success: result.success,
            data: result.data,
            hasMore: result.hasMore,
            error: result.success ? null : conn.getError(),
          ),
        );

      case StreamFetchRequest():
        final result = conn.streamFetch(
          request.streamId,
          bufferSize: request.bufferSize,
        );
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
