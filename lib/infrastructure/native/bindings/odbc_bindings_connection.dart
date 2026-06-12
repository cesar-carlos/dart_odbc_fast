part of 'odbc_bindings.dart';

mixin _OdbcBindingsConnection on _OdbcBindingsState {
  void _bindConnection() {
    _odbc_init_ptr = _dylib.lookup('odbc_init');
    _odbc_set_log_level_ptr = _dylib.lookup('odbc_set_log_level');
    _odbc_get_version_ptr = _dylib.lookup('odbc_get_version');
    _odbc_validate_connection_string_ptr =
        _dylib.lookup('odbc_validate_connection_string');
    _odbc_connect_ptr = _dylib.lookup('odbc_connect');
    try {
      _odbc_connect_with_timeout_ptr =
          _dylib.lookup('odbc_connect_with_timeout');
    } on Object catch (_) {
      _odbc_connect_with_timeout_ptr = null;
    }
    _odbc_disconnect_ptr = _dylib.lookup('odbc_disconnect');
    _odbc_get_error_ptr = _dylib.lookup('odbc_get_error');
    _odbc_get_structured_error_ptr = _dylib.lookup('odbc_get_structured_error');
    try {
      _odbc_get_structured_error_for_connection_ptr =
          _dylib.lookup('odbc_get_structured_error_for_connection');
    } on Object catch (_) {
      _odbc_get_structured_error_for_connection_ptr = null;
    }
    _odbc_detect_driver_ptr = _dylib.lookup('odbc_detect_driver');
    try {
      _odbc_audit_enable_ptr = _dylib.lookup('odbc_audit_enable');
      _odbc_audit_get_events_ptr = _dylib.lookup('odbc_audit_get_events');
      _odbc_audit_clear_ptr = _dylib.lookup('odbc_audit_clear');
      _odbc_audit_get_status_ptr = _dylib.lookup('odbc_audit_get_status');
    } on Object catch (_) {
      _odbc_audit_enable_ptr = null;
      _odbc_audit_get_events_ptr = null;
      _odbc_audit_clear_ptr = null;
      _odbc_audit_get_status_ptr = null;
    }
    try {
      _odbc_get_driver_capabilities_ptr =
          _dylib.lookup('odbc_get_driver_capabilities');
    } on Object catch (_) {
      _odbc_get_driver_capabilities_ptr = null;
    }
    try {
      _odbc_get_connection_dbms_info_ptr =
          _dylib.lookup('odbc_get_connection_dbms_info');
    } on Object catch (_) {
      _odbc_get_connection_dbms_info_ptr = null;
    }
    try {
      _odbc_build_upsert_sql_ptr = _dylib.lookup('odbc_build_upsert_sql');
      _odbc_append_returning_sql_ptr =
          _dylib.lookup('odbc_append_returning_sql');
      _odbc_get_session_init_sql_ptr =
          _dylib.lookup('odbc_get_session_init_sql');
    } on Object catch (_) {
      _odbc_build_upsert_sql_ptr = null;
      _odbc_append_returning_sql_ptr = null;
      _odbc_get_session_init_sql_ptr = null;
    }
    try {
      _odbc_metadata_cache_enable_ptr =
          _dylib.lookup('odbc_metadata_cache_enable');
      _odbc_metadata_cache_stats_ptr =
          _dylib.lookup('odbc_metadata_cache_stats');
      _odbc_metadata_cache_clear_ptr =
          _dylib.lookup('odbc_metadata_cache_clear');
    } on Object catch (_) {
      _odbc_metadata_cache_enable_ptr = null;
      _odbc_metadata_cache_stats_ptr = null;
      _odbc_metadata_cache_clear_ptr = null;
    }
  }

late final ffi.Pointer<ffi.NativeFunction<odbc_init_func>> _odbc_init_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_set_log_level_func>>
      _odbc_set_log_level_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_get_version_func>>
      _odbc_get_version_ptr;

  late final ffi
      .Pointer<ffi.NativeFunction<odbc_validate_connection_string_func>>
      _odbc_validate_connection_string_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_connect_func>>
      _odbc_connect_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_connect_with_timeout_func>>?
      _odbc_connect_with_timeout_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_disconnect_func>>
      _odbc_disconnect_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_get_error_func>>
      _odbc_get_error_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_get_structured_error_func>>
      _odbc_get_structured_error_ptr;

  ffi.Pointer<
          ffi.NativeFunction<odbc_get_structured_error_for_connection_func>>?
      _odbc_get_structured_error_for_connection_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_detect_driver_func>>
      _odbc_detect_driver_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_audit_enable_func>>?
      _odbc_audit_enable_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_audit_get_events_func>>?
      _odbc_audit_get_events_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_audit_clear_func>>? _odbc_audit_clear_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_audit_get_status_func>>?
      _odbc_audit_get_status_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_get_driver_capabilities_func>>?
      _odbc_get_driver_capabilities_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_get_connection_dbms_info_func>>?
      _odbc_get_connection_dbms_info_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_build_upsert_sql_func>>?
      _odbc_build_upsert_sql_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_append_returning_sql_func>>?
      _odbc_append_returning_sql_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_get_session_init_sql_func>>?
      _odbc_get_session_init_sql_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_metadata_cache_enable_func>>?
      _odbc_metadata_cache_enable_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_metadata_cache_stats_func>>?
      _odbc_metadata_cache_stats_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_metadata_cache_clear_func>>?
      _odbc_metadata_cache_clear_ptr;

  bool get supportsAuditApi =>
      _odbc_audit_enable_ptr != null &&
      _odbc_audit_get_events_ptr != null &&
      _odbc_audit_clear_ptr != null &&
      _odbc_audit_get_status_ptr != null;

  bool get supportsDriverCapabilitiesApi =>
      _odbc_get_driver_capabilities_ptr != null;

  /// True when the loaded native library exposes the v2.1 live DBMS
  /// introspection FFI (`odbc_get_connection_dbms_info`).

  bool get supportsConnectionDbmsInfoApi =>
      _odbc_get_connection_dbms_info_ptr != null;

  /// True when the v3.0 capability FFIs are available (UPSERT / RETURNING /
  /// session init builders).

  bool get supportsCapabilitiesApi =>
      _odbc_build_upsert_sql_ptr != null &&
      _odbc_append_returning_sql_ptr != null &&
      _odbc_get_session_init_sql_ptr != null;

  bool get supportsMetadataCacheApi =>
      _odbc_metadata_cache_enable_ptr != null &&
      _odbc_metadata_cache_stats_ptr != null &&
      _odbc_metadata_cache_clear_ptr != null;

  bool get supportsStructuredErrorForConnection =>
      _odbc_get_structured_error_for_connection_ptr != null;

  int odbc_init() => _odbc_init_ptr.asFunction<int Function()>()();

  int odbc_set_log_level(int level) =>
      _odbc_set_log_level_ptr.asFunction<int Function(int)>()(level);

  int odbc_get_version(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_get_version_ptr.asFunction<
          int Function(
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(buffer, bufferLen, outWritten);

  int odbc_validate_connection_string(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> errorBuffer,
    int errorBufferLen,
  ) =>
      _odbc_validate_connection_string_ptr.asFunction<
          int Function(
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
          )>()(
        connStr,
        errorBuffer,
        errorBufferLen,
      );

  int odbc_connect(ffi.Pointer<Utf8> connStr) =>
      _odbc_connect_ptr.asFunction<int Function(ffi.Pointer<Utf8>)>()(connStr);

  int odbc_connect_with_timeout(ffi.Pointer<Utf8> connStr, int timeoutMs) {
    final ptr = _odbc_connect_with_timeout_ptr;
    if (ptr == null) {
      return _odbc_connect_ptr
          .asFunction<int Function(ffi.Pointer<Utf8>)>()(connStr);
    }
    return ptr.asFunction<int Function(ffi.Pointer<Utf8>, int)>()(
      connStr,
      timeoutMs,
    );
  }

  int odbc_disconnect(int connId) =>
      _odbc_disconnect_ptr.asFunction<int Function(int)>()(connId);

  int odbc_get_error(ffi.Pointer<ffi.Int8> buffer, int bufferLen) =>
      _odbc_get_error_ptr
          .asFunction<int Function(ffi.Pointer<ffi.Int8>, int)>()(
        buffer,
        bufferLen,
      );

  int odbc_get_structured_error(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_get_structured_error_ptr.asFunction<
          int Function(
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(buffer, bufferLen, outWritten);

  int? odbc_get_structured_error_for_connection(
    int connId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_get_structured_error_for_connection_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(connId, buffer, bufferLen, outWritten);
  }

  int odbc_detect_driver(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Int8> outBuf,
    int bufferLen,
  ) =>
      _odbc_detect_driver_ptr.asFunction<
          int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Int8>, int)>()(
        connStr,
        outBuf,
        bufferLen,
      );

  int odbc_get_driver_capabilities(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_get_driver_capabilities_ptr;
    if (ptr == null) return -1;
    return ptr.asFunction<
        int Function(
          ffi.Pointer<Utf8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(connStr, buffer, bufferLen, outWritten);
  }

  int odbc_get_connection_dbms_info(
    int connId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_get_connection_dbms_info_ptr;
    if (ptr == null) return -1;
    return ptr.asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(connId, buffer, bufferLen, outWritten);
  }

  int odbc_build_upsert_sql(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<Utf8> payloadJson,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_build_upsert_sql_ptr;
    if (ptr == null) return -1;
    return ptr.asFunction<
        int Function(
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(connStr, table, payloadJson, outBuf, bufLen, outWritten);
  }

  int odbc_append_returning_sql(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<Utf8> sql,
    int verb,
    ffi.Pointer<Utf8> columnsCsv,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_append_returning_sql_ptr;
    if (ptr == null) return -1;
    return ptr.asFunction<
        int Function(
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          int,
          ffi.Pointer<Utf8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(connStr, sql, verb, columnsCsv, outBuf, bufLen, outWritten);
  }

  int odbc_get_session_init_sql(
    ffi.Pointer<Utf8> connStr,
    ffi.Pointer<Utf8>? optionsJson,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_get_session_init_sql_ptr;
    if (ptr == null) return -1;
    final optsPtr = optionsJson ?? ffi.Pointer<Utf8>.fromAddress(0);
    return ptr.asFunction<
        int Function(
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(connStr, optsPtr, outBuf, bufLen, outWritten);
  }

  int odbc_audit_enable(int enabled) {
    final ptr = _odbc_audit_enable_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<int Function(int)>()(enabled);
  }

  int odbc_audit_get_events(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    int limit,
  ) {
    final ptr = _odbc_audit_get_events_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
          int,
        )>()(
      buffer,
      bufferLen,
      outWritten,
      limit,
    );
  }

  int odbc_audit_clear() {
    final ptr = _odbc_audit_clear_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<int Function()>()();
  }

  int odbc_audit_get_status(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_audit_get_status_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(
      buffer,
      bufferLen,
      outWritten,
    );
  }

  int odbc_metadata_cache_enable(int maxEntries, int ttlSeconds) {
    final ptr = _odbc_metadata_cache_enable_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<int Function(int, int)>()(maxEntries, ttlSeconds);
  }

  int odbc_metadata_cache_stats(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_metadata_cache_stats_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(
      buffer,
      bufferLen,
      outWritten,
    );
  }

  int odbc_metadata_cache_clear() {
    final ptr = _odbc_metadata_cache_clear_ptr;
    if (ptr == null) {
      return -1;
    }
    return ptr.asFunction<int Function()>()();
  }
}
