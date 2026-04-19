import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart' as domain;
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart'
    as bindings;
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';

/// Native ODBC connection implementation using FFI bindings.
///
/// Provides direct access to the Rust-based ODBC engine through FFI.
/// This is the low-level implementation that handles all native ODBC operations
/// including connections, queries, transactions, prepared statements,
/// connection pooling, and streaming.
///
/// Example:
/// ```dart
/// final native = NativeOdbcConnection();
/// native.initialize();
/// final connId = native.connect('DSN=MyDatabase');
/// ```
class NativeOdbcConnection implements OdbcConnectionBackend {
  /// Creates a new [NativeOdbcConnection] instance.
  NativeOdbcConnection() : _native = bindings.OdbcNative() {
    _auditLogger = OdbcAuditLogger(_native);
  }
  final bindings.OdbcNative _native;
  late final OdbcAuditLogger _auditLogger;
  bool _isInitialized = false;

  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations. This method can be called
  /// multiple times safely - subsequent calls are ignored if already
  /// initialized.
  ///
  /// Returns true on success, false on failure.
  bool initialize() {
    if (_isInitialized) return true;

    final result = _native.init();
    if (result) {
      _isInitialized = true;
    }
    return result;
  }

  /// Establishes a new database connection.
  ///
  /// The [connectionString] should be a valid ODBC connection string
  /// (e.g., 'DSN=MyDatabase' or 'Driver={SQL Server};Server=...').
  ///
  /// Returns a connection ID on success, 0 on failure.
  /// Throws [StateError] if the environment has not been initialized.
  int connect(String connectionString) {
    if (!_isInitialized) {
      throw StateError('Environment not initialized');
    }
    return _native.connect(connectionString);
  }

  /// Establishes a connection with a login timeout.
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Returns a connection ID on success, 0 on failure.
  int connectWithTimeout(String connectionString, int timeoutMs) {
    if (!_isInitialized) {
      throw StateError('Environment not initialized');
    }
    return _native.connectWithTimeout(connectionString, timeoutMs);
  }

  /// Closes and disconnects a connection.
  ///
  /// The [connectionId] must be a valid connection identifier returned
  /// from [connect]. Returns true on success, false on failure.
  bool disconnect(int connectionId) {
    return _native.disconnect(connectionId);
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres") if
  /// detected, or null if unknown.
  String? detectDriver(String connectionString) =>
      _native.detectDriver(connectionString);

  /// Validates connection string format without opening a connection.
  ///
  /// Returns null when valid; otherwise a human-readable validation message.
  String? validateConnectionString(String connectionString) =>
      _native.validateConnectionString(connectionString);

  /// Whether the loaded native library supports driver capabilities FFI API.
  bool get supportsDriverCapabilitiesApi =>
      _native.supportsDriverCapabilitiesApi;

  /// Returns typed driver capabilities from [connectionString], or null when
  /// API is unavailable or invalid.
  DriverCapabilities? getDriverCapabilities(String connectionString) =>
      OdbcDriverCapabilities(_native).getCapabilities(connectionString);

  /// Returns driver capabilities payload as JSON, or null on failure.
  String? getDriverCapabilitiesJson(String connectionString) =>
      _native.getDriverCapabilitiesJson(connectionString);

  /// Whether the loaded native library exposes live DBMS introspection
  /// (v2.1 `odbc_get_connection_dbms_info`).
  bool get supportsConnectionDbmsInfoApi =>
      _native.supportsConnectionDbmsInfoApi;

  /// Returns the live DBMS introspection JSON for [connectionId], or null
  /// when the call fails or the API is unavailable. Use the high-level
  /// `OdbcDriverCapabilities.getDbmsInfoForConnection` to obtain a typed
  /// `DbmsInfo` instead of raw JSON.
  String? getConnectionDbmsInfoJson(int connectionId) =>
      _native.getConnectionDbmsInfoJson(connectionId);

  /// Gets the last error message from the native engine.
  ///
  /// Returns an empty string if no error occurred.
  String getError() => _native.getError();

  /// Gets structured error information including SQLSTATE and native code.
  ///
  /// Returns null if no error occurred or if structured error info
  /// is not available.
  StructuredError? getStructuredError() => _native.getStructuredError();

  /// Whether the native library supports per-connection structured error API.
  bool get supportsStructuredErrorForConnection =>
      _native.supportsStructuredErrorForConnection;

  /// Gets structured error for a specific connection (per-connection
  /// isolation).
  ///
  /// When [connectionId] != 0, returns only that connection's error.
  /// Returns null when API is unavailable, no error for this connection,
  /// or on FFI failure.
  StructuredError? getStructuredErrorForConnection(int connectionId) =>
      _native.getStructuredErrorForConnection(connectionId);

  /// Typed wrapper for native audit APIs.
  OdbcAuditLogger get auditLogger => _auditLogger;

  /// Whether the loaded native library supports audit FFI endpoints.
  bool get supportsAuditApi => _native.supportsAuditApi;

  /// Whether the loaded native library supports async execute FFI endpoints.
  bool get supportsAsyncExecuteApi => _native.supportsAsyncExecuteApi;

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
  int? streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _native.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
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

  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3) corresponding
  /// to isolation level enum values (0=ReadUncommitted, 1=ReadCommitted,
  /// 2=RepeatableRead, 3=Serializable).
  /// The [savepointDialect] is the wire code from `SavepointDialect.code`
  /// (default `0` = `auto`, resolved by the Rust engine via SQLGetInfo).
  ///
  /// Returns a transaction ID on success, 0 on failure.
  int beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
  }) =>
      _native.transactionBegin(
        connectionId,
        isolationLevel,
        savepointDialect: savepointDialect,
      );

  /// Begins a new transaction and returns a [TransactionHandle] wrapper.
  ///
  /// See [beginTransaction] for the parameter contract.
  /// Returns a [TransactionHandle] on success, null on failure.
  TransactionHandle? beginTransactionHandle(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
  }) {
    final txnId = beginTransaction(
      connectionId,
      isolationLevel,
      savepointDialect: savepointDialect,
    );
    if (txnId == 0) return null;
    return TransactionHandle(this, txnId);
  }

  @override
  bool commitTransaction(int txnId) => _native.transactionCommit(txnId);

  @override
  bool rollbackTransaction(int txnId) => _native.transactionRollback(txnId);

  @override
  bool createSavepoint(int txnId, String name) =>
      _native.savepointCreate(txnId, name);

  @override
  bool rollbackToSavepoint(int txnId, String name) =>
      _native.savepointRollback(txnId, name);

  @override
  bool releaseSavepoint(int txnId, String name) =>
      _native.savepointRelease(txnId, name);

  /// Prepares a SQL statement for execution.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement (e.g.,
  /// 'SELECT * FROM users WHERE id = ?').
  ///
  /// The [timeoutMs] specifies the statement timeout in milliseconds
  /// (0 = no timeout).
  /// Returns a statement ID on success, 0 on failure.
  int prepare(int connectionId, String sql, {int timeoutMs = 0}) =>
      _native.prepare(connectionId, sql, timeoutMs: timeoutMs);

  /// Prepares a SQL statement and returns a [PreparedStatement] wrapper.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  ///
  /// The [timeoutMs] specifies the statement timeout in milliseconds
  /// (0 = no timeout).
  /// Returns a [PreparedStatement] on success, null on failure.
  PreparedStatement? prepareStatement(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) {
    final stmtId = prepare(connectionId, sql, timeoutMs: timeoutMs);
    if (stmtId == 0) return null;
    return PreparedStatement(this, stmtId);
  }

  /// Prepares a SQL statement with named parameters and returns a
  /// `PreparedStatement` wrapper that supports `executeNamed`.
  ///
  /// Supports @name and :name syntax. Converts to positional placeholders
  /// before preparing. The returned `PreparedStatement` can use
  /// `executeNamed` with a map of parameter values.
  PreparedStatement? prepareStatementNamed(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) {
    final extractResult = NamedParameterParser.extract(sql);
    final stmtId =
        prepare(connectionId, extractResult.cleanedSql, timeoutMs: timeoutMs);
    if (stmtId == 0) return null;
    return PreparedStatement(
      this,
      stmtId,
      paramNamesForNamedExecution: extractResult.paramNames,
    );
  }

  @override
  Uint8List? executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) =>
      _native.executeTyped(
        stmtId,
        params,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
      );

  /// Executes a prepared statement with params already serialized (bytes).
  ///
  /// Used by the worker isolate. [serializedParams] is the output of
  /// [serializeParams] or null/empty for no params.
  Uint8List? executePreparedRaw(
    int stmtId,
    Uint8List? serializedParams,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) =>
      _native.execute(
        stmtId,
        serializedParams,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
      );

  /// Requests cancellation of a prepared statement execution.
  ///
  /// Returns true on success, false when cancellation fails or is unsupported.
  bool cancelStatement(int stmtId) => _native.cancelStatement(stmtId);

  @override
  bool closeStatement(int stmtId) => _native.closeStatement(stmtId);

  @override
  int clearAllStatements() => _native.clearAllStatements();

  @override
  PreparedStatementMetrics? getCacheMetrics() => _native.getCacheMetrics();

  /// Executes a SQL query with parameters.
  ///
  /// Convenience method that combines prepare and execute in a single call.
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] list should contain [ParamValue] instances for each '?'
  /// placeholder in [sql], in order.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
  }) =>
      _native.execQueryParamsTyped(
        connectionId,
        sql,
        params,
        maxBufferBytes: maxBufferBytes,
      );

  /// Executes a parameterized query with params already serialized (bytes).
  ///
  /// Used by the worker isolate where [ParamValue] cannot be deserialized.
  /// [serializedParams] is the output of [serializeParams].
  /// When [maxBufferBytes] is set, caps the result buffer size.
  Uint8List? executeQueryParamsRaw(
    int connectionId,
    String sql,
    Uint8List? serializedParams, {
    int? maxBufferBytes,
  }) =>
      _native.execQueryParams(
        connectionId,
        sql,
        serializedParams,
        maxBufferBytes: maxBufferBytes,
      );

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  /// The [connectionId] must be a valid active connection.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) =>
      _native.execQueryMulti(connectionId, sql, maxBufferBytes: maxBufferBytes);

  /// Whether the loaded native library exports
  /// `odbc_exec_query_multi_params` (added in v3.2.0).
  bool get supportsExecuteQueryMultiParams =>
      _native.supportsExecQueryMultiParams;

  /// Whether the loaded native library exports the M8 streaming
  /// multi-result FFIs (added in v3.3.0).
  bool get supportsStreamQueryMulti => _native.supportsMultiResultStream;

  /// Starts a streaming multi-result batch in batched mode and returns the
  /// new stream id (or `null` on failure / unsupported native lib).
  /// Use `streamFetch` / `streamCancel` / `streamClose` to drive it.
  int? streamMultiStartBatched(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) =>
      _native.streamMultiStartBatched(
        connectionId,
        sql,
        chunkSize: chunkSize,
      );

  /// Async variant of [streamMultiStartBatched]. Combine with
  /// `streamPollAsync` for non-blocking readiness.
  int? streamMultiStartAsync(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) =>
      _native.streamMultiStartAsync(
        connectionId,
        sql,
        chunkSize: chunkSize,
      );

  /// Executes a parameterised batch SQL that may return multiple result sets.
  ///
  /// See `OdbcNative.execQueryMultiParams` for the full contract.
  /// `paramsBuffer` is the output of `serializeParams(...)`.
  Uint8List? executeQueryMultiParams(
    int connectionId,
    String sql,
    Uint8List? paramsBuffer, {
    int? maxBufferBytes,
  }) =>
      _native.execQueryMultiParams(
        connectionId,
        sql,
        paramsBuffer,
        maxBufferBytes: maxBufferBytes,
      );

  @override
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _native.catalogTables(
        connectionId,
        catalog: catalog,
        schema: schema,
      );

  /// Creates a [CatalogQuery] wrapper for database catalog queries.
  ///
  /// The [connectionId] must be a valid active connection.
  /// Returns a [CatalogQuery] instance for querying database metadata.
  CatalogQuery catalogQuery(int connectionId) =>
      CatalogQuery(this, connectionId);

  @override
  Uint8List? catalogColumns(int connectionId, String table) =>
      _native.catalogColumns(connectionId, table);

  @override
  Uint8List? catalogTypeInfo(int connectionId) =>
      _native.catalogTypeInfo(connectionId);

  @override
  Uint8List? catalogPrimaryKeys(int connectionId, String table) =>
      _native.catalogPrimaryKeys(connectionId, table);

  @override
  Uint8List? catalogForeignKeys(int connectionId, String table) =>
      _native.catalogForeignKeys(connectionId, table);

  @override
  Uint8List? catalogIndexes(int connectionId, String table) =>
      _native.catalogIndexes(connectionId, table);

  /// Creates a new connection pool.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a pool ID on success, 0 on failure.
  int poolCreate(String connectionString, int maxSize) =>
      _native.poolCreate(connectionString, maxSize);

  /// Creates a new connection pool and returns a [ConnectionPool] wrapper.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a [ConnectionPool] on success, null on failure.
  ConnectionPool? createConnectionPool(String connectionString, int maxSize) {
    final poolId = poolCreate(connectionString, maxSize);
    if (poolId == 0) return null;
    return ConnectionPool(this, poolId);
  }

  @override
  int poolGetConnection(int poolId) => _native.poolGetConnection(poolId);

  @override
  bool poolReleaseConnection(int connectionId) =>
      _native.poolReleaseConnection(connectionId);

  @override
  bool poolHealthCheck(int poolId) => _native.poolHealthCheck(poolId);

  @override
  ({int size, int idle})? poolGetState(int poolId) =>
      _native.poolGetState(poolId);

  /// Returns pool state telemetry payload as JSON, or null on failure.
  Map<String, dynamic>? poolGetStateJson(int poolId) =>
      _native.poolGetStateJson(poolId);

  @override
  bool poolSetSize(int poolId, int newMaxSize) =>
      _native.poolSetSize(poolId, newMaxSize);

  @override
  bool poolClose(int poolId) => _native.poolClose(poolId);

  /// Performs a bulk insert operation.
  ///
  /// Inserts multiple rows into [table] using the specified [columns].
  /// The [dataBuffer] contains the data as a binary buffer created by
  /// [BulkInsertBuilder.build()].
  ///
  /// The [rowCount] specifies how many rows are in [dataBuffer].
  /// Returns the number of rows inserted on success, 0 on failure.
  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) =>
      _native.bulkInsertArray(
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      );

  /// Performs parallel bulk insert through [poolId].
  ///
  /// Uses pool-managed parallel workers in Rust. Returns rows inserted on
  /// success, or negative value on failure.
  @override
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) =>
      _native.bulkInsertParallel(
        poolId,
        table,
        columns,
        dataBuffer,
        parallelism,
      );

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
  }) =>
      _native.streamStartBatched(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
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
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async* {
    final streamId = _native.streamStartBatched(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );

    if (streamId == 0) {
      throw Exception('Failed to start batched stream: ${_native.getError()}');
    }

    var pending = BytesBuilder(copy: false);
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

        while (pending.length >= BinaryProtocolParser.headerSize) {
          final all = pending.toBytes();
          final msgLen = BinaryProtocolParser.messageLengthFromHeader(all);
          if (all.length < msgLen) break;

          final msg = all.sublist(0, msgLen);
          yield BinaryProtocolParser.parse(msg);

          final remainder = all.sublist(msgLen);
          pending = BytesBuilder(copy: false);
          if (remainder.isNotEmpty) pending.add(remainder);
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

  /// Executes a SQL query and returns results as a stream.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a valid SQL SELECT statement.
  ///
  /// The [chunkSize] specifies how many rows to fetch per chunk
  /// (default: 1000). Results are streamed as [ParsedRowBuffer] instances,
  /// allowing efficient processing of large result sets without loading
  /// everything into memory.
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
  }
}
