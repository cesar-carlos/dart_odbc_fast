part of 'native_odbc_connection.dart';

mixin _NativeAsyncAudit on _NativeOdbcState {
  /// Typed wrapper for native audit APIs.
  OdbcAuditLogger get auditLogger => _auditLogger;

  /// Whether the loaded native library supports audit FFI endpoints.
  bool get supportsAuditApi => _native.supportsAuditApi;

  /// Whether the loaded native library supports async execute FFI endpoints.
  bool get supportsAsyncExecuteApi => _native.supportsAsyncExecuteApi;

  /// Whether async execute also supports serialized parameter buffers.
  bool get supportsAsyncExecuteParamsApi =>
      _native.supportsAsyncExecuteParamsApi;

  /// Whether parameterized query execution can request columnar result
  /// encodings. When false, callers fall back to row-major v1.
  bool get supportsResultEncodingOptions =>
      _native.supportsResultEncodingOptions;

  /// Whether the loaded native library supports async stream FFI endpoints.
  bool get supportsAsyncStreamApi => _native.supportsAsyncStreamApi;

  /// Whether the loaded native library supports metadata cache FFI endpoints.
  bool get supportsMetadataCacheApi => _native.supportsMetadataCacheApi;

  /// Enables/disables native audit event collection.
  bool setAuditEnabled({required bool enabled}) =>
      _native.setAuditEnabled(enabled: enabled);

  /// Clears in-memory native audit events.
  bool clearAuditEvents() => _native.clearAuditEvents();

  /// Enables metadata cache in native engine.
  bool metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      _native.metadataCacheEnable(
        maxEntries: maxEntries,
        ttlSeconds: ttlSeconds,
      );

  /// Returns metadata cache stats JSON payload.
  String? getMetadataCacheStatsJson() => _native.metadataCacheStatsJson();

  /// Clears metadata cache entries.
  bool clearMetadataCache() => _native.metadataCacheClear();

  /// Starts non-blocking query execution and returns async request ID.
  int? executeAsyncStart(int connectionId, String sql) =>
      _native.executeAsyncStart(connectionId, sql);

  /// Starts non-blocking parameterized query execution.
  int? executeAsyncStartParams(
    int connectionId,
    String sql,
    Uint8List? serializedParams, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _native.executeAsyncStartParams(
        connectionId,
        sql,
        serializedParams,
        resultEncoding: resultEncoding,
      );

  /// Polls async request status:
  /// `0` pending, `1` ready, `-1` error, `-2` cancelled.
  int? asyncPoll(int requestId) => _native.asyncPoll(requestId);

  /// Retrieves binary result for a completed async request.
  Uint8List? asyncGetResult(int requestId) => _native.asyncGetResult(requestId);

  /// Best-effort cancellation for an async request.
  bool asyncCancel(int requestId) => _native.asyncCancel(requestId);

  /// Frees async request resources.
  bool asyncFree(int requestId) => _native.asyncFree(requestId);

  /// Starts async stream and returns stream ID.
  ///
  /// Returns `null` when API is unavailable. Returns `0` on native failure.
  /// When [resultEncodingWire] is non-zero and the native library exports
  /// `odbc_stream_start_async_options`, columnar v2 batches are used.
  int? streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) =>
      _native.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
        resultEncodingWire: resultEncodingWire,
      );

  /// Polls async stream status:
  /// `0` pending, `1` ready, `2` done, `-1` error, `-2` cancelled.
  int? streamPollAsync(int streamId) => _native.streamPollAsync(streamId);

  /// Gets audit events as JSON payload.
  String? getAuditEventsJson({int limit = 0}) =>
      _native.getAuditEventsJson(limit: limit);

  /// Gets audit status as JSON payload.
  String? getAuditStatusJson() => _native.getAuditStatusJson();

  /// Whether the ODBC environment has been initialized.
  bool get isInitialized => _isInitialized;
}
