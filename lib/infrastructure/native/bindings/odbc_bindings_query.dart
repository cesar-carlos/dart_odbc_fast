// FFI bindings mirror exported C symbol names; snake_case identifiers are
// intentional for 1:1 native API mapping.
// ignore_for_file: non_constant_identifier_names

part of 'odbc_bindings.dart';

mixin _OdbcBindingsQuery on _OdbcBindingsState {
  void _bindQuery() {
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
    try {
      _odbc_execute_async_params_ptr =
          _dylib.lookup('odbc_execute_async_params');
    } on Object catch (_) {
      _odbc_execute_async_params_ptr = null;
    }
    try {
      _odbc_execute_async_params_options_ptr =
          _dylib.lookup('odbc_execute_async_params_options');
    } on Object catch (_) {
      _odbc_execute_async_params_options_ptr = null;
    }
    _odbc_get_metrics_ptr = _dylib.lookup('odbc_get_metrics');
    _odbc_get_cache_metrics_ptr = _dylib.lookup('odbc_get_cache_metrics');
    _odbc_clear_statement_cache_ptr =
        _dylib.lookup('odbc_clear_statement_cache');
    _odbc_exec_query_params_ptr = _dylib.lookup('odbc_exec_query_params');
    try {
      _odbc_exec_query_params_options_ptr =
          _dylib.lookup('odbc_exec_query_params_options');
    } on Object catch (_) {
      _odbc_exec_query_params_options_ptr = null;
    }
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
    _odbc_bulk_insert_array_ptr = _dylib.lookup('odbc_bulk_insert_array');
    _odbc_bulk_insert_parallel_ptr = _dylib.lookup('odbc_bulk_insert_parallel');
  }

  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_func>>
      _odbc_exec_query_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_exec_query_fn = _odbc_exec_query_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  ffi.Pointer<ffi.NativeFunction<odbc_execute_async_func>>?
      _odbc_execute_async_ptr;
  late final int Function(int, ffi.Pointer<Utf8>)? _odbc_execute_async_fn =
      _odbc_execute_async_ptr
          ?.asFunction<int Function(int, ffi.Pointer<Utf8>)>();

  ffi.Pointer<ffi.NativeFunction<odbc_execute_async_params_func>>?
      _odbc_execute_async_params_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
  )? _odbc_execute_async_params_fn = _odbc_execute_async_params_ptr?.asFunction<
      int Function(int, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int)>();

  ffi.Pointer<ffi.NativeFunction<odbc_execute_async_params_options_func>>?
      _odbc_execute_async_params_options_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
  )? _odbc_execute_async_params_options_fn =
      _odbc_execute_async_params_options_ptr?.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>,
            int,
            int,
          )>();

  ffi.Pointer<ffi.NativeFunction<odbc_async_poll_func>>? _odbc_async_poll_ptr;
  late final int Function(int, ffi.Pointer<ffi.Int32>)? _odbc_async_poll_fn =
      _odbc_async_poll_ptr
          ?.asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>();

  ffi.Pointer<ffi.NativeFunction<odbc_async_get_result_func>>?
      _odbc_async_get_result_ptr;
  late final int Function(
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  )? _odbc_async_get_result_fn = _odbc_async_get_result_ptr?.asFunction<
      int Function(
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  ffi.Pointer<ffi.NativeFunction<odbc_async_cancel_func>>?
      _odbc_async_cancel_ptr;
  late final int Function(int)? _odbc_async_cancel_fn =
      _odbc_async_cancel_ptr?.asFunction<int Function(int)>();

  ffi.Pointer<ffi.NativeFunction<odbc_async_free_func>>? _odbc_async_free_ptr;
  late final int Function(int)? _odbc_async_free_fn =
      _odbc_async_free_ptr?.asFunction<int Function(int)>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_get_metrics_func>>
      _odbc_get_metrics_ptr;
  late final int Function(
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_get_metrics_fn = _odbc_get_metrics_ptr.asFunction<
      int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>)>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_get_cache_metrics_func>>
      _odbc_get_cache_metrics_ptr;
  late final int Function(
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_get_cache_metrics_fn = _odbc_get_cache_metrics_ptr.asFunction<
      int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>)>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_clear_statement_cache_func>>
      _odbc_clear_statement_cache_ptr;
  late final int Function() _odbc_clear_statement_cache_fn =
      _odbc_clear_statement_cache_ptr.asFunction<int Function()>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_params_func>>
      _odbc_exec_query_params_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>?,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_exec_query_params_fn = _odbc_exec_query_params_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>?,
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  ffi.Pointer<ffi.NativeFunction<odbc_exec_query_params_options_func>>?
      _odbc_exec_query_params_options_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>?,
    int,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  )? _odbc_exec_query_params_options_fn =
      _odbc_exec_query_params_options_ptr?.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>?,
            int,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_multi_func>>
      _odbc_exec_query_multi_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_exec_query_multi_fn = _odbc_exec_query_multi_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  ffi.Pointer<ffi.NativeFunction<odbc_exec_query_multi_params_func>>?
      _odbc_exec_query_multi_params_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>?,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  )? _odbc_exec_query_multi_params_fn =
      _odbc_exec_query_multi_params_ptr?.asFunction<
          int Function(
            int,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Uint8>?,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>();

  /// True when the loaded native library exports
  /// `odbc_exec_query_multi_params` (added in v3.2.0). Used by
  /// `OdbcNative.execQueryMultiParams` to fall back gracefully on older
  /// binaries.

  bool get supportsExecQueryMultiParams =>
      _odbc_exec_query_multi_params_ptr != null;

  bool get supportsExecQueryParamsOptions =>
      _odbc_exec_query_params_options_ptr != null;

  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_tables_func>>
      _odbc_catalog_tables_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_catalog_tables_fn = _odbc_catalog_tables_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_columns_func>>
      _odbc_catalog_columns_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_catalog_columns_fn = _odbc_catalog_columns_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_type_info_func>>
      _odbc_catalog_type_info_ptr;
  late final int Function(
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_catalog_type_info_fn = _odbc_catalog_type_info_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_primary_keys_func>>
      _odbc_catalog_primary_keys_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_catalog_primary_keys_fn = _odbc_catalog_primary_keys_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_foreign_keys_func>>
      _odbc_catalog_foreign_keys_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_catalog_foreign_keys_fn = _odbc_catalog_foreign_keys_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_indexes_func>>
      _odbc_catalog_indexes_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_catalog_indexes_fn = _odbc_catalog_indexes_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_prepare_func>>
      _odbc_prepare_ptr;
  late final int Function(int, ffi.Pointer<Utf8>, int) _odbc_prepare_fn =
      _odbc_prepare_ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int)>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_execute_func>>
      _odbc_execute_ptr;
  late final int Function(
    int,
    ffi.Pointer<ffi.Uint8>?,
    int,
    int,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_execute_fn = _odbc_execute_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<ffi.Uint8>?,
        int,
        int,
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_cancel_func>> _odbc_cancel_ptr;
  late final int Function(int) _odbc_cancel_fn =
      _odbc_cancel_ptr.asFunction<int Function(int)>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_close_statement_func>>
      _odbc_close_statement_ptr;
  late final int Function(int) _odbc_close_statement_fn =
      _odbc_close_statement_ptr.asFunction<int Function(int)>();

  ffi.Pointer<ffi.NativeFunction<odbc_clear_all_statements_func>>?
      _odbc_clear_all_statements_ptr;
  late final int Function()? _odbc_clear_all_statements_fn =
      _odbc_clear_all_statements_ptr?.asFunction<int Function()>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_bulk_insert_array_func>>
      _odbc_bulk_insert_array_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Pointer<Utf8>>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_bulk_insert_array_fn = _odbc_bulk_insert_array_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Pointer<Utf8>>,
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  late final ffi.Pointer<ffi.NativeFunction<odbc_bulk_insert_parallel_func>>
      _odbc_bulk_insert_parallel_ptr;
  late final int Function(
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Pointer<Utf8>>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    ffi.Pointer<ffi.Uint32>,
  ) _odbc_bulk_insert_parallel_fn = _odbc_bulk_insert_parallel_ptr.asFunction<
      int Function(
        int,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.Pointer<Utf8>>,
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        int,
        ffi.Pointer<ffi.Uint32>,
      )>();

  bool get supportsAsyncExecuteApi =>
      _odbc_execute_async_ptr != null &&
      _odbc_async_poll_ptr != null &&
      _odbc_async_get_result_ptr != null &&
      _odbc_async_cancel_ptr != null &&
      _odbc_async_free_ptr != null;

  bool get supportsAsyncExecuteParamsApi =>
      supportsAsyncExecuteApi && _odbc_execute_async_params_ptr != null;

  /// True when [odbc_execute_async_params_options] is exported
  /// (async columnar).

  bool get supportsAsyncExecuteParamsOptionsApi =>
      supportsAsyncExecuteParamsApi &&
      _odbc_execute_async_params_options_ptr != null;

  int odbc_exec_query(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_exec_query_fn(connId, sql, outBuf, bufLen, outWritten);

  int? odbc_execute_async(int connId, ffi.Pointer<Utf8> sql) {
    final fn = _odbc_execute_async_fn;
    if (fn == null) return null;
    return fn(connId, sql);
  }

  int? odbc_execute_async_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> paramsBuffer,
    int paramsLen,
  ) {
    final fn = _odbc_execute_async_params_fn;
    if (fn == null) return null;
    return fn(connId, sql, paramsBuffer, paramsLen);
  }

  int? odbc_execute_async_params_options(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> paramsBuffer,
    int paramsLen,
    int resultEncoding,
  ) {
    final fn = _odbc_execute_async_params_options_fn;
    if (fn == null) return null;
    return fn(connId, sql, paramsBuffer, paramsLen, resultEncoding);
  }

  int? odbc_async_poll(int requestId, ffi.Pointer<ffi.Int32> outStatus) {
    final fn = _odbc_async_poll_fn;
    if (fn == null) return null;
    return fn(requestId, outStatus);
  }

  int? odbc_async_get_result(
    int requestId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final fn = _odbc_async_get_result_fn;
    if (fn == null) return null;
    return fn(requestId, outBuf, bufLen, outWritten);
  }

  int? odbc_async_cancel(int requestId) {
    final fn = _odbc_async_cancel_fn;
    if (fn == null) return null;
    return fn(requestId);
  }

  int? odbc_async_free(int requestId) {
    final fn = _odbc_async_free_fn;
    if (fn == null) return null;
    return fn(requestId);
  }

  int odbc_get_metrics(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_get_metrics_fn(buffer, bufferLen, outWritten);

  int odbc_get_cache_metrics(
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_get_cache_metrics_fn(buffer, bufferLen, outWritten);

  int odbc_clear_statement_cache() => _odbc_clear_statement_cache_fn();

  int odbc_exec_query_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_exec_query_params_fn(
        connId,
        sql,
        paramsBuffer,
        paramsLen,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_exec_query_params_options(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    int resultEncoding,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final fn = _odbc_exec_query_params_options_fn;
    if (fn == null) return -1;
    return fn(
      connId,
      sql,
      paramsBuffer,
      paramsLen,
      resultEncoding,
      outBuffer,
      bufferLen,
      outWritten,
    );
  }

  int odbc_exec_query_multi(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_exec_query_multi_fn(connId, sql, outBuffer, bufferLen, outWritten);

  int odbc_exec_query_multi_params(
    int connId,
    ffi.Pointer<Utf8> sql,
    ffi.Pointer<ffi.Uint8>? paramsBuffer,
    int paramsLen,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) {
    final fn = _odbc_exec_query_multi_params_fn;
    if (fn == null) {
      throw StateError(
        'odbc_exec_query_multi_params is not exported by the loaded '
        'odbc_engine library. Rebuild against odbc_engine >= 3.2.0.',
      );
    }
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
      _odbc_catalog_tables_fn(
        connId,
        catalog,
        schema,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_catalog_columns(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_columns_fn(connId, table, outBuffer, bufferLen, outWritten);

  int odbc_catalog_type_info(
    int connId,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_type_info_fn(connId, outBuffer, bufferLen, outWritten);

  int odbc_catalog_primary_keys(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_primary_keys_fn(
        connId,
        table,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_catalog_foreign_keys(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_foreign_keys_fn(
        connId,
        table,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_catalog_indexes(
    int connId,
    ffi.Pointer<Utf8> table,
    ffi.Pointer<ffi.Uint8> outBuffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_catalog_indexes_fn(connId, table, outBuffer, bufferLen, outWritten);

  int odbc_prepare(int connId, ffi.Pointer<Utf8> sql, int timeoutMs) =>
      _odbc_prepare_fn(connId, sql, timeoutMs);

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
      _odbc_execute_fn(
        stmtId,
        paramsBuffer,
        paramsLen,
        timeoutOverrideMs,
        fetchSize,
        outBuffer,
        bufferLen,
        outWritten,
      );

  int odbc_cancel(int stmtId) => _odbc_cancel_fn(stmtId);

  int odbc_close_statement(int stmtId) => _odbc_close_statement_fn(stmtId);

  int odbc_clear_all_statements() {
    final fn = _odbc_clear_all_statements_fn;
    if (fn == null) {
      // Backward compatibility with older native libs.
      return 0;
    }
    return fn();
  }

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
      _odbc_bulk_insert_array_fn(
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
      _odbc_bulk_insert_parallel_fn(
        poolId,
        table,
        columns,
        columnCount,
        dataBuffer,
        bufferLen,
        parallelism,
        rowsInserted,
      );
}
