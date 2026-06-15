part of 'odbc_native.dart';

mixin _OdbcNativeStream on _OdbcNativeState, _OdbcNativeHelpers {
  /// Starts a streaming query.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a valid SQL SELECT statement.
  /// The [chunkSize] specifies how many rows to fetch per chunk.
  ///
  /// Returns a stream ID on success, 0 on failure.
  int streamStart(
    int connectionId,
    String sql, {
    int chunkSize = _defaultStreamChunkSize,
  }) {
    return _withSql<int>(
          sql,
          (sqlPtr) => _bindings.odbc_stream_start(
            connectionId,
            sqlPtr,
            chunkSize,
          ),
        ) ??
        0;
  }

  /// Starts async batched streaming query execution.
  ///
  /// Returns stream ID (>0) on success, 0 on native failure, and null when
  /// async stream API is unavailable.
  int? streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) {
    if (!_bindings.supportsAsyncStreamApi) {
      return null;
    }
    return _withSql<int>(
      sql,
      (sqlPtr) {
        if (resultEncodingWire != 0) {
          final optionsId = _bindings.odbc_stream_start_async_options(
            connectionId,
            sqlPtr,
            fetchSize,
            chunkSize,
            resultEncodingWire,
          );
          if (optionsId != null) {
            return optionsId;
          }
        }
        return _bindings.odbc_stream_start_async(
          connectionId,
          sqlPtr,
          fetchSize,
          chunkSize,
        );
      },
    );
  }

  /// Polls async stream status.
  ///
  /// Status values: `0` pending, `1` ready, `2` done, `-1` error,
  /// `-2` cancelled.
  int? streamPollAsync(int streamId) {
    if (!_bindings.supportsAsyncStreamApi) {
      return null;
    }
    final outStatus = malloc<ffi.Int32>()..value = 0;
    try {
      final code = _bindings.odbc_stream_poll_async(streamId, outStatus);
      if (code != 0) {
        return null;
      }
      return outStatus.value;
    } finally {
      malloc.free(outStatus);
    }
  }

  /// Fetches the next chunk of data from a streaming query.
  ///
  /// The [streamId] must be a valid stream identifier from [streamStart].
  ///
  /// Returns a [StreamFetchResult] with success status, data, and hasMore flag.
  StreamFetchResult streamFetch(int streamId) {
    final fetched = streamCallWithBuffer(
      (buf, bufLen, outWritten, hasMore) => _bindings.odbc_stream_fetch(
        streamId,
        buf,
        bufLen,
        outWritten,
        hasMore,
      ),
    );
    if (fetched != null) {
      return StreamFetchResult(
        success: true,
        data: fetched.data,
        hasMore: fetched.hasMore,
      );
    }
    return StreamFetchResult(
      success: false,
      data: null,
      hasMore: false,
    );
  }

  /// Requests cancellation of a batched stream.
  ///
  /// Only effective for streams created with [streamStartBatched].
  /// No-op for buffer-mode streams. The worker exits between batches.
  /// Returns true on success, false if stream_id is invalid.
  bool streamCancel(int streamId) {
    final result = _bindings.odbc_stream_cancel(streamId);
    return result == 0;
  }

  /// Closes a streaming query.
  ///
  /// The [streamId] must be a valid stream identifier.
  /// Returns true on success, false on failure.
  bool streamClose(int streamId) {
    final result = _bindings.odbc_stream_close(streamId);
    return result == 0;
  }

  /// Starts a batched streaming query.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a valid SQL SELECT statement.
  /// The [fetchSize] specifies how many rows to fetch per batch.
  /// The [chunkSize] specifies the buffer size in bytes.
  ///
  /// Returns a stream ID on success, 0 on failure.
  int streamStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) {
    return _withSql<int>(
          sql,
          (sqlPtr) {
            if (resultEncodingWire != 0) {
              final optionsId = _bindings.odbc_stream_start_batched_options(
                connectionId,
                sqlPtr,
                fetchSize,
                chunkSize,
                resultEncodingWire,
              );
              if (optionsId != null) {
                return optionsId;
              }
            }
            return _bindings.odbc_stream_start_batched(
              connectionId,
              sqlPtr,
              fetchSize,
              chunkSize,
            );
          },
        ) ??
        0;
  }

  /// Whether the loaded native library exports the M8 streaming
  /// multi-result FFIs (added in v3.3.0).
  bool get supportsMultiResultStream => _bindings.supportsMultiResultStream;
  bool get supportsAsyncMultiResultStream =>
      _bindings.supportsAsyncMultiResultStream;

  /// Starts a streaming multi-result batch in batched mode.
  ///
  /// Each chunk emitted by `streamFetch` belongs to a frame-based wire
  /// format where every frame carries one multi-result item:
  ///
  ///     [tag: u8] [len: u32 LE] [payload: len bytes]
  ///
  /// `tag = 0` payload is a `binary_protocol` row-buffer; `tag = 1` payload
  /// is `i64 LE` row count. Use `MultiResultStreamDecoder` (Dart) to assemble
  /// items as bytes accumulate. Returns the new stream id, or `null` when
  /// the loaded native library predates v3.3.0.
  int? streamMultiStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) {
    if (!_bindings.supportsMultiResultStream) return null;
    return _withSql<int>(
      sql,
      (sqlPtr) {
        if (resultEncodingWire != 0) {
          final optionsId = _bindings.odbc_stream_multi_start_batched_options(
            connectionId,
            sqlPtr,
            fetchSize,
            chunkSize,
            resultEncodingWire,
          );
          if (optionsId != null) {
            return optionsId;
          }
        }
        return _bindings.odbc_stream_multi_start_batched(
          connectionId,
          sqlPtr,
          chunkSize,
        );
      },
    );
  }

  /// Async variant of [streamMultiStartBatched]. Status is observable via
  /// the existing [streamPollAsync].
  int? streamMultiStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) {
    if (!_bindings.supportsAsyncMultiResultStream) return null;
    return _withSql<int>(
      sql,
      (sqlPtr) {
        if (resultEncodingWire != 0) {
          final optionsId = _bindings.odbc_stream_multi_start_async_options(
            connectionId,
            sqlPtr,
            fetchSize,
            chunkSize,
            resultEncodingWire,
          );
          if (optionsId != null) {
            return optionsId;
          }
        }
        return _bindings.odbc_stream_multi_start_async(
          connectionId,
          sqlPtr,
          chunkSize,
        );
      },
    );
  }
}
