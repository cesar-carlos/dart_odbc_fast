// FFI bindings must match native C/Rust symbol names exactly.
// ignore_for_file: non_constant_identifier_names, camel_case_types,
// lines_longer_than_80_chars

import 'dart:ffi' as ffi;

class OdbcBindings {
  OdbcBindings(this._dylib) {
    _odbc_init_ptr = _dylib.lookup('odbc_init');
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
    _odbc_exec_query_ptr = _dylib.lookup('odbc_exec_query');
    _odbc_stream_start_ptr = _dylib.lookup('odbc_stream_start');
    _odbc_stream_fetch_ptr = _dylib.lookup('odbc_stream_fetch');
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
    _odbc_catalog_tables_ptr = _dylib.lookup('odbc_catalog_tables');
    _odbc_catalog_columns_ptr = _dylib.lookup('odbc_catalog_columns');
    _odbc_catalog_type_info_ptr = _dylib.lookup('odbc_catalog_type_info');
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
    _odbc_pool_get_connection_ptr = _dylib.lookup('odbc_pool_get_connection');
    _odbc_pool_release_connection_ptr =
        _dylib.lookup('odbc_pool_release_connection');
    _odbc_pool_health_check_ptr = _dylib.lookup('odbc_pool_health_check');
    _odbc_pool_get_state_ptr = _dylib.lookup('odbc_pool_get_state');
    _odbc_pool_close_ptr = _dylib.lookup('odbc_pool_close');
    _odbc_bulk_insert_array_ptr = _dylib.lookup('odbc_bulk_insert_array');
    _odbc_bulk_insert_parallel_ptr = _dylib.lookup('odbc_bulk_insert_parallel');
    _odbc_detect_driver_ptr = _dylib.lookup('odbc_detect_driver');
  }
  final ffi.DynamicLibrary _dylib;

  late final ffi.Pointer<ffi.NativeFunction<odbc_init_func>> _odbc_init_ptr;
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
  late final ffi.Pointer<ffi.NativeFunction<odbc_exec_query_func>>
      _odbc_exec_query_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_start_func>>
      _odbc_stream_start_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_fetch_func>>
      _odbc_stream_fetch_ptr;
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
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_tables_func>>
      _odbc_catalog_tables_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_columns_func>>
      _odbc_catalog_columns_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_catalog_type_info_func>>
      _odbc_catalog_type_info_ptr;
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
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_connection_func>>
      _odbc_pool_get_connection_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_release_connection_func>>
      _odbc_pool_release_connection_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_health_check_func>>
      _odbc_pool_health_check_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_state_func>>
      _odbc_pool_get_state_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_close_func>>
      _odbc_pool_close_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_bulk_insert_array_func>>
      _odbc_bulk_insert_array_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_bulk_insert_parallel_func>>
      _odbc_bulk_insert_parallel_ptr;
  late final ffi.Pointer<ffi.NativeFunction<odbc_detect_driver_func>>
      _odbc_detect_driver_ptr;

  int odbc_init() => _odbc_init_ptr.asFunction<int Function()>()();

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

  int odbc_stream_close(int streamId) =>
      _odbc_stream_close_ptr.asFunction<int Function(int)>()(streamId);

  int odbc_transaction_begin(int connId, int isolationLevel) =>
      _odbc_transaction_begin_ptr.asFunction<int Function(int, int)>()(
        connId,
        isolationLevel,
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
}

typedef odbc_init_func = ffi.Int32 Function();
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
typedef odbc_exec_query_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
);
typedef odbc_stream_start_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef odbc_stream_fetch_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
  ffi.Pointer<ffi.Uint8>,
);
typedef odbc_stream_close_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_transaction_begin_func = ffi.Uint32 Function(
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
typedef odbc_pool_get_connection_func = ffi.Uint32 Function(ffi.Uint32);
typedef odbc_pool_release_connection_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_pool_health_check_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_pool_get_state_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint32>,
  ffi.Pointer<ffi.Uint32>,
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

final class Utf8 extends ffi.Opaque {}
