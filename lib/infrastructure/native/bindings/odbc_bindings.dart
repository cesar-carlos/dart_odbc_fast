// FFI bindings must match native C/Rust symbol names exactly.
// ignore_for_file: non_constant_identifier_names, camel_case_types,
// lines_longer_than_80_chars

import 'dart:ffi' as ffi;

class OdbcBindings {
  OdbcBindings(this._dylib) {
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
    _odbc_exec_query_ptr = _dylib.lookup('odbc_exec_query');
    try {
      _odbc_execute_async_ptr = _dylib.lookup('odbc_execute_async');
      _odbc_async_poll_ptr = _dylib.lookup('odbc_async_poll');
      _odbc_async_get_result_ptr = _dylib.lookup('odbc_async_get_result');
      _odbc_async_cancel_ptr = _dylib.lookup('odbc_async_cancel');
      _odbc_async_free_ptr = _dylib.lookup('odbc_async_free');
    } on Object catch (_) {
      _odbc_execute_async_ptr = null;
      _odbc_async_poll_ptr = null;
      _odbc_async_get_result_ptr = null;
      _odbc_async_cancel_ptr = null;
      _odbc_async_free_ptr = null;
    }
    _odbc_stream_start_ptr = _dylib.lookup('odbc_stream_start');
    try {
      _odbc_stream_start_async_ptr = _dylib.lookup('odbc_stream_start_async');
      _odbc_stream_multi_start_batched_ptr =
          _dylib.lookup('odbc_stream_multi_start_batched');
      _odbc_stream_multi_start_async_ptr =
          _dylib.lookup('odbc_stream_multi_start_async');
      _odbc_stream_poll_async_ptr = _dylib.lookup('odbc_stream_poll_async');
    } on Object catch (_) {
      _odbc_stream_start_async_ptr = null;
      _odbc_stream_multi_start_batched_ptr = null;
      _odbc_stream_multi_start_async_ptr = null;
      _odbc_stream_poll_async_ptr = null;
    }
    _odbc_stream_fetch_ptr = _dylib.lookup('odbc_stream_fetch');
    _odbc_stream_cancel_ptr = _dylib.lookup('odbc_stream_cancel');
    _odbc_stream_close_ptr = _dylib.lookup('odbc_stream_close');
    _odbc_transaction_begin_ptr = _dylib.lookup('odbc_transaction_begin');
    _odbc_transaction_commit_ptr = _dylib.lookup('odbc_transaction_commit');
    _odbc_transaction_rollback_ptr = _dylib.lookup('odbc_transaction_rollback');
    _odbc_savepoint_create_ptr = _dylib.lookup('odbc_savepoint_create');
    _odbc_savepoint_rollback_ptr = _dylib.lookup('odbc_savepoint_rollback');
    _odbc_savepoint_release_ptr = _dylib.lookup('odbc_savepoint_release');
    _odbc_get_metrics_ptr = _dylib.lookup('odbc_get_metrics');
    _odbc_get_cache_metrics_ptr = _dylib.lookup('odbc_get_cache_metrics');
    _odbc_clear_statement_cache_ptr =
        _dylib.lookup('odbc_clear_statement_cache');
    _odbc_exec_query_params_ptr = _dylib.lookup('odbc_exec_query_params');
    _odbc_exec_query_multi_ptr = _dylib.lookup('odbc_exec_query_multi');
    try {
      _odbc_exec_query_multi_params_ptr =
          _dylib.lookup('odbc_exec_query_multi_params');
    } on Object catch (_) {
      _odbc_exec_query_multi_params_ptr = null;
    }
    _odbc_catalog_tables_ptr = _dylib.lookup('odbc_catalog_tables');
    _odbc_catalog_columns_ptr = _dylib.lookup('odbc_catalog_columns');
    _odbc_catalog_type_info_ptr = _dylib.lookup('odbc_catalog_type_info');
    _odbc_catalog_primary_keys_ptr = _dylib.lookup('odbc_catalog_primary_keys');
    _odbc_catalog_foreign_keys_ptr = _dylib.lookup('odbc_catalog_foreign_keys');
    _odbc_catalog_indexes_ptr = _dylib.lookup('odbc_catalog_indexes');
    _odbc_prepare_ptr = _dylib.lookup('odbc_prepare');
    _odbc_execute_ptr = _dylib.lookup('odbc_execute');
    _odbc_cancel_ptr = _dylib.lookup('odbc_cancel');
    _odbc_close_statement_ptr = _dylib.lookup('odbc_close_statement');
    try {
      _odbc_clear_all_statements_ptr =
          _dylib.lookup('odbc_clear_all_statements');
    } on Object catch (_) {
      _odbc_clear_all_statements_ptr = null;
    }
    _odbc_stream_start_batched_ptr = _dylib.lookup('odbc_stream_start_batched');
    _odbc_pool_create_ptr = _dylib.lookup('odbc_pool_create');
    try {
      _odbc_pool_create_with_options_ptr = _dylib.lookup(
        'odbc_pool_create_with_options',
      );
    } on Object catch (_) {
      _odbc_pool_create_with_options_ptr = null;
    }
    _odbc_pool_get_connection_ptr = _dylib.lookup('odbc_pool_get_connection');
    _odbc_pool_release_connection_ptr =
        _dylib.lookup('odbc_pool_release_connection');
    _odbc_pool_health_check_ptr = _dylib.lookup('odbc_pool_health_check');
    _odbc_pool_get_state_ptr = _dylib.lookup('odbc_pool_get_state');
    _odbc_pool_get_state_json_ptr = _dylib.lookup('odbc_pool_get_state_json');
    _odbc_pool_set_size_ptr = _dylib.lookup('odbc_pool_set_size');
    _odbc_pool_close_ptr = _dylib.lookup('odbc_pool_close');
    _odbc_bulk_insert_array_ptr = _dylib.lookup('odbc_bulk_insert_array');
    _odbc_bulk_insert_parallel_ptr = _dylib.lookup('odbc_bulk_insert_parallel');
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
  final ffi.DynamicLibrary _dylib;

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
  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_func>>
      _odbc_exec_query_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_execute_async_func>>?
      _odbc_execute_async_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_async_poll_func>>? _odbc_async_poll_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_async_get_result_func>>?
      _odbc_async_get_result_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_async_cancel_func>>?
      _odbc_async_cancel_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_async_free_func>>? _odbc_async_free_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_start_func>>
      _odbc_stream_start_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_stream_start_async_func>>?
      _odbc_stream_start_async_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_stream_multi_start_batched_func>>?
      _odbc_stream_multi_start_batched_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_stream_multi_start_async_func>>?
      _odbc_stream_multi_start_async_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_stream_poll_async_func>>?
      _odbc_stream_poll_async_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_fetch_func>>
      _odbc_stream_fetch_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_cancel_func>>
      _odbc_stream_cancel_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_close_func>>
      _odbc_stream_close_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_transaction_begin_func>>
      _odbc_transaction_begin_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_transaction_commit_func>>
      _odbc_transaction_commit_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_transaction_rollback_func>>
      _odbc_transaction_rollback_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_savepoint_create_func>>
      _odbc_savepoint_create_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_savepoint_rollback_func>>
      _odbc_savepoint_rollback_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_savepoint_release_func>>
      _odbc_savepoint_release_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_get_metrics_func>>
      _odbc_get_metrics_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_get_cache_metrics_func>>
      _odbc_get_cache_metrics_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_clear_statement_cache_func>>
      _odbc_clear_statement_cache_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_params_func>>
      _odbc_exec_query_params_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_multi_func>>
      _odbc_exec_query_multi_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_exec_query_multi_params_func>>?
      _odbc_exec_query_multi_params_ptr;

  /// True when the loaded native library exports
  /// `odbc_exec_query_multi_params` (added in v3.2.0). Used by
  /// `OdbcNative.execQueryMultiParams` to fall back gracefully on older
  /// binaries.
  bool get supportsExecQueryMultiParams =>
      _odbc_exec_query_multi_params_ptr != null;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_tables_func>>
      _odbc_catalog_tables_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_columns_func>>
      _odbc_catalog_columns_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_type_info_func>>
      _odbc_catalog_type_info_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_primary_keys_func>>
      _odbc_catalog_primary_keys_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_foreign_keys_func>>
      _odbc_catalog_foreign_keys_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_indexes_func>>
      _odbc_catalog_indexes_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_prepare_func>>
      _odbc_prepare_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_execute_func>>
      _odbc_execute_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_cancel_func>> _odbc_cancel_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_close_statement_func>>
      _odbc_close_statement_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_clear_all_statements_func>>?
      _odbc_clear_all_statements_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_start_batched_func>>
      _odbc_stream_start_batched_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_create_func>>
      _odbc_pool_create_ptr;
  ffi.Pointer<ffi.NativeFunction<odbc_pool_create_with_options_func>>?
      _odbc_pool_create_with_options_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_connection_func>>
      _odbc_pool_get_connection_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_release_connection_func>>
      _odbc_pool_release_connection_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_health_check_func>>
      _odbc_pool_health_check_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_state_func>>
      _odbc_pool_get_state_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_state_json_func>>
      _odbc_pool_get_state_json_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_set_size_func>>
      _odbc_pool_set_size_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_close_func>>
      _odbc_pool_close_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_bulk_insert_array_func>>
      _odbc_bulk_insert_array_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_bulk_insert_parallel_func>>
      _odbc_bulk_insert_parallel_ptr;
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

  bool get supportsAsyncExecuteApi =>
      _odbc_execute_async_ptr != null &&
      _odbc_async_poll_ptr != null &&
      _odbc_async_get_result_ptr != null &&
      _odbc_async_cancel_ptr != null &&
      _odbc_async_free_ptr != null;

  bool get supportsAsyncStreamApi =>
      _odbc_stream_start_async_ptr != null &&
      _odbc_stream_poll_async_ptr != null;

  /// True when the loaded native library exports
  /// `odbc_stream_multi_start_batched` (added in v3.3.0). Used by
  /// `OdbcNative.streamMultiStartBatched` to refuse silently on older
  /// binaries.
  bool get supportsMultiResultStream =>
      _odbc_stream_multi_start_batched_ptr != null;

  /// True when both multi-result streaming start FFIs and the existing
  /// async-poll FFI are available.
  bool get supportsAsyncMultiResultStream =>
      _odbc_stream_multi_start_async_ptr != null &&
      _odbc_stream_poll_async_ptr != null;

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

  int odbc_exec_query(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_exec_query_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, sql, outBuf, bufLen, outWritten);

  int? odbc_execute_async(int connId, ffi.Pointer<Utf8> sql) {
    final ptr = _odbc_execute_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>)>()(connId, sql);
  }

  int? odbc_async_poll(int requestId, ffi.Pointer<ffi.Int32> outStatus) {
    final ptr = _odbc_async_poll_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>()(
      requestId,
      outStatus,
    );
  }

  int? odbc_async_get_result(
    int requestId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_async_get_result_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(requestId, outBuf, bufLen, outWritten);
  }

  int? odbc_async_cancel(int requestId) {
    final ptr = _odbc_async_cancel_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int)>()(requestId);
  }

  int? odbc_async_free(int requestId) {
    final ptr = _odbc_async_free_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int)>()(requestId);
  }

  int odbc_stream_start(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) =>
      _odbc_stream_start_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
        connId,
        sql,
        chunkSize,
      );

  int? odbc_stream_start_async(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  ) {
    final ptr = _odbc_stream_start_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int, int)>()(
      connId,
      sql,
      fetchSize,
      chunkSize,
    );
  }

  /// Starts a streaming multi-result batch in batched mode.
  /// Returns `null` if the native library predates v3.3.0.
  int? odbc_stream_multi_start_batched(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) {
    final ptr = _odbc_stream_multi_start_batched_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
      connId,
      sql,
      chunkSize,
    );
  }

  /// Starts a streaming multi-result batch in async mode (poll + fetch).
  /// Returns `null` if the native library predates v3.3.0.
  int? odbc_stream_multi_start_async(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) {
    final ptr = _odbc_stream_multi_start_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
      connId,
      sql,
      chunkSize,
    );
  }

  int? odbc_stream_poll_async(int streamId, ffi.Pointer<ffi.Int32> outStatus) {
    final ptr = _odbc_stream_poll_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>()(
      streamId,
      outStatus,
    );
  }

  int odbc_stream_fetch(
    int streamId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    ffi.Pointer<ffi.Uint8> hasMore,
  ) =>
      _odbc_stream_fetch_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
          )>()(streamId, outBuf, bufLen, outWritten, hasMore);

  int odbc_stream_cancel(int streamId) =>
      _odbc_stream_cancel_ptr.asFunction<int Function(int)>()(streamId);

  int odbc_stream_close(int streamId) =>
      _odbc_stream_close_ptr.asFunction<int Function(int)>()(streamId);

  int odbc_transaction_begin(
    int connId,
    int isolationLevel, [
    int savepointDialect = 0,
  ]) =>
      _odbc_transaction_begin_ptr.asFunction<int Function(int, int, int)>()(
        connId,
        isolationLevel,
        savepointDialect,
      );

  int odbc_transaction_commit(int txnId) =>
      _odbc_transaction_commit_ptr.asFunction<int Function(int)>()(txnId);

  int odbc_transaction_rollback(int txnId) =>
      _odbc_transaction_rollback_ptr.asFunction<int Function(int)>()(txnId);

  int odbc_savepoint_create(int txnId, ffi.Pointer<Utf8> name) =>
      _odbc_savepoint_create_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>)>()(txnId, name);

  int odbc_savepoint_rollback(int txnId, ffi.Pointer<Utf8> name) =>
      _odbc_savepoint_rollback_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>)>()(txnId, name);

  int odbc_savepoint_release(int txnId, ffi.Pointer<Utf8> name) =>
      _odbc_savepoint_release_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>)>()(txnId, name);

  int odbc_get_metrics(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_get_metrics_ptr.asFunction<
          int Function(
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(buffer, bufferLen, outWritten);

  int odbc_get_cache_metrics(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_get_cache_metrics_ptr.asFunction<
          int Function(
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(buffer, bufferLen, outWritten);

  int odbc_clear_statement_cache() =>
      _odbc_clear_statement_cache_ptr.asFunction<int Function()>()();

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

  int odbc_exec_query_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_exec_query_params_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>?,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        connId,
        sql,
        paramsBuffer,
        paramsLen,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_exec_query_multi(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_exec_query_multi_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, sql, outBuffer, bufferLen, outWritten);

  int odbc_exec_query_multi_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final ptr = _odbc_exec_query_multi_params_ptr;
    if (ptr == null) {
      throw StateError(
        'odbc_exec_query_multi_params is not exported by the loaded '
        'odbc_engine library. Rebuild against odbc_engine >= 3.2.0.',
      );
    }
    final fn = ptr.asFunction<
        int Function(
          int,
          ffi.Pointer<Utf8>,
          ffi.Pointer<ffi.Uint8>?,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>();
    return fn(
      connId,
      sql,
      paramsBuffer,
      paramsLen,
      outBuffer,
      bufferLen,
      outWritten,
    );
  }

  int odbc_catalog_tables(
    int connId,
    ffi.Pointer<Utf8> catalog,
    ffi.Pointer<Utf8> schema,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_tables_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, catalog, schema, outBuffer, bufferLen, outWritten);

  int odbc_catalog_columns(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_columns_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, table, outBuffer, bufferLen, outWritten);

  int odbc_catalog_type_info(
    int connId,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_type_info_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, outBuffer, bufferLen, outWritten);

  int odbc_catalog_primary_keys(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_primary_keys_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, table, outBuffer, bufferLen, outWritten);

  int odbc_catalog_foreign_keys(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_foreign_keys_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, table, outBuffer, bufferLen, outWritten);

  int odbc_catalog_indexes(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_indexes_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(connId, table, outBuffer, bufferLen, outWritten);

  int odbc_prepare(int connId, ffi.Pointer<Utf8> sql, int timeoutMs) =>
      _odbc_prepare_ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
        connId,
        sql,
        timeoutMs,
      );

  int odbc_execute(
    int stmtId,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    int timeoutOverrideMs,
    int fetchSize,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_execute_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint8>?,
            int,
            int,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        stmtId,
        paramsBuffer,
        paramsLen,
        timeoutOverrideMs,
        fetchSize,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_cancel(int stmtId) =>
      _odbc_cancel_ptr.asFunction<int Function(int)>()(stmtId);

  int odbc_close_statement(int stmtId) =>
      _odbc_close_statement_ptr.asFunction<int Function(int)>()(stmtId);

  int odbc_clear_all_statements() {
    final ptr = _odbc_clear_all_statements_ptr;
    if (ptr == null) {
      // Backward compatibility with older native libs.
      return 0;
    }
    return ptr.asFunction<int Function()>()();
  }

  int odbc_stream_start_batched(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  ) =>
      _odbc_stream_start_batched_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>, int, int)>()(
        connId,
        sql,
        fetchSize,
        chunkSize,
      );

  int odbc_pool_create(ffi.Pointer<Utf8> connStr, int maxSize) =>
      _odbc_pool_create_ptr.asFunction<int Function(ffi.Pointer<Utf8>, int)>()(
        connStr,
        maxSize,
      );

  bool get supportsPoolCreateWithOptions =>
      _odbc_pool_create_with_options_ptr != null;

  int odbc_pool_create_with_options(
    ffi.Pointer<Utf8> connStr,
    int maxSize,
    ffi.Pointer<Utf8>? optionsJson,
  ) {
    final ptr = _odbc_pool_create_with_options_ptr;
    if (ptr == null) return 0;
    final optsPtr = optionsJson ?? ffi.Pointer<Utf8>.fromAddress(0);
    final fn = ptr
        .asFunction<int Function(ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>)>();
    return fn(connStr, maxSize, optsPtr);
  }

  int odbc_pool_get_connection(int poolId) =>
      _odbc_pool_get_connection_ptr.asFunction<int Function(int)>()(poolId);

  int odbc_pool_release_connection(int connectionId) =>
      _odbc_pool_release_connection_ptr
          .asFunction<int Function(int)>()(connectionId);

  int odbc_pool_health_check(int poolId) =>
      _odbc_pool_health_check_ptr.asFunction<int Function(int)>()(poolId);

  int odbc_pool_get_state(
    int poolId,
    ffi.Pointer<ffi.Uint32> outSize,
    ffi.Pointer<ffi.Uint32> outIdle,
  ) =>
      _odbc_pool_get_state_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        poolId,
        outSize,
        outIdle,
      );

  int odbc_pool_get_state_json(
    int poolId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_pool_get_state_json_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        poolId,
        buffer,
        bufferLen,
        outWritten,
      );

  int odbc_pool_set_size(int poolId, int newMaxSize) => _odbc_pool_set_size_ptr
      .asFunction<int Function(int, int)>()(poolId, newMaxSize);

  int odbc_pool_close(int poolId) =>
      _odbc_pool_close_ptr.asFunction<int Function(int)>()(poolId);

  int odbc_bulk_insert_array(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Pointer<Utf8>> columns,
    int columnCount,
    ffi.Pointer<ffi.Uint8> dataBuffer,
    int bufferLen,
    int rowCount,
    ffi.Pointer<ffi.Uint32> rowsInserted,
  ) =>
      _odbc_bulk_insert_array_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Pointer<Utf8>>,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        connId,
        table,
        columns,
        columnCount,
        dataBuffer,
        bufferLen,
        rowCount,
        rowsInserted,
      );

  int odbc_bulk_insert_parallel(
    int poolId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Pointer<Utf8>> columns,
    int columnCount,
    ffi.Pointer<ffi.Uint8> dataBuffer,
    int bufferLen,
    int parallelism,
    ffi.Pointer<ffi.Uint32> rowsInserted,
  ) =>
      _odbc_bulk_insert_parallel_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Pointer<Utf8>>,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        poolId,
        table,
        columns,
        columnCount,
        dataBuffer,
        bufferLen,
        parallelism,
        rowsInserted,
      );

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

typedef odbc_init_func = ffi.Int32 Function();
typedef odbc_set_log_level_func = ffi.Int32 Function(ffi.Int32);
typedef odbc_get_version_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_validate_connection_string_func = ffi.Int32 Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
);
typedef odbc_connect_func = ffi.Uint32 Function(ffi.Pointer<Utf8>);
typedef odbc_connect_with_timeout_func = ffi.Uint32 Function(
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_disconnect_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_get_error_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Int8>,
  ffi.Uint32,
);
typedef odbc_get_structured_error_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_get_structured_error_for_connection_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_exec_query_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_execute_async_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
);
typedef odbc_async_poll_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Int32>,
);
typedef odbc_async_get_result_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_async_cancel_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_async_free_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_stream_start_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_stream_multi_start_batched_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_stream_multi_start_async_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_stream_start_async_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
  ffi.Uint32,
);
typedef odbc_stream_poll_async_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Int32>,
);
typedef odbc_stream_fetch_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
  ffi.Pointer<ffi.Uint8>,
);
typedef odbc_stream_cancel_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_stream_close_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_transaction_begin_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
);
typedef odbc_transaction_commit_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_transaction_rollback_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_savepoint_create_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
);
typedef odbc_savepoint_rollback_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
);
typedef odbc_savepoint_release_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
);
typedef odbc_get_metrics_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_get_cache_metrics_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_clear_statement_cache_func = ffi.Int32 Function();
typedef odbc_detect_driver_func = ffi.Int32 Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Int8>,
  ffi.Uint32,
);
typedef odbc_exec_query_params_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>?,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_exec_query_multi_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_exec_query_multi_params_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>?,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_catalog_tables_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_catalog_columns_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_catalog_type_info_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_catalog_primary_keys_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_catalog_foreign_keys_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_catalog_indexes_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_prepare_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_execute_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>?,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_cancel_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_close_statement_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_clear_all_statements_func = ffi.Int32 Function();
typedef odbc_stream_start_batched_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
  ffi.Uint32,
);
typedef odbc_pool_create_func = ffi.Uint32 Function(
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_pool_create_with_options_func = ffi.Uint32 Function(
  ffi.Pointer<Utf8>,
  ffi.Uint32,
  ffi.Pointer<Utf8>,
);
typedef odbc_pool_get_connection_func = ffi.Uint32 Function(ffi.Uint32);
typedef odbc_pool_release_connection_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_pool_health_check_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_pool_get_state_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_pool_get_state_json_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_pool_set_size_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Uint32,
);
typedef odbc_pool_close_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_bulk_insert_array_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Pointer<Utf8>>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_bulk_insert_parallel_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Pointer<Utf8>>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_audit_enable_func = ffi.Int32 Function(ffi.Int32);
typedef odbc_audit_get_events_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
  ffi.Uint32,
);
typedef odbc_audit_clear_func = ffi.Int32 Function();
typedef odbc_audit_get_status_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_get_driver_capabilities_func = ffi.Int32 Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_get_connection_dbms_info_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_build_upsert_sql_func = ffi.Int32 Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_append_returning_sql_func = ffi.Int32 Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Int32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_get_session_init_sql_func = ffi.Int32 Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_metadata_cache_enable_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Uint32,
);
typedef odbc_metadata_cache_stats_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_metadata_cache_clear_func = ffi.Int32 Function();

final class Utf8 extends ffi.Opaque {}
