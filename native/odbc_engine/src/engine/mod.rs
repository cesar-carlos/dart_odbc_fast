pub mod catalog;
pub mod cell_reader;
pub mod connection;
pub mod core;
pub mod dbms_info;
pub mod environment;
pub mod identifier;
pub mod query;
pub mod sqlserver_json;
pub mod statement;
pub mod streaming;
pub mod transaction;
pub mod xa_transaction;

// Sprint 4.3b — SQL Server XA via MSDTC (Windows-only, feature-gated).
// The module is conditionally compiled so non-Windows builds and
// builds without the `xa-dtc` feature are byte-identical to today.
#[cfg(all(target_os = "windows", feature = "xa-dtc"))]
pub mod xa_dtc;

// Sprint 4.3c — Oracle XA via OCI (cross-platform, feature-gated).
#[cfg(feature = "xa-oci")]
pub mod xa_oci;

pub use catalog::{
    get_type_info, list_columns, list_foreign_keys, list_indexes, list_primary_keys, list_tables,
};
pub use connection::OdbcConnection;
pub use core::*;
pub use dbms_info::DbmsInfo;
pub use environment::OdbcEnvironment;
pub use identifier::{
    quote_identifier, quote_identifier_default, quote_qualified_default, validate_identifier,
    IdentifierQuoting, MAX_IDENTIFIER_LEN,
};
pub use query::{
    execute_multi_result, execute_multi_result_with_params, execute_query_with_cached_connection,
    execute_query_with_connection, execute_query_with_param_buffer,
    execute_query_with_param_buffer_and_timeout, execute_query_with_params,
    execute_query_with_params_and_timeout, get_global_metrics,
};
pub use sqlserver_json::{
    coalesce_for_json_rows, is_for_json_result, SQLSERVER_FOR_JSON_COLUMN_NAME,
};
pub use statement::StatementHandle;
pub use streaming::{
    start_multi_async_stream, start_multi_batched_stream, AsyncStreamStatus, AsyncStreamingState,
    BatchedStreamingState, StreamState, StreamingExecutor, StreamingState,
    MULTI_STREAM_ITEM_TAG_RESULT_SET, MULTI_STREAM_ITEM_TAG_ROW_COUNT,
};
pub use transaction::{
    IsolationLevel, LockTimeout, Savepoint, SavepointDialect, Transaction, TransactionAccessMode,
    TransactionState,
};
pub use xa_transaction::{
    recover_prepared_xids, resume_prepared, PreparedXa, PreparingXa, XaState, XaTransaction, Xid,
};
// SharedHandleManager appears in public APIs (XaTransaction::start,
// recover_prepared_xids, etc.); re-export so tests / downstreams that
// need to hold one across calls don't have to reach into a private
// path.
pub use crate::handles::SharedHandleManager;
