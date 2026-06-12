part of 'native_odbc_connection.dart';

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
  }) =>
      _native.streamStartBatched(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
        resultEncodingWire: resultEncodingWire,
      );

  /// Fetches the next chunk for a low-level native stream.
  bindings.StreamFetchResult streamFetch(int streamId) =>
      _native.streamFetch(streamId);

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
        pending.add(data);

        for (final msg in pending.drainFrames()) {
          yield BinaryProtocolParser.parse(msg);
        }

        if (!result.hasMore) break;
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
    } finally {
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
  }) async* {
    final streamId =
        _native.streamStart(connectionId, sql, chunkSize: chunkSize);

    if (streamId == 0) {
      throw Exception('Failed to start stream: ${_native.getError()}');
    }

    final buffer = BytesBuilder(copy: false);
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
        final parsed = BinaryProtocolParser.parse(buffer.toBytes());
        yield parsed;
      }
    } finally {
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
