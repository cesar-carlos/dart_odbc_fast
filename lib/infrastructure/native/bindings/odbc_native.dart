import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart'
    show PreparedStatementMetrics;
import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart'
    show callWithBuffer, initialBufferSize, maxBufferSize;
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as bindings;
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// Error buffer size for retrieving error messages (4 KB).
const int _errorBufferSize = 4096;

/// Default chunk size for streaming queries (1000 rows).
const int _defaultStreamChunkSize = 1000;

/// Native ODBC bindings wrapper.
///
/// Provides a high-level Dart interface to the native ODBC engine
/// through FFI bindings. Handles connection management, queries,
/// transactions, prepared statements, connection pooling, and streaming.
class OdbcNative {
  /// Creates a new [OdbcNative] instance.
  ///
  /// Automatically loads the ODBC engine library and initializes bindings.
  OdbcNative() {
    _library = loadOdbcLibrary();
    _bindings = bindings.OdbcBindings(_library);
  }

  late final bindings.OdbcBindings _bindings;
  late final ffi.DynamicLibrary _library;

  /// Read-only access to the raw bindings. Use only for new capabilities
  /// implemented in companion modules (e.g. `driver_capabilities_v3.dart`).
  bindings.OdbcBindings get rawBindings => _bindings;

  /// Re-export of the buffer-allocation helper so capability modules can
  /// reuse the same retry/grow logic used internally.
  Uint8List? execWithBuffer(
    int Function(
      ffi.Pointer<ffi.Uint8> buf,
      int bufLen,
      ffi.Pointer<ffi.Uint32> outWritten,
    ) op,
  ) =>
      callWithBuffer(op);

  /// True when the loaded native library exposes the audit FFI API.
  bool get supportsAuditApi => _bindings.supportsAuditApi;

  /// True when the loaded native library exposes driver capabilities FFI API.
  bool get supportsDriverCapabilitiesApi =>
      _bindings.supportsDriverCapabilitiesApi;

  /// True when the loaded native library exposes async execute FFI APIs.
  bool get supportsAsyncExecuteApi => _bindings.supportsAsyncExecuteApi;

  /// True when the loaded native library exposes async stream FFI APIs.
  bool get supportsAsyncStreamApi => _bindings.supportsAsyncStreamApi;

  /// True when the loaded native library exposes metadata cache FFI APIs.
  bool get supportsMetadataCacheApi => _bindings.supportsMetadataCacheApi;

  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations.
  /// Returns true on success, false on failure.
  bool init() {
    final result = _bindings.odbc_init();
    return result == 0;
  }

  /// Sets the native engine log level (0=Off, 1=Error, 2=Warn, 3=Info, 4=Debug,
  /// 5=Trace). A logger must be initialized by the host for output to appear.
  void setLogLevel(int level) {
    _bindings.odbc_set_log_level(level);
  }

  /// Returns engine version (api + abi) for client compatibility checks.
  ///
  /// Example: `{"api": "0.1.0", "abi": "1.0.0"}`.
  /// Returns null on failure.
  Map<String, String>? getVersion() {
    const bufSize = 128;
    final buf = malloc<ffi.Uint8>(bufSize);
    final outWritten = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_get_version(buf, bufSize, outWritten);
      if (code != 0) return null;
      final n = outWritten.value;
      if (n == 0) return null;
      final json = utf8.decode(buf.asTypedList(n));
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return {
        'api': decoded['api'] as String? ?? '',
        'abi': decoded['abi'] as String? ?? '',
      };
    } on Object catch (_) {
      return null;
    } finally {
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }

  /// Validates connection string format without connecting.
  ///
  /// Returns null if valid; error message if invalid (empty, bad UTF-8,
  /// no key=value pairs, unbalanced braces).
  String? validateConnectionString(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    final errorBuf = malloc<ffi.Uint8>(256);
    try {
      final code = _bindings.odbc_validate_connection_string(
        connStrPtr.cast<bindings.Utf8>(),
        errorBuf,
        256,
      );
      if (code == 0) return null;
      final len = errorBuf.asTypedList(256).indexOf(0);
      if (len <= 0) return 'Invalid connection string';
      return utf8.decode(errorBuf.asTypedList(len));
    } finally {
      malloc
        ..free(connStrPtr)
        ..free(errorBuf);
    }
  }

  /// Establishes a new database connection.
  ///
  /// The [connectionString] should be a valid ODBC connection string
  /// (e.g., 'DSN=MyDatabase' or 'Driver={SQL Server};Server=...').
  ///
  /// Returns a connection ID on success, 0 on failure.
  int connect(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final connId = _bindings.odbc_connect(connStrPtr.cast<bindings.Utf8>());
      return connId;
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// Starts non-blocking query execution and returns async request ID.
  ///
  /// Returns `null` when API is unavailable. Returns `0` on native failure.
  int? executeAsyncStart(int connectionId, String sql) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    final sqlPtr = sql.toNativeUtf8();
    try {
      return _bindings.odbc_execute_async(
        connectionId,
        sqlPtr.cast<bindings.Utf8>(),
      );
    } finally {
      malloc.free(sqlPtr);
    }
  }

  /// Polls async request status.
  ///
  /// Status values: `0` pending, `1` ready, `-1` error, `-2` cancelled.
  int? asyncPoll(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    final outStatus = malloc<ffi.Int32>()..value = 0;
    try {
      final code = _bindings.odbc_async_poll(requestId, outStatus);
      if (code != 0) {
        return null;
      }
      return outStatus.value;
    } finally {
      malloc.free(outStatus);
    }
  }

  /// Retrieves async query result payload for a completed request.
  ///
  /// Returns null on API unavailable, request not ready, or native failure.
  Uint8List? asyncGetResult(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_async_get_result(requestId, buf, bufLen, outWritten) ??
          -1,
    );
    if (data == null || data.isEmpty) {
      return null;
    }
    return data;
  }

  /// Best-effort cancellation for an async request.
  bool asyncCancel(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return false;
    }
    final code = _bindings.odbc_async_cancel(requestId);
    return code == 0;
  }

  /// Frees async request resources.
  bool asyncFree(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return false;
    }
    final code = _bindings.odbc_async_free(requestId);
    return code == 0;
  }

  /// Establishes a connection with a login timeout.
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Returns a connection ID on success, 0 on failure.
  int connectWithTimeout(String connectionString, int timeoutMs) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final connId = _bindings.odbc_connect_with_timeout(
        connStrPtr.cast<bindings.Utf8>(),
        timeoutMs,
      );
      return connId;
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// Closes and disconnects a connection.
  ///
  /// The [connectionId] must be a valid connection identifier.
  /// Returns true on success, false on failure.
  bool disconnect(int connectionId) {
    final result = _bindings.odbc_disconnect(connectionId);
    return result == 0;
  }

  /// Gets driver capabilities from connection string as UTF-8 JSON object.
  ///
  /// Returns null on FFI failure or when API is unavailable.
  String? getDriverCapabilitiesJson(String connectionString) {
    if (!_bindings.supportsDriverCapabilitiesApi) {
      return null;
    }
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final data = callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_get_driver_capabilities(
          connStrPtr.cast<bindings.Utf8>(),
          buf,
          bufLen,
          outWritten,
        ),
      );
      if (data == null) {
        return null;
      }
      return utf8.decode(data);
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// True when the loaded native library exposes the v2.1 live DBMS
  /// introspection FFI (`odbc_get_connection_dbms_info`).
  bool get supportsConnectionDbmsInfoApi =>
      _bindings.supportsConnectionDbmsInfoApi;

  /// Live DBMS introspection (v2.1). Returns the JSON document produced by
  /// `odbc_get_connection_dbms_info` for the given connection id, or null
  /// when the FFI is unavailable / the call fails.
  ///
  /// Far more accurate than [getDriverCapabilitiesJson] because it queries
  /// the actual driver via `SQLGetInfo(SQL_DBMS_NAME)` instead of parsing
  /// the connection string.
  String? getConnectionDbmsInfoJson(int connectionId) {
    if (!_bindings.supportsConnectionDbmsInfoApi) {
      return null;
    }
    final data = callWithBuffer(
      (buf, bufLen, outWritten) => _bindings.odbc_get_connection_dbms_info(
        connectionId,
        buf,
        bufLen,
        outWritten,
      ),
    );
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres", "mysql",
  /// "mongodb", "sqlite", "sybase") if detected, or null if unknown.
  String? detectDriver(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    const bufferLen = 64;
    final outBuf = malloc<ffi.Int8>(bufferLen);
    try {
      final result = _bindings.odbc_detect_driver(
        connStrPtr.cast<bindings.Utf8>(),
        outBuf,
        bufferLen,
      );
      if (result != 1) {
        return null;
      }
      final end = outBuf.asTypedList(bufferLen).indexOf(0);
      final len = end < 0 ? bufferLen : end;
      if (len == 0) {
        return null;
      }
      final bytes =
          outBuf.asTypedList(len).map((e) => e.toUnsigned(8)).toList();
      return utf8.decode(bytes);
    } finally {
      malloc
        ..free(connStrPtr)
        ..free(outBuf);
    }
  }

  /// Gets the last error message from the native engine.
  ///
  /// Returns an empty string if no error occurred.
  String getError() {
    final buf = malloc<ffi.Int8>(_errorBufferSize);
    try {
      final n = _bindings.odbc_get_error(buf, _errorBufferSize);
      if (n < 0) {
        return 'Unknown error';
      }
      if (n == 0) {
        return '';
      }
      final bytes = buf.asTypedList(n).map((e) => e.toUnsigned(8)).toList();
      return utf8.decode(bytes);
    } finally {
      malloc.free(buf);
    }
  }

  /// Enables or disables native audit event collection.
  ///
  /// Returns true when operation succeeds.
  bool setAuditEnabled({required bool enabled}) {
    final result = _bindings.odbc_audit_enable(enabled ? 1 : 0);
    return result == 0;
  }

  /// Clears all in-memory native audit events.
  ///
  /// Returns true on success.
  bool clearAuditEvents() {
    final result = _bindings.odbc_audit_clear();
    return result == 0;
  }

  /// Gets audit events encoded as UTF-8 JSON array.
  ///
  /// Returns null on FFI failure.
  String? getAuditEventsJson({int limit = 0}) {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_audit_get_events(buf, bufLen, outWritten, limit),
    );
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Gets current audit status encoded as UTF-8 JSON object.
  ///
  /// Returns null on FFI failure.
  String? getAuditStatusJson() {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_audit_get_status(buf, bufLen, outWritten),
    );
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Gets structured error information including SQLSTATE and native code.
  ///
  /// Returns null if no error occurred or if structured error info
  /// is not available.
  StructuredError? getStructuredError() {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_get_structured_error(buf, bufLen, outWritten),
    );
    if (data == null || data.isEmpty) {
      return null;
    }
    return StructuredError.deserialize(data);
  }

  /// Whether the native library exposes per-connection structured error API.
  bool get supportsStructuredErrorForConnection =>
      _bindings.supportsStructuredErrorForConnection;

  /// Gets structured error for a specific connection (per-connection
  /// isolation).
  ///
  /// When [connectionId] != 0, returns only that connection's error.
  /// Returns null when API is unavailable, no error for this connection,
  /// or on FFI failure.
  StructuredError? getStructuredErrorForConnection(int connectionId) {
    if (!_bindings.supportsStructuredErrorForConnection) {
      return null;
    }

    var size = initialBufferSize;
    const limit = maxBufferSize;
    while (size <= limit) {
      final buf = malloc<ffi.Uint8>(size);
      final outWritten = malloc<ffi.Uint32>()..value = 0;
      try {
        final code = _bindings.odbc_get_structured_error_for_connection(
          connectionId,
          buf,
          size,
          outWritten,
        );
        if (code == null) return null;
        if (code == 1) return null; // No structured error for this connection
        if (code == -1) return null; // FFI error
        if (code == -2) {
          size *= 2;
          continue;
        }
        if (code == 0) {
          final n = outWritten.value;
          if (n == 0) return null;
          final data = Uint8List.fromList(buf.asTypedList(n));
          return StructuredError.deserialize(data);
        }
        return null;
      } finally {
        malloc
          ..free(buf)
          ..free(outWritten);
      }
    }
    return null;
  }

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
    final sqlPtr = sql.toNativeUtf8();
    try {
      final streamId = _bindings.odbc_stream_start(
        connectionId,
        sqlPtr.cast<bindings.Utf8>(),
        chunkSize,
      );
      return streamId;
    } finally {
      malloc.free(sqlPtr);
    }
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
  }) {
    if (!_bindings.supportsAsyncStreamApi) {
      return null;
    }
    final sqlPtr = sql.toNativeUtf8();
    try {
      return _bindings.odbc_stream_start_async(
        connectionId,
        sqlPtr.cast<bindings.Utf8>(),
        fetchSize,
        chunkSize,
      );
    } finally {
      malloc.free(sqlPtr);
    }
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
    var size = initialBufferSize;
    const maxSize = maxBufferSize;
    while (size <= maxSize) {
      final buf = malloc<ffi.Uint8>(size);
      final outWritten = malloc<ffi.Uint32>();
      final hasMore = malloc<ffi.Uint8>();
      outWritten.value = 0;
      hasMore.value = 0;
      try {
        final code = _bindings.odbc_stream_fetch(
          streamId,
          buf,
          size,
          outWritten,
          hasMore,
        );
        if (code == 0) {
          final n = outWritten.value;
          final data = n > 0 ? Uint8List.fromList(buf.asTypedList(n)) : null;
          final more = hasMore.value != 0;
          return StreamFetchResult(
            success: true,
            data: data?.toList(),
            hasMore: more,
          );
        }
        if (code == -2) {
          size *= 2;
          continue;
        }
        return StreamFetchResult(
          success: false,
          data: null,
          hasMore: false,
        );
      } finally {
        malloc
          ..free(buf)
          ..free(outWritten)
          ..free(hasMore);
      }
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

  /// Executes a SQL query and returns binary result data.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a valid SQL SELECT statement.
  /// When [maxBufferBytes] is set, caps the result buffer size; otherwise
  /// uses the package default.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQuery(int connectionId, String sql, {int? maxBufferBytes}) {
    return _withSql(
      sql,
      (sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_exec_query(
          connectionId,
          sqlPtr,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Executes a SQL query with binary parameters.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] should be a binary buffer containing serialized parameters.
  /// When [maxBufferBytes] is set, caps the result buffer size; otherwise
  /// uses the package default.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryParams(
    int connectionId,
    String sql,
    Uint8List? params, {
    int? maxBufferBytes,
  }) {
    final paramsOrEmpty =
        (params == null || params.isEmpty) ? Uint8List(0) : params;
    return _withSql(
      sql,
      (sqlPtr) {
        return _withParamsBuffer(
          paramsOrEmpty,
          (paramsPtr) => callWithBuffer(
            (buf, bufLen, outWritten) => _bindings.odbc_exec_query_params(
              connectionId,
              sqlPtr,
              paramsPtr,
              paramsOrEmpty.length,
              buf,
              bufLen,
              outWritten,
            ),
            maxSize: maxBufferBytes,
          ),
        );
      },
    );
  }

  /// Executes a SQL query with typed parameters.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder in [sql], in order.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryParamsTyped(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
  }) {
    if (params.isEmpty) {
      return execQueryParams(
        connectionId,
        sql,
        null,
        maxBufferBytes: maxBufferBytes,
      );
    }
    final buf = serializeParams(params);
    return execQueryParams(
      connectionId,
      sql,
      buf,
      maxBufferBytes: maxBufferBytes,
    );
  }

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  /// The [connectionId] must be a valid active connection.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) {
    return _withSql(
      sql,
      (sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_exec_query_multi(
          connectionId,
          sqlPtr,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3 — see
  /// `IsolationLevel`).
  /// The [savepointDialect] is the wire code from `SavepointDialect.code`
  /// (default `0` = `auto`, resolved on the Rust side via SQLGetInfo).
  ///
  /// Returns a transaction ID on success, 0 on failure.
  int transactionBegin(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
  }) {
    return _bindings.odbc_transaction_begin(
      connectionId,
      isolationLevel,
      savepointDialect,
    );
  }

  /// Commits a transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool transactionCommit(int txnId) {
    return _bindings.odbc_transaction_commit(txnId) == 0;
  }

  /// Rolls back a transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool transactionRollback(int txnId) {
    return _bindings.odbc_transaction_rollback(txnId) == 0;
  }

  /// Creates a savepoint within an active transaction.
  ///
  /// The [txnId] must be a valid transaction identifier from
  /// [transactionBegin]. Returns true on success, false on failure.
  bool savepointCreate(int txnId, String name) {
    final namePtr = name.toNativeUtf8();
    try {
      return _bindings.odbc_savepoint_create(
            txnId,
            namePtr.cast<bindings.Utf8>(),
          ) ==
          0;
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Rolls back to a savepoint. The transaction remains active.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool savepointRollback(int txnId, String name) {
    final namePtr = name.toNativeUtf8();
    try {
      return _bindings.odbc_savepoint_rollback(
            txnId,
            namePtr.cast<bindings.Utf8>(),
          ) ==
          0;
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Releases a savepoint. The transaction remains active.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool savepointRelease(int txnId, String name) {
    final namePtr = name.toNativeUtf8();
    try {
      return _bindings.odbc_savepoint_release(
            txnId,
            namePtr.cast<bindings.Utf8>(),
          ) ==
          0;
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Gets performance and operational metrics.
  ///
  /// Returns [OdbcMetrics] containing query counts, error counts,
  /// uptime, and latency information, or null on failure.
  OdbcMetrics? getMetrics() {
    const metricsSize = 40;
    final buf = malloc<ffi.Uint8>(metricsSize);
    final outWritten = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_get_metrics(buf, metricsSize, outWritten);
      if (code != 0) return null;
      final n = outWritten.value;
      if (n < metricsSize) return null;
      return OdbcMetrics.fromBytes(
        Uint8List.fromList(buf.asTypedList(metricsSize)),
      );
    } finally {
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }

  /// Gets prepared statement cache metrics.
  ///
  /// Returns [PreparedStatementMetrics] on success, null on failure.
  PreparedStatementMetrics? getCacheMetrics() {
    const metricsSize = 64;
    final buf = malloc<ffi.Uint8>(metricsSize);
    final outWritten = malloc<ffi.Uint32>();
    try {
      final code =
          _bindings.odbc_get_cache_metrics(buf, metricsSize, outWritten);
      if (code != 0) return null;
      final n = outWritten.value;
      if (n < metricsSize) return null;
      return PreparedStatementMetrics.fromBytes(
        Uint8List.fromList(buf.asTypedList(metricsSize)),
      );
    } finally {
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }

  /// Clears the prepared statement cache.
  ///
  /// Returns true on success, false on failure.
  bool clearStatementCache() {
    final code = _bindings.odbc_clear_statement_cache();
    return code == 0;
  }

  /// Enables or reconfigures metadata cache in native engine.
  ///
  /// [maxEntries] and [ttlSeconds] must be greater than zero.
  /// Returns true on success.
  bool metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) {
    final code = _bindings.odbc_metadata_cache_enable(maxEntries, ttlSeconds);
    return code == 0;
  }

  /// Returns metadata cache statistics as JSON payload.
  ///
  /// Example keys: `hits`, `misses`, `size`, `max_size`, `ttl_secs`.
  /// Returns null on failure.
  String? metadataCacheStatsJson() {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_metadata_cache_stats(buf, bufLen, outWritten),
      initialSize: 128,
    );
    if (data == null || data.isEmpty) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Clears all metadata cache entries.
  ///
  /// Returns true on success.
  bool metadataCacheClear() {
    final code = _bindings.odbc_metadata_cache_clear();
    return code == 0;
  }

  /// Queries the database catalog for table information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [catalog] and [schema] parameters filter results.
  /// Empty strings match all values.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) {
    return _withUtf8Pair(
      catalog,
      schema,
      (cPtr, sPtr) => _withConn(
        connectionId,
        (conn) => callWithBuffer(
          (buf, bufLen, outWritten) => _bindings.odbc_catalog_tables(
            conn,
            cPtr,
            sPtr,
            buf,
            bufLen,
            outWritten,
          ),
        ),
      ),
    );
  }

  /// Queries the database catalog for column information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query columns for.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogColumns(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_columns(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Queries the database catalog for data type information.
  ///
  /// The [connectionId] must be a valid active connection.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTypeInfo(int connectionId) {
    return callWithBuffer(
      (buf, bufLen, outWritten) => _bindings.odbc_catalog_type_info(
        connectionId,
        buf,
        bufLen,
        outWritten,
      ),
    );
  }

  /// Queries the database catalog for primary key information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query primary keys for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, CONSTRAINT_NAME
  Uint8List? catalogPrimaryKeys(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_primary_keys(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Queries the database catalog for foreign key information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query foreign keys for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: CONSTRAINT_NAME, FROM_TABLE, FROM_COLUMN, TO_TABLE,
  /// TO_COLUMN, UPDATE_RULE, DELETE_RULE
  Uint8List? catalogForeignKeys(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_foreign_keys(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Queries the database catalog for index information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query indexes for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: INDEX_NAME, TABLE_NAME, COLUMN_NAME, IS_UNIQUE,
  /// IS_PRIMARY, ORDINAL_POSITION
  Uint8List? catalogIndexes(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_indexes(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Prepares a SQL statement for execution.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [timeoutMs] specifies the statement timeout in milliseconds
  /// (0 = no timeout).
  ///
  /// Returns a statement ID on success, 0 on failure.
  int prepare(int connectionId, String sql, {int timeoutMs = 0}) {
    final sqlPtr = sql.toNativeUtf8();
    try {
      return _bindings.odbc_prepare(
        connectionId,
        sqlPtr.cast<bindings.Utf8>(),
        timeoutMs,
      );
    } finally {
      malloc.free(sqlPtr);
    }
  }

  /// Executes a prepared statement with optional binary parameters.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// The [params] should be a binary buffer containing serialized parameters,
  /// or null if no parameters are needed.
  /// The [timeoutOverrideMs] overrides statement timeout (0 = use stored).
  /// The [fetchSize] specifies rows per batch (default: 1000).
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execute(
    int stmtId, [
    Uint8List? params,
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxBufferBytes,
  ]) {
    if (params == null || params.isEmpty) {
      return callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_execute(
          stmtId,
          ffi.nullptr,
          0,
          timeoutOverrideMs,
          fetchSize,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      );
    }
    return _withParamsBuffer(
      params,
      (paramsPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_execute(
          stmtId,
          paramsPtr,
          params.length,
          timeoutOverrideMs,
          fetchSize,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Executes a prepared statement with typed parameters.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder, in order, or null if no parameters are needed.
  /// The [timeoutOverrideMs] overrides statement timeout (0 = use stored).
  /// The [fetchSize] specifies rows per batch (default: 1000).
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeTyped(
    int stmtId, [
    List<ParamValue>? params,
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxBufferBytes,
  ]) {
    if (params == null || params.isEmpty) {
      return execute(
        stmtId,
        null,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
      );
    }
    return execute(
      stmtId,
      serializeParams(params),
      timeoutOverrideMs,
      fetchSize,
      maxBufferBytes,
    );
  }

  /// Cancels a prepared statement execution.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  ///
  /// Current native contract may return unsupported feature errors depending
  /// on runtime capabilities.
  ///
  /// Returns true on success, false on failure.
  bool cancelStatement(int stmtId) {
    return _bindings.odbc_cancel(stmtId) == 0;
  }

  /// Closes and releases a prepared statement.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// Returns true on success, false on failure.
  bool closeStatement(int stmtId) {
    return _bindings.odbc_close_statement(stmtId) == 0;
  }

  /// Clears all prepared statements.
  ///
  /// Returns 0 on success, non-zero on failure.
  int clearAllStatements() => _bindings.odbc_clear_all_statements();

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
  }) {
    final sqlPtr = sql.toNativeUtf8();
    try {
      return _bindings.odbc_stream_start_batched(
        connectionId,
        sqlPtr.cast<bindings.Utf8>(),
        fetchSize,
        chunkSize,
      );
    } finally {
      malloc.free(sqlPtr);
    }
  }

  /// Creates a new connection pool.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a pool ID on success, 0 on failure.
  int poolCreate(String connectionString, int maxSize) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      return _bindings.odbc_pool_create(
        connStrPtr.cast<bindings.Utf8>(),
        maxSize,
      );
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// Whether the loaded native library exposes the v3.0
  /// `odbc_pool_create_with_options` entry point.
  bool get supportsPoolCreateWithOptions =>
      _bindings.supportsPoolCreateWithOptions;

  /// Creates a pool with explicit eviction/timeout options (v3.0).
  ///
  /// `optionsJson` keys (all optional, in milliseconds):
  /// `idle_timeout_ms`, `max_lifetime_ms`, `connection_timeout_ms`.
  /// Returns 0 on failure or when the FFI is not available.
  int poolCreateWithOptions(
    String connectionString,
    int maxSize, {
    String? optionsJson,
  }) {
    if (!_bindings.supportsPoolCreateWithOptions) return 0;
    final connStrPtr = connectionString.toNativeUtf8();
    final optsPtr = optionsJson?.toNativeUtf8().cast<bindings.Utf8>();
    try {
      return _bindings.odbc_pool_create_with_options(
        connStrPtr.cast<bindings.Utf8>(),
        maxSize,
        optsPtr,
      );
    } finally {
      malloc.free(connStrPtr);
      if (optsPtr != null) {
        malloc.free(optsPtr.cast<Utf8>());
      }
    }
  }

  /// Gets a connection from the pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns a connection ID on success, 0 on failure.
  int poolGetConnection(int poolId) {
    return _bindings.odbc_pool_get_connection(poolId);
  }

  /// Releases a connection back to the pool.
  ///
  /// The [connectionId] must be a connection obtained from [poolGetConnection].
  /// Returns true on success, false on failure.
  bool poolReleaseConnection(int connectionId) {
    return _bindings.odbc_pool_release_connection(connectionId) == 0;
  }

  /// Performs a health check on the connection pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns true if the pool is healthy, false otherwise.
  bool poolHealthCheck(int poolId) {
    return _bindings.odbc_pool_health_check(poolId) == 1;
  }

  /// Gets the current state of the connection pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns a record with pool size and idle count, or null on failure.
  ({int size, int idle})? poolGetState(int poolId) {
    final outSize = malloc<ffi.Uint32>();
    final outIdle = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_pool_get_state(poolId, outSize, outIdle);
      if (code != 0) return null;
      return (size: outSize.value, idle: outIdle.value);
    } finally {
      malloc
        ..free(outSize)
        ..free(outIdle);
    }
  }

  /// Gets pool state as JSON (detailed metrics for monitoring).
  ///
  /// Returns a map with keys: total_connections, idle_connections,
  /// active_connections, max_size, wait_count, wait_time_ms,
  /// max_wait_time_ms, avg_wait_time_ms. Returns null on failure.
  Map<String, dynamic>? poolGetStateJson(int poolId) {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_pool_get_state_json(poolId, buf, bufLen, outWritten),
      initialSize: 256,
    );
    if (data == null || data.isEmpty) return null;
    try {
      final json = utf8.decode(data);
      return jsonDecode(json) as Map<String, dynamic>;
    } on Object {
      return null;
    }
  }

  /// Resizes the pool by recreating it with [newMaxSize].
  ///
  /// All connections must be released before resize. Returns true on success,
  /// false on failure (invalid pool, connections checked out, or pool creation
  /// failed).
  bool poolSetSize(int poolId, int newMaxSize) {
    return _bindings.odbc_pool_set_size(poolId, newMaxSize) == 0;
  }

  /// Closes the connection pool and releases all connections.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns true on success, false on failure.
  bool poolClose(int poolId) {
    return _bindings.odbc_pool_close(poolId) == 0;
  }

  /// Performs a bulk insert operation.
  ///
  /// Inserts multiple rows into [table] using the specified [columns].
  /// The [dataBuffer] contains the data as a binary buffer.
  /// The [rowCount] specifies how many rows are in [dataBuffer].
  ///
  /// Returns the number of rows inserted on success, -1 on failure.
  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) {
    final tablePtr = table.toNativeUtf8();
    final colPtrs = malloc<ffi.Pointer<bindings.Utf8>>(columns.length);
    final utf8Ptrs = <ffi.Pointer<ffi.Opaque>>[];
    try {
      for (var i = 0; i < columns.length; i++) {
        final p = columns[i].toNativeUtf8();
        utf8Ptrs.add(p);
        (colPtrs + i).value = p.cast<bindings.Utf8>();
      }
      final rowsInserted = malloc<ffi.Uint32>();
      try {
        final dataPtr = _allocUint8List(dataBuffer);
        try {
          final code = _bindings.odbc_bulk_insert_array(
            connectionId,
            tablePtr.cast<bindings.Utf8>(),
            colPtrs,
            columns.length,
            dataPtr,
            dataBuffer.length,
            rowCount,
            rowsInserted,
          );
          if (code != 0) return -1;
          return rowsInserted.value;
        } finally {
          malloc.free(dataPtr);
        }
      } finally {
        malloc.free(rowsInserted);
      }
    } finally {
      utf8Ptrs.forEach(malloc.free);
      malloc
        ..free(colPtrs)
        ..free(tablePtr);
    }
  }

  /// Performs a parallel bulk insert operation through [poolId].
  ///
  /// [dataBuffer] must be built using [BulkInsertBuilder.build()].
  /// Returns inserted row count on success, -1 on failure.
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) {
    final tablePtr = table.toNativeUtf8();
    final colPtrs = malloc<ffi.Pointer<bindings.Utf8>>(columns.length);
    final utf8Ptrs = <ffi.Pointer<ffi.Opaque>>[];
    try {
      for (var i = 0; i < columns.length; i++) {
        final p = columns[i].toNativeUtf8();
        utf8Ptrs.add(p);
        (colPtrs + i).value = p.cast<bindings.Utf8>();
      }
      final rowsInserted = malloc<ffi.Uint32>();
      try {
        final dataPtr = _allocUint8List(dataBuffer);
        try {
          final code = _bindings.odbc_bulk_insert_parallel(
            poolId,
            tablePtr.cast<bindings.Utf8>(),
            colPtrs,
            columns.length,
            dataPtr,
            dataBuffer.length,
            parallelism,
            rowsInserted,
          );
          if (code != 0) return -1;
          return rowsInserted.value;
        } finally {
          malloc.free(dataPtr);
        }
      } finally {
        malloc.free(rowsInserted);
      }
    } finally {
      utf8Ptrs.forEach(malloc.free);
      malloc
        ..free(colPtrs)
        ..free(tablePtr);
    }
  }

  /// Disposes of native resources.
  ///
  /// Should be called when the instance is no longer needed.
  void dispose() {}
}

extension on OdbcNative {
  ffi.Pointer<ffi.Uint8> _allocUint8List(Uint8List list) {
    final p = malloc<ffi.Uint8>(list.length);
    for (var i = 0; i < list.length; i++) {
      (p + i).value = list[i];
    }
    return p;
  }

  T? _withSql<T>(
    String sql,
    T? Function(ffi.Pointer<bindings.Utf8> ptr) f,
  ) {
    final ptr = sql.toNativeUtf8();
    try {
      return f(ptr.cast<bindings.Utf8>());
    } finally {
      malloc.free(ptr);
    }
  }

  T? _withParamsBuffer<T>(
    Uint8List params,
    T? Function(ffi.Pointer<ffi.Uint8> ptr) f,
  ) {
    final ptr = _allocUint8List(params);
    try {
      return f(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  T? _withUtf8Pair<T>(
    String a,
    String b,
    T? Function(
      ffi.Pointer<bindings.Utf8> aPtr,
      ffi.Pointer<bindings.Utf8> bPtr,
    ) f,
  ) {
    final aPtr = a.toNativeUtf8();
    final bPtr = b.toNativeUtf8();
    try {
      return f(
        aPtr.cast<bindings.Utf8>(),
        bPtr.cast<bindings.Utf8>(),
      );
    } finally {
      malloc
        ..free(aPtr)
        ..free(bPtr);
    }
  }

  T? _withConn<T>(int connId, T? Function(int) f) => f(connId);
}

/// Performance and operational metrics from the ODBC engine.
///
/// Contains query counts, error counts, uptime, and latency statistics.
class OdbcMetrics {
  /// Creates a new [OdbcMetrics] instance.
  ///
  /// The [queryCount] is the total number of queries executed.
  /// The [errorCount] is the total number of errors encountered.
  /// The [uptimeSecs] is the engine uptime in seconds.
  /// The [totalLatencyMillis] is the total query latency in milliseconds.
  /// The [avgLatencyMillis] is the average query latency in milliseconds.
  const OdbcMetrics({
    required this.queryCount,
    required this.errorCount,
    required this.uptimeSecs,
    required this.totalLatencyMillis,
    required this.avgLatencyMillis,
  });

  /// Total number of queries executed.
  final int queryCount;

  /// Total number of errors encountered.
  final int errorCount;

  /// Uptime in seconds.
  final int uptimeSecs;

  /// Total query latency in milliseconds.
  final int totalLatencyMillis;

  /// Average query latency in milliseconds.
  final int avgLatencyMillis;

  /// Deserializes [OdbcMetrics] from binary data.
  ///
  /// The [b] must contain at least 40 bytes of metrics data.
  // Factory method pattern preferred for deserialization.
  // ignore: prefer_constructors_over_static_methods
  static OdbcMetrics fromBytes(Uint8List b) {
    final d = ByteData.sublistView(b);
    return OdbcMetrics(
      queryCount: d.getUint64(0, Endian.little),
      errorCount: d.getUint64(8, Endian.little),
      uptimeSecs: d.getUint64(16, Endian.little),
      totalLatencyMillis: d.getUint64(24, Endian.little),
      avgLatencyMillis: d.getUint64(32, Endian.little),
    );
  }
}

/// Deserializes [PreparedStatementMetrics] from binary data.
///
/// The [b] must contain at least 64 bytes of metrics data.
PreparedStatementMetrics fromBytes(Uint8List b) {
  final d = ByteData.sublistView(b);
  return PreparedStatementMetrics(
    cacheSize: d.getUint64(0, Endian.little),
    cacheMaxSize: d.getUint64(8, Endian.little),
    cacheHits: d.getUint64(16, Endian.little),
    cacheMisses: d.getUint64(24, Endian.little),
    totalPrepares: d.getUint64(32, Endian.little),
    totalExecutions: d.getUint64(40, Endian.little),
    memoryUsageBytes: d.getUint64(48, Endian.little),
    avgExecutionsPerStmt: d.getFloat64(56, Endian.little),
  );
}

/// Result of a stream fetch operation.
///
/// Contains success status, fetched data, and whether more data is available.
class StreamFetchResult {
  /// Creates a new [StreamFetchResult] instance.
  ///
  /// The [success] indicates if the fetch operation succeeded.
  /// The [data] contains the fetched data, or null if no data or on failure.
  /// The [hasMore] indicates if more data is available in the stream.
  StreamFetchResult({
    required this.success,
    required this.data,
    required this.hasMore,
  });

  /// Whether the fetch operation succeeded.
  final bool success;

  /// Fetched data, or null if no data or on failure.
  final List<int>? data;

  /// Whether more data is available in the stream.
  final bool hasMore;
}
