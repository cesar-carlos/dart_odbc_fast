// FFI symbol names match the native ABI.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart';

/// Optional FFI overrides for [TestOdbcBindings] (unit tests only).
@visibleForTesting
class TestOdbcBindingsOverrides {
  const TestOdbcBindingsOverrides({
    this.validateConnectionString,
    this.getError,
    this.init,
    this.connect,
    this.connectWithTimeout,
    this.transactionBegin,
    this.transactionBeginV2,
    this.transactionBeginV3,
    this.prepare,
    this.poolCreate,
    this.poolCreateWithOptions,
    this.getDriverCapabilities,
    this.getConnectionDbmsInfo,
    this.execQueryMultiParams,
    this.executeAsync,
    this.auditEnable,
    this.auditGetEvents,
    this.auditClear,
    this.auditGetStatus,
    this.xaStart,
    this.xaRecoverCount,
    this.xaRecoverGet,
    this.getMetrics,
    this.disconnect,
    this.transactionCommit,
    this.transactionRollback,
    this.savepointCreate,
    this.savepointRollback,
    this.savepointRelease,
    this.poolGetConnection,
    this.poolReleaseConnection,
    this.poolHealthCheck,
    this.poolGetState,
    this.poolGetStateJson,
    this.poolSetSize,
    this.poolClose,
    this.asyncPoll,
    this.asyncCancel,
    this.asyncFree,
    this.streamStartAsync,
    this.streamPollAsync,
    this.streamStart,
    this.streamStartBatched,
    this.streamFetch,
    this.streamClose,
  });

  final int Function(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> errorBuffer,
    int errorBufferLen,
  )? validateConnectionString;

  final int Function(ffi.Pointer<ffi.Int8> buffer, int bufferLen)? getError;

  final int Function()? init;

  final int Function(ffi.Pointer<Utf8> connStr)? connect;

  final int Function(ffi.Pointer<Utf8> connStr, int timeoutMs)?
      connectWithTimeout;

  final int Function(int connId, int isolationLevel, int savepointDialect)?
      transactionBegin;

  final int Function(
    int connId,
    int isolationLevel,
    int savepointDialect,
    int accessMode,
  )? transactionBeginV2;

  final int Function(
    int connId,
    int isolationLevel,
    int savepointDialect,
    int accessMode,
    int lockTimeoutMs,
  )? transactionBeginV3;

  final int Function(int connId, ffi.Pointer<Utf8> sql, int timeoutMs)? prepare;

  final int Function(int connId)? disconnect;

  final int Function(int txnId)? transactionCommit;

  final int Function(int txnId)? transactionRollback;

  final int Function(int txnId, ffi.Pointer<Utf8> name)? savepointCreate;

  final int Function(int txnId, ffi.Pointer<Utf8> name)? savepointRollback;

  final int Function(int txnId, ffi.Pointer<Utf8> name)? savepointRelease;

  final int Function(ffi.Pointer<Utf8> connStr, int maxSize)? poolCreate;

  final int Function(
    ffi.Pointer<Utf8> connStr,
    int maxSize,
    ffi.Pointer<Utf8>? optionsJson,
  )? poolCreateWithOptions;

  final int Function(int poolId)? poolGetConnection;

  final int Function(int connectionId)? poolReleaseConnection;

  final int Function(int poolId)? poolHealthCheck;

  final int Function(
    int poolId,
    ffi.Pointer<ffi.Uint32> outSize,
    ffi.Pointer<ffi.Uint32> outIdle,
  )? poolGetState;

  final int Function(
    int poolId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? poolGetStateJson;

  final int Function(int poolId, int newMaxSize)? poolSetSize;

  final int Function(int poolId)? poolClose;

  final int Function(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? getDriverCapabilities;

  final int Function(
    int connId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? getConnectionDbmsInfo;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? execQueryMultiParams;

  final int? Function(int connId, ffi.Pointer<Utf8> sql)? executeAsync;

  final int? Function(int requestId, ffi.Pointer<ffi.Int32> outStatus)?
      asyncPoll;

  final int? Function(int requestId)? asyncCancel;

  final int? Function(int requestId)? asyncFree;

  final int Function(int enabled)? auditEnable;

  final int Function(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    int limit,
  )? auditGetEvents;

  final int Function()? auditClear;

  final int Function(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? auditGetStatus;

  final int Function(
    int connId,
    int formatId,
    ffi.Pointer<ffi.Uint8> gtridPtr,
    int gtridLen,
    ffi.Pointer<ffi.Uint8> bqualPtr,
    int bqualLen,
  )? xaStart;

  final int Function(int connId)? xaRecoverCount;

  final int Function(
    int index,
    ffi.Pointer<ffi.Int32> outFormatId,
    ffi.Pointer<ffi.Uint8> gtridBuf,
    int gtridBufLen,
    ffi.Pointer<ffi.Uint32> outGtridLen,
    ffi.Pointer<ffi.Uint8> bqualBuf,
    int bqualBufLen,
    ffi.Pointer<ffi.Uint32> outBqualLen,
  )? xaRecoverGet;

  final int Function(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  )? getMetrics;

  final int? Function(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  )? streamStartAsync;

  final int? Function(int streamId, ffi.Pointer<ffi.Int32> outStatus)?
      streamPollAsync;

  final int Function(int connId, ffi.Pointer<Utf8> sql, int chunkSize)?
      streamStart;

  final int Function(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  )? streamStartBatched;

  final int Function(
    int streamId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    ffi.Pointer<ffi.Uint8> hasMore,
  )? streamFetch;

  final int Function(int streamId)? streamClose;
}

/// Capability flags forced for [TestOdbcBindings] getters.
///
/// Null capability fields fall back to the loaded library.
@visibleForTesting
class TestOdbcBindingsCapabilities {
  const TestOdbcBindingsCapabilities({
    this.supportsAuditApi,
    this.supportsDriverCapabilitiesApi,
    this.supportsConnectionDbmsInfoApi,
    this.supportsAsyncExecuteApi,
    this.supportsAsyncExecuteParamsApi,
    this.supportsAsyncExecuteParamsOptionsApi,
    this.supportsAsyncStreamApi,
    this.supportsTransactionAccessMode,
    this.supportsTransactionLockTimeout,
    this.supportsXa,
    this.supportsExecQueryMultiParams,
    this.supportsExecQueryParamsOptions,
    this.supportsStreamResultEncodingOptions,
    this.supportsStreamStartParamsOptions,
    this.supportsStreamAsyncEncodingOptions,
    this.supportsMultiResultStreamEncodingOptions,
    this.supportsMultiResultStreamAsyncEncodingOptions,
    this.supportsPoolCreateWithOptions,
    this.hasConnectWithTimeoutSymbol,
  });

  final bool? supportsAuditApi;
  final bool? supportsDriverCapabilitiesApi;
  final bool? supportsConnectionDbmsInfoApi;
  final bool? supportsAsyncExecuteApi;
  final bool? supportsAsyncExecuteParamsApi;
  final bool? supportsAsyncExecuteParamsOptionsApi;
  final bool? supportsAsyncStreamApi;
  final bool? supportsTransactionAccessMode;
  final bool? supportsTransactionLockTimeout;
  final bool? supportsXa;
  final bool? supportsExecQueryMultiParams;
  final bool? supportsExecQueryParamsOptions;
  final bool? supportsStreamResultEncodingOptions;
  final bool? supportsStreamStartParamsOptions;
  final bool? supportsStreamAsyncEncodingOptions;
  final bool? supportsMultiResultStreamEncodingOptions;
  final bool? supportsMultiResultStreamAsyncEncodingOptions;
  final bool? supportsPoolCreateWithOptions;

  /// When false, connect-with-timeout uses the v1 connect fallback path.
  final bool? hasConnectWithTimeoutSymbol;
}

/// [OdbcBindings] subclass with injectable capability flags and FFI stubs.
@visibleForTesting
class TestOdbcBindings extends OdbcBindings {
  TestOdbcBindings({
    ffi.DynamicLibrary? library,
    TestOdbcBindingsCapabilities capabilities =
        const TestOdbcBindingsCapabilities(),
    TestOdbcBindingsOverrides overrides = const TestOdbcBindingsOverrides(),
  })  : _capabilities = capabilities,
        _overrides = overrides,
        super(library ?? loadOdbcLibrary());

  final TestOdbcBindingsCapabilities _capabilities;
  final TestOdbcBindingsOverrides _overrides;

  @override
  bool get supportsAuditApi =>
      _capabilities.supportsAuditApi ?? super.supportsAuditApi;

  @override
  bool get supportsDriverCapabilitiesApi =>
      _capabilities.supportsDriverCapabilitiesApi ??
      super.supportsDriverCapabilitiesApi;

  @override
  bool get supportsConnectionDbmsInfoApi =>
      _capabilities.supportsConnectionDbmsInfoApi ??
      super.supportsConnectionDbmsInfoApi;

  @override
  bool get supportsAsyncExecuteApi =>
      _capabilities.supportsAsyncExecuteApi ?? super.supportsAsyncExecuteApi;

  @override
  bool get supportsAsyncExecuteParamsApi =>
      _capabilities.supportsAsyncExecuteParamsApi ??
      super.supportsAsyncExecuteParamsApi;

  @override
  bool get supportsAsyncExecuteParamsOptionsApi =>
      _capabilities.supportsAsyncExecuteParamsOptionsApi ??
      super.supportsAsyncExecuteParamsOptionsApi;

  @override
  bool get supportsAsyncStreamApi =>
      _capabilities.supportsAsyncStreamApi ?? super.supportsAsyncStreamApi;

  @override
  bool get supportsTransactionAccessMode =>
      _capabilities.supportsTransactionAccessMode ??
      super.supportsTransactionAccessMode;

  @override
  bool get supportsTransactionLockTimeout =>
      _capabilities.supportsTransactionLockTimeout ??
      super.supportsTransactionLockTimeout;

  @override
  bool get supportsXa => _capabilities.supportsXa ?? super.supportsXa;

  @override
  bool get supportsExecQueryMultiParams =>
      _capabilities.supportsExecQueryMultiParams ??
      super.supportsExecQueryMultiParams;

  @override
  bool get supportsExecQueryParamsOptions =>
      _capabilities.supportsExecQueryParamsOptions ??
      super.supportsExecQueryParamsOptions;

  @override
  bool get supportsStreamResultEncodingOptions =>
      _capabilities.supportsStreamResultEncodingOptions ??
      super.supportsStreamResultEncodingOptions;

  @override
  bool get supportsStreamStartParamsOptions =>
      _capabilities.supportsStreamStartParamsOptions ??
      super.supportsStreamStartParamsOptions;

  @override
  bool get supportsStreamAsyncEncodingOptions =>
      _capabilities.supportsStreamAsyncEncodingOptions ??
      super.supportsStreamAsyncEncodingOptions;

  @override
  bool get supportsMultiResultStreamEncodingOptions =>
      _capabilities.supportsMultiResultStreamEncodingOptions ??
      super.supportsMultiResultStreamEncodingOptions;

  @override
  bool get supportsMultiResultStreamAsyncEncodingOptions =>
      _capabilities.supportsMultiResultStreamAsyncEncodingOptions ??
      super.supportsMultiResultStreamAsyncEncodingOptions;

  @override
  bool get supportsPoolCreateWithOptions =>
      _capabilities.supportsPoolCreateWithOptions ??
      super.supportsPoolCreateWithOptions;

  @override
  int odbc_validate_connection_string(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> errorBuffer,
    int errorBufferLen,
  ) =>
      _overrides.validateConnectionString?.call(
        connStr,
        errorBuffer,
        errorBufferLen,
      ) ??
      super.odbc_validate_connection_string(
        connStr,
        errorBuffer,
        errorBufferLen,
      );

  @override
  int odbc_get_error(ffi.Pointer<ffi.Int8> buffer, int bufferLen) =>
      _overrides.getError?.call(buffer, bufferLen) ??
      super.odbc_get_error(buffer, bufferLen);

  @override
  int odbc_init() => _overrides.init?.call() ?? super.odbc_init();

  @override
  int odbc_connect(ffi.Pointer<Utf8> connStr) =>
      _overrides.connect?.call(connStr) ?? super.odbc_connect(connStr);

  @override
  int odbc_connect_with_timeout(ffi.Pointer<Utf8> connStr, int timeoutMs) {
    final override = _overrides.connectWithTimeout;
    if (override != null) {
      return override(connStr, timeoutMs);
    }
    if (_capabilities.hasConnectWithTimeoutSymbol == false) {
      return odbc_connect(connStr);
    }
    return super.odbc_connect_with_timeout(connStr, timeoutMs);
  }

  @override
  int odbc_transaction_begin(
    int connId,
    int isolationLevel, [
    int savepointDialect = 0,
  ]) =>
      _overrides.transactionBegin?.call(
        connId,
        isolationLevel,
        savepointDialect,
      ) ??
      super.odbc_transaction_begin(
        connId,
        isolationLevel,
        savepointDialect,
      );

  @override
  int odbc_transaction_begin_v2(
    int connId,
    int isolationLevel,
    int savepointDialect,
    int accessMode,
  ) {
    final override = _overrides.transactionBeginV2;
    if (override != null) {
      return override(connId, isolationLevel, savepointDialect, accessMode);
    }
    if (_capabilities.supportsTransactionAccessMode == false) {
      return odbc_transaction_begin(connId, isolationLevel, savepointDialect);
    }
    return super.odbc_transaction_begin_v2(
      connId,
      isolationLevel,
      savepointDialect,
      accessMode,
    );
  }

  @override
  int odbc_transaction_begin_v3(
    int connId,
    int isolationLevel,
    int savepointDialect,
    int accessMode,
    int lockTimeoutMs,
  ) {
    final override = _overrides.transactionBeginV3;
    if (override != null) {
      return override(
        connId,
        isolationLevel,
        savepointDialect,
        accessMode,
        lockTimeoutMs,
      );
    }
    if (_capabilities.supportsTransactionLockTimeout == false) {
      return odbc_transaction_begin_v2(
        connId,
        isolationLevel,
        savepointDialect,
        accessMode,
      );
    }
    return super.odbc_transaction_begin_v3(
      connId,
      isolationLevel,
      savepointDialect,
      accessMode,
      lockTimeoutMs,
    );
  }

  @override
  int odbc_prepare(int connId, ffi.Pointer<Utf8> sql, int timeoutMs) =>
      _overrides.prepare?.call(connId, sql, timeoutMs) ??
      super.odbc_prepare(connId, sql, timeoutMs);

  @override
  int odbc_disconnect(int connId) =>
      _overrides.disconnect?.call(connId) ?? super.odbc_disconnect(connId);

  @override
  int odbc_transaction_commit(int txnId) =>
      _overrides.transactionCommit?.call(txnId) ??
      super.odbc_transaction_commit(txnId);

  @override
  int odbc_transaction_rollback(int txnId) =>
      _overrides.transactionRollback?.call(txnId) ??
      super.odbc_transaction_rollback(txnId);

  @override
  int odbc_savepoint_create(int txnId, ffi.Pointer<Utf8> name) =>
      _overrides.savepointCreate?.call(txnId, name) ??
      super.odbc_savepoint_create(txnId, name);

  @override
  int odbc_savepoint_rollback(int txnId, ffi.Pointer<Utf8> name) =>
      _overrides.savepointRollback?.call(txnId, name) ??
      super.odbc_savepoint_rollback(txnId, name);

  @override
  int odbc_savepoint_release(int txnId, ffi.Pointer<Utf8> name) =>
      _overrides.savepointRelease?.call(txnId, name) ??
      super.odbc_savepoint_release(txnId, name);

  @override
  int odbc_pool_create(ffi.Pointer<Utf8> connStr, int maxSize) =>
      _overrides.poolCreate?.call(connStr, maxSize) ??
      super.odbc_pool_create(connStr, maxSize);

  @override
  int odbc_pool_create_with_options(
    ffi.Pointer<Utf8> connStr,
    int maxSize,
    ffi.Pointer<Utf8>? optionsJson,
  ) {
    final override = _overrides.poolCreateWithOptions;
    if (override != null) {
      return override(connStr, maxSize, optionsJson);
    }
    if (_capabilities.supportsPoolCreateWithOptions == false) {
      return 0;
    }
    return super.odbc_pool_create_with_options(connStr, maxSize, optionsJson);
  }

  @override
  int odbc_pool_get_connection(int poolId) =>
      _overrides.poolGetConnection?.call(poolId) ??
      super.odbc_pool_get_connection(poolId);

  @override
  int odbc_pool_release_connection(int connectionId) =>
      _overrides.poolReleaseConnection?.call(connectionId) ??
      super.odbc_pool_release_connection(connectionId);

  @override
  int odbc_pool_health_check(int poolId) =>
      _overrides.poolHealthCheck?.call(poolId) ??
      super.odbc_pool_health_check(poolId);

  @override
  int odbc_pool_get_state(
    int poolId,
    ffi.Pointer<ffi.Uint32> outSize,
    ffi.Pointer<ffi.Uint32> outIdle,
  ) =>
      _overrides.poolGetState?.call(poolId, outSize, outIdle) ??
      super.odbc_pool_get_state(poolId, outSize, outIdle);

  @override
  int odbc_pool_get_state_json(
    int poolId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _overrides.poolGetStateJson
          ?.call(poolId, buffer, bufferLen, outWritten) ??
      super.odbc_pool_get_state_json(poolId, buffer, bufferLen, outWritten);

  @override
  int odbc_pool_set_size(int poolId, int newMaxSize) =>
      _overrides.poolSetSize?.call(poolId, newMaxSize) ??
      super.odbc_pool_set_size(poolId, newMaxSize);

  @override
  int odbc_pool_close(int poolId) =>
      _overrides.poolClose?.call(poolId) ?? super.odbc_pool_close(poolId);

  @override
  int odbc_get_driver_capabilities(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _overrides.getDriverCapabilities?.call(
        connStr,
        buffer,
        bufferLen,
        outWritten,
      ) ??
      (_capabilities.supportsDriverCapabilitiesApi == false
          ? -1
          : super.odbc_get_driver_capabilities(
              connStr,
              buffer,
              bufferLen,
              outWritten,
            ));

  @override
  int odbc_get_connection_dbms_info(
    int connId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _overrides.getConnectionDbmsInfo?.call(
        connId,
        buffer,
        bufferLen,
        outWritten,
      ) ??
      (_capabilities.supportsConnectionDbmsInfoApi == false
          ? -1
          : super.odbc_get_connection_dbms_info(
              connId,
              buffer,
              bufferLen,
              outWritten,
            ));

  @override
  int odbc_exec_query_multi_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final override = _overrides.execQueryMultiParams;
    if (override != null) {
      return override(
        connId,
        sql,
        paramsBuffer,
        paramsLen,
        outBuffer,
        bufferLen,
        outWritten,
      );
    }
    if (_capabilities.supportsExecQueryMultiParams == false) {
      throw StateError(
        'odbc_exec_query_multi_params is not exported by the loaded '
        'odbc_engine library. Rebuild against odbc_engine >= 3.2.0.',
      );
    }
    return super.odbc_exec_query_multi_params(
      connId,
      sql,
      paramsBuffer,
      paramsLen,
      outBuffer,
      bufferLen,
      outWritten,
    );
  }

  @override
  int? odbc_execute_async(int connId, ffi.Pointer<Utf8> sql) =>
      _overrides.executeAsync?.call(connId, sql) ??
      (_capabilities.supportsAsyncExecuteApi == false
          ? null
          : super.odbc_execute_async(connId, sql));

  @override
  int? odbc_async_poll(int requestId, ffi.Pointer<ffi.Int32> outStatus) {
    final override = _overrides.asyncPoll;
    if (override != null) {
      return override(requestId, outStatus);
    }
    if (_capabilities.supportsAsyncExecuteApi == false) {
      return null;
    }
    return super.odbc_async_poll(requestId, outStatus);
  }

  @override
  int? odbc_async_cancel(int requestId) {
    final override = _overrides.asyncCancel;
    if (override != null) {
      return override(requestId);
    }
    if (_capabilities.supportsAsyncExecuteApi == false) {
      return null;
    }
    return super.odbc_async_cancel(requestId);
  }

  @override
  int? odbc_async_free(int requestId) {
    final override = _overrides.asyncFree;
    if (override != null) {
      return override(requestId);
    }
    if (_capabilities.supportsAsyncExecuteApi == false) {
      return null;
    }
    return super.odbc_async_free(requestId);
  }

  @override
  int odbc_audit_enable(int enabled) =>
      _overrides.auditEnable?.call(enabled) ??
      (_capabilities.supportsAuditApi == false
          ? -1
          : super.odbc_audit_enable(enabled));

  @override
  int odbc_audit_get_events(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    int limit,
  ) =>
      _overrides.auditGetEvents?.call(buffer, bufferLen, outWritten, limit) ??
      (_capabilities.supportsAuditApi == false
          ? -1
          : super.odbc_audit_get_events(buffer, bufferLen, outWritten, limit));

  @override
  int odbc_audit_clear() =>
      _overrides.auditClear?.call() ??
      (_capabilities.supportsAuditApi == false ? -1 : super.odbc_audit_clear());

  @override
  int odbc_audit_get_status(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _overrides.auditGetStatus?.call(buffer, bufferLen, outWritten) ??
      (_capabilities.supportsAuditApi == false
          ? -1
          : super.odbc_audit_get_status(buffer, bufferLen, outWritten));

  @override
  int odbc_xa_start(
    int connId,
    int formatId,
    ffi.Pointer<ffi.Uint8> gtridPtr,
    int gtridLen,
    ffi.Pointer<ffi.Uint8> bqualPtr,
    int bqualLen,
  ) {
    final override = _overrides.xaStart;
    if (override != null) {
      return override(connId, formatId, gtridPtr, gtridLen, bqualPtr, bqualLen);
    }
    if (_capabilities.supportsXa == false) {
      throw UnsupportedError(
        'odbc_xa_start: this native library does not export the XA / 2PC FFI '
        'family (Sprint 4.3). Rebuild the native engine from a '
        '3.4+ source tree, or gate on `OdbcBindings.supportsXa` '
        'before calling.',
      );
    }
    return super.odbc_xa_start(
      connId,
      formatId,
      gtridPtr,
      gtridLen,
      bqualPtr,
      bqualLen,
    );
  }

  @override
  int odbc_xa_recover_count(int connId) {
    final override = _overrides.xaRecoverCount;
    if (override != null) {
      return override(connId);
    }
    if (_capabilities.supportsXa == false) {
      throw UnsupportedError(
        'odbc_xa_recover_count: this native library does not export the XA / '
        '2PC FFI family (Sprint 4.3).',
      );
    }
    return super.odbc_xa_recover_count(connId);
  }

  @override
  int odbc_xa_recover_get(
    int index,
    ffi.Pointer<ffi.Int32> outFormatId,
    ffi.Pointer<ffi.Uint8> gtridBuf,
    int gtridBufLen,
    ffi.Pointer<ffi.Uint32> outGtridLen,
    ffi.Pointer<ffi.Uint8> bqualBuf,
    int bqualBufLen,
    ffi.Pointer<ffi.Uint32> outBqualLen,
  ) {
    final override = _overrides.xaRecoverGet;
    if (override != null) {
      return override(
        index,
        outFormatId,
        gtridBuf,
        gtridBufLen,
        outGtridLen,
        bqualBuf,
        bqualBufLen,
        outBqualLen,
      );
    }
    if (_capabilities.supportsXa == false) {
      throw UnsupportedError(
        'odbc_xa_recover_get: this native library does not export the XA / '
        '2PC FFI family (Sprint 4.3).',
      );
    }
    return super.odbc_xa_recover_get(
      index,
      outFormatId,
      gtridBuf,
      gtridBufLen,
      outGtridLen,
      bqualBuf,
      bqualBufLen,
      outBqualLen,
    );
  }

  @override
  int odbc_get_metrics(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _overrides.getMetrics?.call(buffer, bufferLen, outWritten) ??
      super.odbc_get_metrics(buffer, bufferLen, outWritten);

  @override
  int? odbc_stream_start_async(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  ) {
    final override = _overrides.streamStartAsync;
    if (override != null) {
      return override(connId, sql, fetchSize, chunkSize);
    }
    if (_capabilities.supportsAsyncStreamApi == false) {
      return null;
    }
    return super.odbc_stream_start_async(connId, sql, fetchSize, chunkSize);
  }

  @override
  int? odbc_stream_poll_async(int streamId, ffi.Pointer<ffi.Int32> outStatus) {
    final override = _overrides.streamPollAsync;
    if (override != null) {
      return override(streamId, outStatus);
    }
    if (_capabilities.supportsAsyncStreamApi == false) {
      return null;
    }
    return super.odbc_stream_poll_async(streamId, outStatus);
  }

  @override
  int odbc_stream_start(int connId, ffi.Pointer<Utf8> sql, int chunkSize) =>
      _overrides.streamStart?.call(connId, sql, chunkSize) ??
      super.odbc_stream_start(connId, sql, chunkSize);

  @override
  int odbc_stream_start_batched(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  ) =>
      _overrides.streamStartBatched?.call(connId, sql, fetchSize, chunkSize) ??
      super.odbc_stream_start_batched(connId, sql, fetchSize, chunkSize);

  @override
  int odbc_stream_fetch(
    int streamId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    ffi.Pointer<ffi.Uint8> hasMore,
  ) =>
      _overrides.streamFetch?.call(
        streamId,
        outBuf,
        bufLen,
        outWritten,
        hasMore,
      ) ??
      super.odbc_stream_fetch(
        streamId,
        outBuf,
        bufLen,
        outWritten,
        hasMore,
      );

  @override
  int odbc_stream_close(int streamId) =>
      _overrides.streamClose?.call(streamId) ??
      super.odbc_stream_close(streamId);
}
