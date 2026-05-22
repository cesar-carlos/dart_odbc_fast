// FFI symbol names match the native ABI.
// ignore_for_file: non_constant_identifier_names

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart';
import 'package:odbc_fast/infrastructure/native/bindings/test_odbc_bindings.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart'
    show StructuredError;

/// Preset [OdbcBindings] stubs for FFI/bindings unit tests (no live DSN).
class FakeOdbcBindings {
  FakeOdbcBindings._();

  /// Full native symbol surface from the loaded engine library.
  static OdbcBindings production() => TestOdbcBindings();

  /// Simulates a pre–async-quintet / pre–audit native binary.
  static OdbcBindings legacyMinimal() => TestOdbcBindings(
        capabilities: const TestOdbcBindingsCapabilities(
          supportsAuditApi: false,
          supportsDriverCapabilitiesApi: false,
          supportsAsyncExecuteApi: false,
          supportsAsyncExecuteParamsApi: false,
          supportsAsyncStreamApi: false,
          supportsTransactionAccessMode: false,
          supportsTransactionLockTimeout: false,
          supportsXa: false,
          supportsExecQueryMultiParams: false,
          supportsPoolCreateWithOptions: false,
          hasConnectWithTimeoutSymbol: false,
        ),
      );

  /// Async execute quintet present, params/multi/audit/XA absent.
  static OdbcBindings asyncOnly() => TestOdbcBindings(
        capabilities: const TestOdbcBindingsCapabilities(
          supportsAuditApi: false,
          supportsDriverCapabilitiesApi: false,
          supportsAsyncExecuteParamsApi: false,
          supportsExecQueryMultiParams: false,
          supportsXa: false,
        ),
      );

  /// Audit quartet exported; other optional APIs absent.
  static OdbcBindings auditOnly() => TestOdbcBindings(
        capabilities: const TestOdbcBindingsCapabilities(
          supportsDriverCapabilitiesApi: false,
          supportsAsyncExecuteApi: false,
          supportsAsyncStreamApi: false,
          supportsXa: false,
          supportsExecQueryMultiParams: false,
        ),
      );

  /// Transaction v2/v3 routing without XA or async.
  static OdbcBindings transactionV1Only() => TestOdbcBindings(
        capabilities: const TestOdbcBindingsCapabilities(
          supportsTransactionAccessMode: false,
          supportsTransactionLockTimeout: false,
        ),
        overrides: TestOdbcBindingsOverrides(
          transactionBegin: (connId, isolation, dialect) => 42,
          transactionBeginV2: (connId, isolation, dialect, accessMode) => 43,
          transactionBeginV3:
              (connId, isolation, dialect, accessMode, lockTimeout) => 44,
        ),
      );

  /// Custom stub with selective symbol presence and FFI behavior.
  static OdbcBindings custom({
    TestOdbcBindingsCapabilities capabilities =
        const TestOdbcBindingsCapabilities(),
    TestOdbcBindingsOverrides overrides = const TestOdbcBindingsOverrides(),
  }) =>
      TestOdbcBindings(capabilities: capabilities, overrides: overrides);

  /// Stub with injectable FFI handlers for exec, stream-multi, structured
  /// error.
  static StubOdbcBindings stub({
    TestOdbcBindingsCapabilities capabilities =
        const TestOdbcBindingsCapabilities(),
    TestOdbcBindingsOverrides overrides = const TestOdbcBindingsOverrides(),
    StubOdbcBindingsHandlers handlers = const StubOdbcBindingsHandlers(),
  }) =>
      StubOdbcBindings(
        capabilities: capabilities,
        overrides: overrides,
        handlers: handlers,
      );

  /// Binary payload matching [StructuredError.deserialize] wire layout.
  static Uint8List structuredErrorPayload({
    String sqlState = 'HY000',
    int nativeCode = 100,
    String message = 'driver failure',
  }) {
    final msgBytes = utf8.encode(message);
    final buf = ByteData(13 + msgBytes.length);
    for (var i = 0; i < 5 && i < sqlState.length; i++) {
      buf.setUint8(i, sqlState.codeUnitAt(i));
    }
    buf
      ..setInt32(5, nativeCode, Endian.little)
      ..setUint32(9, msgBytes.length, Endian.little);
    for (var i = 0; i < msgBytes.length; i++) {
      buf.setUint8(13 + i, msgBytes[i]);
    }
    return buf.buffer.asUint8List();
  }

  /// Writes [payload] into [buffer] and sets [outWritten].
  static void writePayload(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    Uint8List payload,
  ) {
    outWritten.value = payload.length;
    final n = payload.length < bufferLen ? payload.length : bufferLen;
    for (var i = 0; i < n; i++) {
      buffer[i] = payload[i];
    }
  }

  /// Writes [message] into a native error buffer for validate-connection tests.
  static int Function(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> errorBuffer,
    int errorBufferLen,
  ) validateConnectionStringReturns(
    String message, {
    int code = 1,
  }) {
    return (
      ffi.Pointer<Utf8> connStr,
      ffi.Pointer<ffi.Uint8> errorBuffer,
      int len,
    ) {
      final bytes = message.codeUnits;
      final max = len < bytes.length + 1 ? len : bytes.length + 1;
      for (var i = 0; i < max - 1 && i < bytes.length; i++) {
        errorBuffer[i] = bytes[i];
      }
      if (max > 0) {
        errorBuffer[max - 1] = 0;
      }
      return code;
    };
  }

  /// Populates the error buffer for odbc_get_error stub callbacks.
  static int Function(ffi.Pointer<ffi.Int8> buffer, int bufferLen)
      getErrorWrites(
    String message,
  ) {
    return (ffi.Pointer<ffi.Int8> buffer, int bufferLen) {
      final bytes = message.codeUnits;
      final n = bytes.length < bufferLen ? bytes.length : bufferLen;
      for (var i = 0; i < n; i++) {
        buffer[i] = bytes[i];
      }
      return n;
    };
  }

  /// 40-byte wire layout for native metrics decoding.
  static Uint8List metricsPayload({
    int queryCount = 10,
    int errorCount = 1,
    int uptimeSecs = 100,
    int totalLatencyMillis = 500,
    int avgLatencyMillis = 50,
  }) {
    final buf = ByteData(40)
      ..setUint64(0, queryCount, Endian.little)
      ..setUint64(8, errorCount, Endian.little)
      ..setUint64(16, uptimeSecs, Endian.little)
      ..setUint64(24, totalLatencyMillis, Endian.little)
      ..setUint64(32, avgLatencyMillis, Endian.little);
    return buf.buffer.asUint8List();
  }

  /// Row-major v1 frame: one `id` column, one row (value `1`).
  static Uint8List minimalStreamRowMajorFrame() {
    final bytes = <int>[];
    const magic = 0x4F444243;
    const version = 1;
    const columnCount = 1;
    const rowCount = 1;
    const odbcInteger = 2;
    const columnName = 'id';
    const payloadSize = 15;

    void writeInt(int value, int length) {
      for (var i = 0; i < length; i++) {
        bytes.add((value >> (i * 8)) & 0xFF);
      }
    }

    writeInt(magic, 4);
    writeInt(version, 2);
    writeInt(columnCount, 2);
    writeInt(rowCount, 4);
    writeInt(payloadSize, 4);
    writeInt(odbcInteger, 2);
    writeInt(columnName.length, 2);
    bytes
      ..addAll(columnName.codeUnits)
      ..add(0);
    writeInt(4, 4);
    writeInt(1, 4);
    return Uint8List.fromList(bytes);
  }

  /// Decodes a null-terminated UTF-8 string from a native [Utf8] pointer.
  static String readUtf8Pointer(ffi.Pointer<Utf8> ptr) {
    final codeUnits = <int>[];
    var i = 0;
    while (ptr.cast<ffi.Uint8>()[i] != 0) {
      codeUnits.add(ptr.cast<ffi.Uint8>()[i]);
      i++;
    }
    return utf8.decode(codeUnits);
  }

  /// odbc_prepare stub that records SQL text and returns the statement id.
  static int Function(int connId, ffi.Pointer<Utf8> sql, int timeoutMs)
      prepareCapturing(
    void Function(String sql) onSql, {
    int stmtId = 7,
  }) {
    return (int connId, ffi.Pointer<Utf8> sql, int timeoutMs) {
      onSql(readUtf8Pointer(sql));
      return stmtId;
    };
  }

  /// odbc_stream_fetch stub that yields chunks in order, then empty chunks.
  static TestOdbcBindingsOverrides streamFetchChunks(
    List<Uint8List> chunks,
  ) {
    var index = 0;
    return TestOdbcBindingsOverrides(
      streamFetch: (
        streamId,
        outBuf,
        bufLen,
        outWritten,
        hasMore,
      ) {
        if (index >= chunks.length) {
          outWritten.value = 0;
          hasMore.value = 0;
          return 0;
        }
        final chunk = chunks[index++];
        final n = chunk.length < bufLen ? chunk.length : bufLen;
        outBuf.asTypedList(n).setAll(0, chunk.sublist(0, n));
        outWritten.value = n;
        hasMore.value = 0;
        return 0;
      },
    );
  }
}

/// Optional FFI handlers for [StubOdbcBindings].
class StubOdbcBindingsHandlers {
  const StubOdbcBindingsHandlers({
    this.structuredError,
    this.structuredErrorForConnection,
    this.execQuery,
    this.execQueryParams,
    this.execQueryMulti,
    this.execute,
    this.disconnect,
    this.catalogTables,
    this.catalogColumns,
    this.catalogTypeInfo,
    this.catalogPrimaryKeys,
    this.catalogForeignKeys,
    this.catalogIndexes,
    this.detectDriver,
    this.xaEnd,
    this.streamMultiStartBatched,
    this.streamMultiStartAsync,
    this.forceSupportsMultiResultStream,
    this.forceSupportsAsyncMultiResultStream,
    this.forceSupportsStructuredErrorForConnection,
  });

  final int Function(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? structuredError;

  final int? Function(
    int connId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? structuredErrorForConnection;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? execQuery;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? execQueryMulti;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? execQueryParams;

  final int Function(
    int stmtId,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    int timeoutOverrideMs,
    int fetchSize,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? execute;

  final int Function(int connId)? disconnect;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> catalog,
    ffi.Pointer<Utf8> schema,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? catalogTables;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? catalogColumns;

  final int Function(
    int connId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? catalogTypeInfo;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? catalogPrimaryKeys;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? catalogForeignKeys;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? catalogIndexes;

  final int Function(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Int8> outBuf,
    int bufLen,
  )? detectDriver;

  final int Function(int xaId)? xaEnd;

  final int? Function(int connId, ffi.Pointer<Utf8> sql, int chunkSize)?
      streamMultiStartBatched;

  final int? Function(int connId, ffi.Pointer<Utf8> sql, int chunkSize)?
      streamMultiStartAsync;

  final bool? forceSupportsMultiResultStream;
  final bool? forceSupportsAsyncMultiResultStream;
  final bool? forceSupportsStructuredErrorForConnection;
}

/// [TestOdbcBindings] with extra overrides for Wave 4A coverage paths.
class StubOdbcBindings extends TestOdbcBindings {
  StubOdbcBindings({
    super.capabilities,
    super.overrides,
    StubOdbcBindingsHandlers handlers = const StubOdbcBindingsHandlers(),
  }) : _handlers = handlers;

  final StubOdbcBindingsHandlers _handlers;

  @override
  bool get supportsMultiResultStream =>
      _handlers.forceSupportsMultiResultStream ??
      super.supportsMultiResultStream;

  @override
  bool get supportsAsyncMultiResultStream =>
      _handlers.forceSupportsAsyncMultiResultStream ??
      super.supportsAsyncMultiResultStream;

  @override
  bool get supportsStructuredErrorForConnection =>
      _handlers.forceSupportsStructuredErrorForConnection ??
      super.supportsStructuredErrorForConnection;

  @override
  int odbc_get_structured_error(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.structuredError?.call(buffer, bufferLen, outWritten) ??
      super.odbc_get_structured_error(buffer, bufferLen, outWritten);

  @override
  int? odbc_get_structured_error_for_connection(
    int connId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    if (_handlers.forceSupportsStructuredErrorForConnection == false) {
      return null;
    }
    final handler = _handlers.structuredErrorForConnection;
    if (handler != null) {
      return handler(connId, buffer, bufferLen, outWritten);
    }
    return super.odbc_get_structured_error_for_connection(
      connId,
      buffer,
      bufferLen,
      outWritten,
    );
  }

  @override
  int odbc_exec_query(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.execQuery?.call(connId, sql, outBuf, bufLen, outWritten) ??
      super.odbc_exec_query(connId, sql, outBuf, bufLen, outWritten);

  @override
  int odbc_exec_query_multi(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.execQueryMulti?.call(connId, sql, outBuf, bufLen, outWritten) ??
      super.odbc_exec_query_multi(connId, sql, outBuf, bufLen, outWritten);

  @override
  int odbc_exec_query_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.execQueryParams?.call(
        connId,
        sql,
        paramsBuffer,
        paramsLen,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_exec_query_params(
        connId,
        sql,
        paramsBuffer,
        paramsLen,
        outBuf,
        bufLen,
        outWritten,
      );

  @override
  int odbc_execute(
    int stmtId,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    int timeoutOverrideMs,
    int fetchSize,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.execute?.call(
        stmtId,
        paramsBuffer,
        paramsLen,
        timeoutOverrideMs,
        fetchSize,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_execute(
        stmtId,
        paramsBuffer,
        paramsLen,
        timeoutOverrideMs,
        fetchSize,
        outBuf,
        bufLen,
        outWritten,
      );

  @override
  int odbc_disconnect(int connId) =>
      _handlers.disconnect?.call(connId) ?? super.odbc_disconnect(connId);

  @override
  int odbc_catalog_tables(
    int connId,
    ffi.Pointer<Utf8> catalog,
    ffi.Pointer<Utf8> schema,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.catalogTables?.call(
        connId,
        catalog,
        schema,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_catalog_tables(
        connId,
        catalog,
        schema,
        outBuf,
        bufLen,
        outWritten,
      );

  @override
  int odbc_catalog_columns(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.catalogColumns?.call(
        connId,
        table,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_catalog_columns(connId, table, outBuf, bufLen, outWritten);

  @override
  int odbc_catalog_type_info(
    int connId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.catalogTypeInfo?.call(connId, outBuf, bufLen, outWritten) ??
      super.odbc_catalog_type_info(connId, outBuf, bufLen, outWritten);

  @override
  int odbc_catalog_primary_keys(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.catalogPrimaryKeys?.call(
        connId,
        table,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_catalog_primary_keys(
        connId,
        table,
        outBuf,
        bufLen,
        outWritten,
      );

  @override
  int odbc_catalog_foreign_keys(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.catalogForeignKeys?.call(
        connId,
        table,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_catalog_foreign_keys(
        connId,
        table,
        outBuf,
        bufLen,
        outWritten,
      );

  @override
  int odbc_catalog_indexes(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _handlers.catalogIndexes?.call(
        connId,
        table,
        outBuf,
        bufLen,
        outWritten,
      ) ??
      super.odbc_catalog_indexes(connId, table, outBuf, bufLen, outWritten);

  @override
  int odbc_detect_driver(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Int8> outBuf,
    int bufLen,
  ) =>
      _handlers.detectDriver?.call(connStr, outBuf, bufLen) ??
      super.odbc_detect_driver(connStr, outBuf, bufLen);

  @override
  int odbc_xa_end(int xaId) =>
      _handlers.xaEnd?.call(xaId) ?? super.odbc_xa_end(xaId);

  @override
  int? odbc_stream_multi_start_batched(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) {
    if (_handlers.forceSupportsMultiResultStream == false) {
      return null;
    }
    final handler = _handlers.streamMultiStartBatched;
    if (handler != null) {
      return handler(connId, sql, chunkSize);
    }
    return super.odbc_stream_multi_start_batched(connId, sql, chunkSize);
  }

  @override
  int? odbc_stream_multi_start_async(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) {
    if (_handlers.forceSupportsAsyncMultiResultStream == false) {
      return null;
    }
    final handler = _handlers.streamMultiStartAsync;
    if (handler != null) {
      return handler(connId, sql, chunkSize);
    }
    return super.odbc_stream_multi_start_async(connId, sql, chunkSize);
  }
}
