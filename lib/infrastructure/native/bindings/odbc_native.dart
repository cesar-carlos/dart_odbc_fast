import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations.
  /// Returns true on success, false on failure.
  bool init() {
    final result = _bindings.odbc_init();
    return result == 0;
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
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQuery(int connectionId, String sql) {
    return _withSql(
      sql,
      (ffi.Pointer<bindings.Utf8> sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_exec_query(
          connectionId,
          sqlPtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Executes a SQL query with binary parameters.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] should be a binary buffer containing serialized parameters.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryParams(
    int connectionId,
    String sql,
    Uint8List? params,
  ) {
    return _withSql(
      sql,
      (ffi.Pointer<bindings.Utf8> sqlPtr) {
        if (params == null || params.isEmpty) {
          return callWithBuffer(
            (buf, bufLen, outWritten) => _bindings.odbc_exec_query_params(
              connectionId,
              sqlPtr,
              null,
              0,
              buf,
              bufLen,
              outWritten,
            ),
          );
        }
        return _withParamsBuffer(
          params,
          (ffi.Pointer<ffi.Uint8> paramsPtr) => callWithBuffer(
            (buf, bufLen, outWritten) => _bindings.odbc_exec_query_params(
              connectionId,
              sqlPtr,
              paramsPtr,
              params.length,
              buf,
              bufLen,
              outWritten,
            ),
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
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryParamsTyped(
    int connectionId,
    String sql,
    List<ParamValue> params,
  ) {
    if (params.isEmpty) {
      return execQueryParams(connectionId, sql, null);
    }
    final buf = serializeParams(params);
    return execQueryParams(connectionId, sql, buf);
  }

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  /// The [connectionId] must be a valid active connection.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryMulti(int connectionId, String sql) {
    return _withSql(
      sql,
      (ffi.Pointer<bindings.Utf8> sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_exec_query_multi(
          connectionId,
          sqlPtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3).
  ///
  /// Returns a transaction ID on success, 0 on failure.
  int transactionBegin(int connectionId, int isolationLevel) {
    return _bindings.odbc_transaction_begin(connectionId, isolationLevel);
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
      (ffi.Pointer<bindings.Utf8> cPtr, ffi.Pointer<bindings.Utf8> sPtr) =>
          _withConn(
        connectionId,
        (int conn) => callWithBuffer(
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
      (ffi.Pointer<bindings.Utf8> tablePtr) => callWithBuffer(
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
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execute(
    int stmtId, [
    Uint8List? params,
  ]) {
    if (params == null || params.isEmpty) {
      return callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_execute(
          stmtId,
          null,
          0,
          buf,
          bufLen,
          outWritten,
        ),
      );
    }
    return _withParamsBuffer(
      params,
      (ffi.Pointer<ffi.Uint8> paramsPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_execute(
          stmtId,
          paramsPtr,
          params.length,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Executes a prepared statement with typed parameters.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder, in order, or null if no parameters are needed.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeTyped(int stmtId, [List<ParamValue>? params]) {
    if (params == null || params.isEmpty) {
      return execute(stmtId);
    }
    return execute(stmtId, serializeParams(params));
  }

  /// Cancels a prepared statement execution.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
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
