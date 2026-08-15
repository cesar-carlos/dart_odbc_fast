part of 'async_native_odbc_connection.dart';

mixin _AsyncQueryAsync on _AsyncOdbcState, _AsyncWorkerDispatch {
  /// Starts non-blocking query execution in native layer.
  ///
  /// Returns async request ID (>0) on success, or 0 on failure.
  Future<int> executeAsyncStart(int connectionId, String sql) async {
    final r = await _sendRequest<IntResponse>(
      ExecuteAsyncStartRequest(_nextRequestId(), connectionId, sql),
    );
    return r.value;
  }

  /// Starts non-blocking parameterized execution in native layer.
  ///
  /// Returns async request ID (>0) on success, or 0 on failure/API fallback.
  Future<int> executeAsyncStartParams(
    int connectionId,
    String sql,
    Uint8List? serializedParams, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final bytes = serializedParams == null || serializedParams.isEmpty
        ? Uint8List(0)
        : serializedParams;
    final r = await _sendRequest<IntResponse>(
      ExecuteAsyncStartParamsRequest.withSerializedParams(
        _nextRequestId(),
        connectionId,
        sql,
        bytes,
        resultEncodingWire: resultEncoding.wireCode,
      ),
    );
    return r.value;
  }

  /// Polls async request status.
  ///
  /// Status values: `0` pending, `1` ready, `-1` error, `-2` cancelled.
  Future<int> asyncPoll(int asyncRequestId) async {
    final r = await _sendRequest<IntResponse>(
      AsyncPollRequest(_nextRequestId(), asyncRequestId),
    );
    return r.value;
  }

  /// Retrieves binary result for a completed async request.
  ///
  /// Returns null when request is not ready or has failed.
  Future<Uint8List?> asyncGetResult(
    int asyncRequestId, {
    int? maxBufferBytes,
    int? initialBufferBytes,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      AsyncGetResultRequest(
        _nextRequestId(),
        asyncRequestId,
        maxResultBufferBytes: maxBufferBytes,
        initialResultBufferBytes: initialBufferBytes,
      ),
    );
    if (r.error != null) {
      return null;
    }
    return r.data;
  }

  /// Executes [sql] in non-blocking mode using native async request lifecycle.
  ///
  /// Flow: `start -> poll -> get_result -> free`.
  /// Returns the binary result when execution completes successfully, or `null`
  /// on failure/cancellation/timeout.
  Future<Uint8List?> executeAsync(
    int connectionId,
    String sql, {
    Duration pollInterval = const Duration(milliseconds: 10),
    Duration? timeout,
    int? maxBufferBytes,
  }) async {
    final requestId = await executeAsyncStart(connectionId, sql);
    if (requestId <= 0) {
      return null;
    }
    return _waitForAsyncResult(
      requestId,
      pollInterval: pollInterval,
      timeout: timeout,
      maxBufferBytes: maxBufferBytes,
    );
  }

  Future<Uint8List?> _waitForAsyncResult(
    int requestId, {
    // Kept for backward compatibility; used as the adaptive-backoff ceiling.
    Duration pollInterval = const Duration(milliseconds: 10),
    Duration? timeout,
    int? maxBufferBytes,
    int? initialBufferBytes,
  }) async {
    final effectiveTimeout =
        timeout ?? _requestTimeout ?? _defaultRequestTimeout;
    final timeoutStopwatch = Stopwatch()..start();
    var delay = _pollBackoffMin;
    final maxDelay = pollInterval;

    try {
      while (true) {
        final status = await asyncPoll(requestId);

        switch (status) {
          case 1: // ready
            return await asyncGetResult(
              requestId,
              maxBufferBytes: maxBufferBytes,
              initialBufferBytes: initialBufferBytes,
            );
          case 0: // pending
            if (effectiveTimeout > Duration.zero &&
                timeoutStopwatch.elapsed >= effectiveTimeout) {
              await asyncCancel(requestId);
              return null;
            }
            await Future<void>.delayed(delay);
            // Double the delay on each miss, capped at maxDelay.
            if (delay < maxDelay) {
              delay = Duration(
                microseconds: (delay.inMicroseconds * 2)
                    .clamp(0, maxDelay.inMicroseconds),
              );
            }
          case -1: // error
          case -2: // cancelled
            return null;
          default:
            return null;
        }
      }
    } finally {
      await asyncFree(requestId);
    }
  }

  /// Best-effort cancellation for async request.
  Future<bool> asyncCancel(int asyncRequestId) async {
    final r = await _sendRequest<BoolResponse>(
      AsyncCancelRequest(_nextRequestId(), asyncRequestId),
    );
    return r.value;
  }

  /// Frees async request resources.
  Future<bool> asyncFree(int asyncRequestId) async {
    final r = await _sendRequest<BoolResponse>(
      AsyncFreeRequest(_nextRequestId(), asyncRequestId),
    );
    return r.value;
  }

  /// Enables/disables native audit event collection in the worker.
  Future<bool> setAuditEnabled({required bool enabled}) async {
    final r = await _sendRequest<BoolResponse>(
      AuditEnableRequest(_nextRequestId(), enabled: enabled),
    );
    return r.value;
  }

  /// Clears in-memory audit events in the worker.
  Future<bool> clearAuditEvents() async {
    final r = await _sendRequest<BoolResponse>(
      AuditClearRequest(_nextRequestId()),
    );
    return r.value;
  }

  /// Returns audit events as JSON payload, or null on failure.
  Future<String?> getAuditEventsJson({int limit = 0}) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      AuditGetEventsRequest(_nextRequestId(), limit: limit),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Returns audit status as JSON payload, or null on failure.
  Future<String?> getAuditStatusJson() async {
    final r = await _sendRequest<AuditPayloadResponse>(
      AuditGetStatusRequest(_nextRequestId()),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }
}
