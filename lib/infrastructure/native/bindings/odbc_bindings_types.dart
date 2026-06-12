// ignore_for_file: camel_case_types

part of 'odbc_bindings.dart';

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
typedef odbc_execute_async_params_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
);
typedef odbc_execute_async_params_options_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Uint32,
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
typedef odbc_transaction_begin_v2_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
);
typedef odbc_transaction_begin_v3_func = ffi.Uint32 Function(
  ffi.Uint32,
  ffi.Uint32,
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

// Sprint 4.3 — XA / 2PC.
typedef odbc_xa_start_func = ffi.Uint32 Function(
  ffi.Uint32, // conn_id
  ffi.Int32, // format_id
  ffi.Pointer<ffi.Uint8>, // gtrid_ptr
  ffi.Uint32, // gtrid_len
  ffi.Pointer<ffi.Uint8>, // bqual_ptr
  ffi.Uint32, // bqual_len
);
typedef odbc_xa_end_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_prepare_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_commit_prepared_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_rollback_prepared_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_commit_one_phase_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_rollback_active_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_recover_count_func = ffi.Int32 Function(ffi.Uint32);
typedef odbc_xa_recover_get_func = ffi.Int32 Function(
  ffi.Uint32, // index
  ffi.Pointer<ffi.Int32>, // out_format_id
  ffi.Pointer<ffi.Uint8>, // gtrid_buf
  ffi.Uint32, // gtrid_buf_len
  ffi.Pointer<ffi.Uint32>, // out_gtrid_len
  ffi.Pointer<ffi.Uint8>, // bqual_buf
  ffi.Uint32, // bqual_buf_len
  ffi.Pointer<ffi.Uint32>, // out_bqual_len
);
typedef odbc_xa_resume_prepared_func = ffi.Uint32 Function(
  ffi.Uint32, // conn_id
  ffi.Int32, // format_id
  ffi.Pointer<ffi.Uint8>, // gtrid_ptr
  ffi.Uint32, // gtrid_len
  ffi.Pointer<ffi.Uint8>, // bqual_ptr
  ffi.Uint32, // bqual_len
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
typedef odbc_exec_query_params_options_func = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Uint8>?,
  ffi.Uint32,
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
