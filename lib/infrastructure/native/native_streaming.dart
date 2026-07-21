part of 'native_odbc_connection.dart';

const _nativeStreamAsyncStatusPending = 0;
const _nativeStreamAsyncStatusReady = 1;
const _nativeStreamAsyncStatusDone = 2;
const _nativeStreamAsyncStatusError = -1;
const _nativeStreamAsyncStatusCancelled = -2;

mixin _NativeStreaming on _NativeOdbcState {
  /// Gets performance and operational metrics.
  ///
  /// Returns [OdbcMetrics] containing query counts, error counts,
  /// uptime, and latency information, or null on failure.
  /// Returns engine version (api + abi) for compatibility checks.
  Map<String, String>? getVersion() => _native.getVersion();

  OdbcMetrics? getMetrics() {
    final metrics = _native.getMetrics();
    if (metrics == null) {
      return null;
    }
    return domain.OdbcMetrics(
      queryCount: metrics.queryCount,
      errorCount: metrics.errorCount,
      uptimeSecs: metrics.uptimeSecs,
      totalLatencyMillis: metrics.totalLatencyMillis,
      avgLatencyMillis: metrics.avgLatencyMillis,
    );
  }

  ///
  /// Clears the prepared statement cache.
  ///
  /// Returns true on success, false on failure.
  bool clearStatementCache() => _native.clearStatementCache();

  /// Starts a low-level streaming query and returns a native stream ID.
  int streamStart(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) =>
      _native.streamStart(
        connectionId,
        sql,
        chunkSize: chunkSize,
      );

  /// Starts a low-level batched streaming query and returns stream ID.
  int streamStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
    Uint8List? paramsBuffer,
  }) =>
      _native.streamStartBatched(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
        resultEncodingWire: resultEncodingWire,
        paramsBuffer: paramsBuffer,
      );

  /// Fetches the next chunk for a low-level native stream.
  bindings.StreamFetchResult streamFetch(
    int streamId, {
    int? bufferSize,
  }) =>
      _native.streamFetch(streamId, bufferSize: bufferSize);

  /// Requests cancellation for a low-level native stream.
  bool streamCancel(int streamId) => _native.streamCancel(streamId);

  /// Closes a low-level native stream.
  bool streamClose(int streamId) => _native.streamClose(streamId);

  /// Executes a SQL query and returns results as a batched stream.
  ///
  /// Uses cursor-based batching; each batch is a complete protocol message.
  /// [fetchSize] rows per batch, [chunkSize] buffer size in bytes.
  /// When [resultEncoding] is not [ResultEncoding.rowMajor] and the native
  /// library exports `odbc_stream_start_batched_options`, batches use columnar
  /// v2 wire layout.
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
    bool lazyStrings = false,
    Uint8List? paramsBuffer,
  }) async* {
    final streamId = _native.streamStartBatched(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      resultEncodingWire: resultEncoding.wireCode,
      paramsBuffer: paramsBuffer,
    );

    if (streamId == 0) {
      throw Exception('Failed to start batched stream: ${_native.getError()}');
    }

    final pending = BinaryFrameAccumulator();
    var completed = false;
    try {
      while (true) {
        final result = _native.streamFetch(streamId, bufferSize: chunkSize);

        if (!result.success) {
          throw Exception('Stream fetch failed: ${_native.getError()}');
        }

        final data = result.data;
        if (data == null || data.isEmpty) {
          break;
        }
        pending.add(data);

        for (final msg in pending.drainFrames()) {
          yield decodeBatchedStreamFrame(
            msg,
            lazyStrings: lazyStrings,
          );
        }

        if (!result.hasMore) break;
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
      completed = true;
    } finally {
      if (!completed) {
        _native.streamCancel(streamId);
      }
      _native.streamClose(streamId);
    }
  }

  /// Like [streamQueryBatched] but decodes columnar v2 frames directly to
  /// [TypedColumnarResult] without a row-major intermediate.
  Stream<TypedColumnarResult> streamQueryColumnarBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    bool lazyStrings = false,
    ResultEncoding resultEncoding = ResultEncoding.columnar,
  }) async* {
    final streamId = _native.streamStartBatched(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      resultEncodingWire: resultEncoding.wireCode,
    );

    if (streamId == 0) {
      throw Exception('Failed to start batched stream: ${_native.getError()}');
    }

    final pending = BinaryFrameAccumulator();
    var completed = false;
    try {
      while (true) {
        final result = _native.streamFetch(streamId, bufferSize: chunkSize);

        if (!result.success) {
          throw Exception('Stream fetch failed: ${_native.getError()}');
        }

        final data = result.data;
        if (data == null || data.isEmpty) {
          break;
        }
        pending.add(data);

        for (final msg in pending.drainFrames()) {
          yield BinaryProtocolParser.parseColumnarToTyped(
            msg,
            lazyStrings: lazyStrings,
          );
        }

        if (!result.hasMore) break;
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
      completed = true;
    } finally {
      if (!completed) {
        _native.streamCancel(streamId);
      }
      _native.streamClose(streamId);
    }
  }

  /// Executes a SQL query and returns results as a batched stream.
  ///
  /// Since v4.1.0 this delegates to [streamQueryBatched] (cursor-based
  /// `odbc_stream_start_batched`) so memory stays bounded to one fetch batch.
  /// [chunkSize] is interpreted as `fetchSize` (rows per yielded chunk).
  ///
  /// Example:
  /// ```dart
  /// await for (final chunk in native.streamQuery(
  ///   connId,
  ///   'SELECT * FROM users',
  /// )) {
  ///   // Process chunk
  /// }
  /// ```
  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) =>
      streamQueryBatched(
        connectionId,
        sql,
        fetchSize: chunkSize,
      );

  /// Legacy buffer-mode streaming via `odbc_stream_start`. Materialises the
  /// full result in native memory before yielding a single parsed chunk.
  /// Prefer [streamQuery] or [streamQueryBatched] for large result sets.
  Stream<ParsedRowBuffer> streamQueryBuffer(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
    bool lazyStrings = false,
  }) async* {
    final streamId =
        _native.streamStart(connectionId, sql, chunkSize: chunkSize);

    if (streamId == 0) {
      throw Exception('Failed to start stream: ${_native.getError()}');
    }

    final buffer = BytesBuilder(copy: false);
    var completed = false;
    try {
      while (true) {
        final result = _native.streamFetch(streamId);

        if (!result.success) {
          throw Exception('Stream fetch failed: ${_native.getError()}');
        }

        final data = result.data;
        if (data == null || data.isEmpty) {
          break;
        }
        buffer.add(data);

        if (!result.hasMore) {
          break;
        }
      }
      if (buffer.length > 0) {
        final parsed = decodeBatchedStreamFrame(
          buffer.toBytes(),
          lazyStrings: lazyStrings,
        );
        yield parsed;
      }
      completed = true;
    } finally {
      if (!completed) {
        _native.streamCancel(streamId);
      }
      _native.streamClose(streamId);
    }
  }

  /// Poll-based async batched streaming via `odbc_stream_start_async`.
  ///
  /// When [resultEncoding] is not [ResultEncoding.rowMajor] and the native
  /// library exports `odbc_stream_start_async_options`, batches use columnar
  /// v2 wire layout.
  Stream<ParsedRowBuffer> streamAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    Duration pollInterval = const Duration(milliseconds: 10),
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
    bool lazyStrings = false,
  }) async* {
    final streamId = _native.streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      resultEncodingWire: resultEncoding.wireCode,
    );
    if (streamId == null || streamId == 0) {
      throw Exception('Failed to start async stream: ${_native.getError()}');
    }

    final pending = BinaryFrameAccumulator();
    var streamDelay = pollInterval ~/ 10;
    if (streamDelay == Duration.zero) {
      streamDelay = const Duration(microseconds: 500);
    }
    final streamMaxDelay = pollInterval;
    var completed = false;
    try {
      while (true) {
        final status = _native.streamPollAsync(streamId);
        if (status == null) {
          throw Exception(
            'Async stream poll unavailable: ${_native.getError()}',
          );
        }
        if (status == _nativeStreamAsyncStatusPending) {
          await Future<void>.delayed(streamDelay);
          if (streamDelay < streamMaxDelay) {
            streamDelay = Duration(
              microseconds: (streamDelay.inMicroseconds * 2)
                  .clamp(0, streamMaxDelay.inMicroseconds),
            );
          }
          continue;
        }
        streamDelay = pollInterval ~/ 10;
        if (streamDelay == Duration.zero) {
          streamDelay = const Duration(microseconds: 500);
        }
        if (status == _nativeStreamAsyncStatusDone) {
          break;
        }
        if (status == _nativeStreamAsyncStatusError ||
            status == _nativeStreamAsyncStatusCancelled) {
          throw Exception('Async stream failed with status $status');
        }
        if (status != _nativeStreamAsyncStatusReady) {
          throw Exception('Unexpected async stream status: $status');
        }

        final result = _native.streamFetch(streamId, bufferSize: chunkSize);
        if (!result.success) {
          throw Exception('Async stream fetch failed: ${_native.getError()}');
        }

        final data = result.data;
        if (data != null && data.isNotEmpty) {
          pending.add(data);
          for (final msg in pending.drainFrames()) {
            yield decodeBatchedStreamFrame(
              msg,
              lazyStrings: lazyStrings,
            );
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
        _native.streamCancel(streamId);
      }
      _native.streamClose(streamId);
    }
  }

  /// Disposes of native resources.
  ///
  /// Should be called when the connection is no longer needed to free
  /// native resources. After calling this, the instance should not be used.
  void dispose() {
    _native.dispose();
    _isInitialized = false;
  }
}
