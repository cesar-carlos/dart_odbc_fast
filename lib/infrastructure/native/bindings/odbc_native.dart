import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi_buffer_helper.dart'
    show callWithBuffer, initialBufferSize, maxBufferSize;
import 'library_loader.dart';
import 'odbc_bindings.dart' as bindings;

import '../errors/structured_error.dart';
import '../protocol/param_value.dart';

const int _errorBufferSize = 4096;
const int _defaultStreamChunkSize = 1000;

class OdbcNative {
  late final bindings.OdbcBindings _bindings;
  late final ffi.DynamicLibrary _library;

  OdbcNative() {
    _library = loadOdbcLibrary();
    _bindings = bindings.OdbcBindings(_library);
  }

  bool init() {
    final result = _bindings.odbc_init();
    return result == 0;
  }

  int connect(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final connId = _bindings.odbc_connect(connStrPtr.cast<bindings.Utf8>());
      return connId;
    } finally {
      malloc.free(connStrPtr);
    }
  }

  bool disconnect(int connectionId) {
    final result = _bindings.odbc_disconnect(connectionId);
    return result == 0;
  }

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

  int streamStart(int connectionId, String sql,
      {int chunkSize = _defaultStreamChunkSize}) {
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

  StreamFetchResult streamFetch(int streamId) {
    int size = initialBufferSize;
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
        malloc.free(buf);
        malloc.free(outWritten);
        malloc.free(hasMore);
      }
    }
    return StreamFetchResult(
      success: false,
      data: null,
      hasMore: false,
    );
  }

  bool streamClose(int streamId) {
    final result = _bindings.odbc_stream_close(streamId);
    return result == 0;
  }

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

  int transactionBegin(int connectionId, int isolationLevel) {
    return _bindings.odbc_transaction_begin(connectionId, isolationLevel);
  }

  bool transactionCommit(int txnId) {
    return _bindings.odbc_transaction_commit(txnId) == 0;
  }

  bool transactionRollback(int txnId) {
    return _bindings.odbc_transaction_rollback(txnId) == 0;
  }

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
      malloc.free(buf);
      malloc.free(outWritten);
    }
  }

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

  Uint8List? executeTyped(int stmtId, [List<ParamValue>? params]) {
    if (params == null || params.isEmpty) {
      return execute(stmtId, null);
    }
    return execute(stmtId, serializeParams(params));
  }

  bool cancelStatement(int stmtId) {
    return _bindings.odbc_cancel(stmtId) == 0;
  }

  bool closeStatement(int stmtId) {
    return _bindings.odbc_close_statement(stmtId) == 0;
  }

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

  int poolGetConnection(int poolId) {
    return _bindings.odbc_pool_get_connection(poolId);
  }

  bool poolReleaseConnection(int connectionId) {
    return _bindings.odbc_pool_release_connection(connectionId) == 0;
  }

  bool poolHealthCheck(int poolId) {
    return _bindings.odbc_pool_health_check(poolId) == 1;
  }

  ({int size, int idle})? poolGetState(int poolId) {
    final outSize = malloc<ffi.Uint32>();
    final outIdle = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_pool_get_state(poolId, outSize, outIdle);
      if (code != 0) return null;
      return (size: outSize.value, idle: outIdle.value);
    } finally {
      malloc.free(outSize);
      malloc.free(outIdle);
    }
  }

  bool poolClose(int poolId) {
    return _bindings.odbc_pool_close(poolId) == 0;
  }

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
      for (final p in utf8Ptrs) malloc.free(p);
      malloc.free(colPtrs);
      malloc.free(tablePtr);
    }
  }

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
      malloc.free(aPtr);
      malloc.free(bPtr);
    }
  }

  T? _withConn<T>(int connId, T? Function(int) f) => f(connId);
}

class OdbcMetrics {
  final int queryCount;
  final int errorCount;
  final int uptimeSecs;
  final int totalLatencyMillis;
  final int avgLatencyMillis;

  const OdbcMetrics({
    required this.queryCount,
    required this.errorCount,
    required this.uptimeSecs,
    required this.totalLatencyMillis,
    required this.avgLatencyMillis,
  });

  static OdbcMetrics fromBytes(Uint8List b) {
    final d = ByteData.sublistView(b);
    return OdbcMetrics(
      queryCount: d.getUint64(0, Endian.little),
      errorCount: d.getUint64(8, Endian.little),
      uptimeSecs: d.getUint64(16, Endian.little).toInt(),
      totalLatencyMillis: d.getUint64(24, Endian.little).toInt(),
      avgLatencyMillis: d.getUint64(32, Endian.little).toInt(),
    );
  }
}

class StreamFetchResult {
  final bool success;
  final List<int>? data;
  final bool hasMore;

  StreamFetchResult({
    required this.success,
    required this.data,
    required this.hasMore,
  });
}
