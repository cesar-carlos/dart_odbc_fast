import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart' as domain;
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart'
    as bindings;
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
  NativeOdbcConnection() : _native = bindings.OdbcNative();
  final bindings.OdbcNative _native;
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

  /// Gets the last error message from the native engine.
  ///
  /// Returns an empty string if no error occurred.
  String getError() => _native.getError();

  /// Gets structured error information including SQLSTATE and native code.
  ///
  /// Returns null if no error occurred or if structured error info
  /// is not available.
  StructuredError? getStructuredError() => _native.getStructuredError();

  /// Whether the ODBC environment has been initialized.
  bool get isInitialized => _isInitialized;

  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3) corresponding
  /// to isolation level enum values (0=ReadUncommitted, 1=ReadCommitted,
  /// 2=RepeatableRead, 3=Serializable).
  ///
  /// Returns a transaction ID on success, 0 on failure.
  int beginTransaction(int connectionId, int isolationLevel) =>
      _native.transactionBegin(connectionId, isolationLevel);

  /// Begins a new transaction and returns a [TransactionHandle] wrapper.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3) corresponding
  /// to isolation level enum values (0=ReadUncommitted, 1=ReadCommitted,
  /// 2=RepeatableRead, 3=Serializable).
  ///
  /// Returns a [TransactionHandle] on success, null on failure.
  TransactionHandle? beginTransactionHandle(
    int connectionId,
    int isolationLevel,
  ) {
    final txnId = beginTransaction(connectionId, isolationLevel);
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

  /// Gets performance and operational metrics.
  ///
  /// Returns [OdbcMetrics] containing query counts, error counts,
  /// uptime, and latency information, or null on failure.
  OdbcMetrics? getMetrics() => domain.OdbcMetrics(
        queryCount: _native.getMetrics()?.queryCount ?? 0,
        errorCount: _native.getMetrics()?.errorCount ?? 0,
        uptimeSecs: _native.getMetrics()?.uptimeSecs ?? 0,
        totalLatencyMillis: _native.getMetrics()?.totalLatencyMillis ?? 0,
        avgLatencyMillis: _native.getMetrics()?.avgLatencyMillis ?? 0,
      );

  ///
  /// Clears the prepared statement cache.
  ///
  /// Returns true on success, false on failure.
  bool clearStatementCache() => _native.clearStatementCache();

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
