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
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, streamId),
        );

      case StreamStartBatchedRequest():
        final streamId = conn.streamStartBatched(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
          resultEncodingWire: request.resultEncodingWire,
          paramsBuffer: request.paramsBuffer,
        );
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, streamId),
        );

      case StreamStartAsyncRequest():
        final streamId = conn.streamStartAsync(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
          resultEncodingWire: request.resultEncodingWire,
        );
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, streamId ?? 0),
        );

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
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, streamId ?? 0),
        );

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
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, streamId ?? 0),
        );

      case StreamPollAsyncRequest():
        final status = conn.streamPollAsync(request.streamId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          IntResponse(request.requestId, status ?? -1),
        );

      case StreamPollFetchRequest():
        final status = conn.streamPollAsync(request.streamId) ?? -1;
        if (status != 1) {
          // Not ready: return status only (pending / done / error / cancelled).
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            StreamPollFetchResponse(request.requestId, status: status),
          );
          break;
        }
        final result = conn.streamFetch(
          request.streamId,
          bufferSize: request.bufferSize,
        );
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          isolateStreamPollFetchResponse(
            requestId: request.requestId,
            status: status,
            success: result.success,
            data: result.data,
            hasMore: result.hasMore,
            error: result.success ? null : _workerError(conn),
          ),
        );

      case StreamFetchRequest():
        final result = conn.streamFetch(
          request.streamId,
          bufferSize: request.bufferSize,
        );
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          streamDataResponse(
            requestId: request.requestId,
            success: result.success,
            data: result.data,
            hasMore: result.hasMore,
            error: result.success ? null : _workerError(conn),
          ),
        );

      case StreamCancelRequest():
        final ok = conn.streamCancel(request.streamId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case StreamCloseRequest():
        final ok = conn.streamClose(request.streamId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      default:
        throw StateError('Unexpected stream request: ${request.type}');
    }
  }
}
