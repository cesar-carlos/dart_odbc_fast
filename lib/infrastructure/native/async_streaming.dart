part of 'async_native_odbc_connection.dart';

mixin _AsyncStreaming
    on _AsyncOdbcState, _AsyncWorkerDispatch, _AsyncWorkerLifecycle {
  Future<int> _streamStart(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<int> _streamStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartBatchedRequest(
        _nextRequestId(),
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
        resultEncodingWire: resultEncodingWire,
      ),
    );
    return r.value;
  }

  Future<int> _streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartAsyncRequest(
        _nextRequestId(),
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  /// Starts low-level async stream lifecycle and returns stream ID.
  Future<int> streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    return _streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
  }

  /// Starts a streaming multi-result batch (M8 in v3.3.0). The chunks
  /// emitted by `streamFetch` follow the framed wire format documented in
  /// `MultiResultStreamDecoder`. Returns 0 when the loaded native library
  /// does not export the FFI.
  Future<int> streamMultiStartBatched(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamMultiStartBatchedRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  /// Async variant of [streamMultiStartBatched]. Combine with
  /// `streamPollAsync`.
  Future<int> streamMultiStartAsync(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamMultiStartAsyncRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<int> _streamPollAsync(int streamId) async {
    final r = await _sendRequest<IntResponse>(
      StreamPollAsyncRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Polls low-level async stream status.
  Future<int> streamPollAsync(int streamId) async {
    return _streamPollAsync(streamId);
  }

  Future<StreamFetchResponse> _streamFetch(int streamId) {
    return _sendRequest<StreamFetchResponse>(
      StreamFetchRequest(_nextRequestId(), streamId),
    );
  }

  /// Fetches the next chunk from an active stream in the worker.
  /// Public counterpart of `_streamFetch`, used by callers that drive the
  /// stream lifecycle themselves (e.g. `streamQueryMulti`). New in v3.3.0.
  Future<StreamFetchResponse> streamFetch(int streamId) =>
      _streamFetch(streamId);

  Future<bool> _streamClose(int streamId) async {
    final r = await _sendRequest<BoolResponse>(
      StreamCloseRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Closes an active stream in the worker. Public counterpart of
  /// `_streamClose` for the same reason as [streamFetch]. New in v3.3.0.
  Future<bool> streamClose(int streamId) => _streamClose(streamId);

  /// Cancels an active low-level native stream in the worker.
  Future<bool> streamCancel(int streamId) async {
    final r = await _sendRequest<BoolResponse>(
      StreamCancelRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Runs [sql] in the worker using native batched streaming.
  ///
  /// This path uses `odbc_stream_start_batched` + `odbc_stream_fetch`,
  /// yielding chunks progressively. [maxBufferBytes] caps internal pending
  /// bytes for message framing.
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int? maxBufferBytes,
    int resultEncodingWire = 0,
  }) async* {
    final streamId = await _streamStartBatched(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      resultEncodingWire: resultEncodingWire,
    );
    if (streamId == 0) {
      final workerError = await _safeGetWorkerError();
      throw AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: workerError ?? 'Failed to start batched stream',
      );
    }

    final pending = BinaryFrameAccumulator();
    final limit = maxBufferBytes;
    var completed = false;
    try {
      while (true) {
        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          final workerError = fetched.error ?? await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Batched stream fetch failed',
          );
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          pending.add(data);
          if (limit != null && pending.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }

          for (final msg in pending.drainFrames()) {
            yield BinaryProtocolParser.parse(msg);
          }
        }

        if (!fetched.hasMore) {
          break;
        }
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
      completed = true;
    } finally {
      if (!completed) {
        await streamCancel(streamId);
      }
      await _streamClose(streamId);
    }
  }

  /// Runs [sql] in the worker using native batched streaming.
  ///
  /// Since v4.1.0 this delegates to [streamQueryBatched]. [chunkSize] is
  /// interpreted as `fetchSize` (rows per yielded chunk).
  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
    int? maxBufferBytes,
  }) =>
      streamQueryBatched(
        connectionId,
        sql,
        fetchSize: chunkSize,
        maxBufferBytes: maxBufferBytes,
      );

  /// Legacy buffer-mode streaming via `odbc_stream_start`. Materialises the
  /// full result in the worker before yielding a single parsed chunk.
  Stream<ParsedRowBuffer> streamQueryBuffer(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStart(
      connectionId,
      sql,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      final workerError = await _safeGetWorkerError();
      throw AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: workerError ?? 'Failed to start stream',
      );
    }

    final buffer = BytesBuilder(copy: false);
    final limit = maxBufferBytes;
    var completed = false;
    try {
      while (true) {
        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          final workerError = fetched.error ?? await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Stream fetch failed',
          );
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          buffer.add(data);
          if (limit != null && buffer.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }
        }

        if (!fetched.hasMore) {
          break;
        }
      }

      if (buffer.length > 0) {
        yield BinaryProtocolParser.parse(buffer.toBytes());
      }
      completed = true;
    } finally {
      if (!completed) {
        await streamCancel(streamId);
      }
      await _streamClose(streamId);
    }
  }

  /// Runs [sql] using native async stream lifecycle:
  /// `stream_start_async -> stream_poll_async -> stream_fetch -> stream_close`.
  ///
  /// This is a poll-based non-blocking stream path. It yields full protocol
  /// messages as [ParsedRowBuffer] values.
  Stream<ParsedRowBuffer> streamAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    Duration pollInterval = const Duration(milliseconds: 10),
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      final workerError = await _safeGetWorkerError();
      throw AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: workerError ?? 'Failed to start async stream',
      );
    }

    final pending = BinaryFrameAccumulator();
    final limit = maxBufferBytes;
    var completed = false;
    var streamDelay = _pollBackoffMin;
    final streamMaxDelay = pollInterval;
    try {
      while (true) {
        final status = await _streamPollAsync(streamId);
        if (status == _streamAsyncStatusPending) {
          await Future<void>.delayed(streamDelay);
          if (streamDelay < streamMaxDelay) {
            streamDelay = Duration(
              microseconds: (streamDelay.inMicroseconds * 2)
                  .clamp(0, streamMaxDelay.inMicroseconds),
            );
          }
          continue;
        }
        // Reset backoff when data is ready so subsequent polls for the next
        // batch start fast again.
        streamDelay = _pollBackoffMin;
        if (status == _streamAsyncStatusDone) {
          break;
        }
        if (status == _streamAsyncStatusError ||
            status == _streamAsyncStatusCancelled) {
          final workerError = await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Async stream failed with status $status',
          );
        }
        if (status != _streamAsyncStatusReady) {
          final workerError = await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Unexpected async stream status: $status',
          );
        }

        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          final workerError = fetched.error ?? await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Async stream fetch failed',
          );
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          pending.add(data);
          if (limit != null && pending.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }

          for (final msg in pending.drainFrames()) {
            yield BinaryProtocolParser.parse(msg);
          }
        }
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
      completed = true;
    } finally {
      if (!completed) {
        await streamCancel(streamId);
      }
      await _streamClose(streamId);
    }
  }
}
