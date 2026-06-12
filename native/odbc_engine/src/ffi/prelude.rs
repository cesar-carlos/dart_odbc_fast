//! Shared imports for domain FFI submodules.
//!
//! Fourteen FFI consumers (`bulk`, `catalog`, `capabilities`, `pool`,
//! `statement`, `stream`, `xa`, `query/sync/*`, and test modules) import this
//! with `use super::prelude::*` (or `crate::ffi::prelude::*`). Each file uses a
//! different subset of ~40 re-exports and feature gates (`sqlserver-bcp`, …),
//! so per-submodule explicit imports are not mechanical without brittle churn.
//! The `unused_imports` allow below silences glob noise in those consumers.

#![allow(
    unused_imports,
    reason = "FFI prelude glob: per-submodule explicit imports are not mechanical across fourteen consumers and feature gates."
)]

#[cfg(not(feature = "sqlserver-bcp"))]
pub use crate::engine::ArrayBinding;
#[cfg(feature = "sqlserver-bcp")]
pub use crate::engine::BulkCopyExecutor;
pub use crate::engine::{
    execute_multi_result, execute_multi_result_with_params, execute_query_with_cached_connection,
    execute_query_with_cached_connection_params, execute_query_with_connection,
    execute_query_with_param_buffer, execute_query_with_param_buffer_and_timeout,
    execute_query_with_param_buffer_encoding, get_global_metrics, get_type_info, list_columns,
    list_foreign_keys, list_indexes, list_primary_keys, list_tables, recover_prepared_xids,
    resume_prepared, AsyncStreamStatus, AsyncStreamingState, BatchedStreamingState,
    DriverCapabilities, IsolationLevel, LockTimeout, MetadataCache, OdbcConnection,
    OdbcEnvironment, PreparedXa, PreparingXa, ResultEncoding, SavepointDialect,
    SharedHandleManager, StatementHandle, StreamCopyResult, StreamState, StreamingExecutor,
    Transaction, TransactionAccessMode, XaTransaction, Xid,
};
pub use crate::error::{OdbcError, Result, StructuredError};
pub use crate::pool::{ConnectionPool, SharedPooledConnection};
pub use crate::protocol::bound_param::ParamDirection;
pub use crate::protocol::{
    bound_param::ParamList, deserialize_param_buffer, parse_bulk_insert_payload, BulkInsertPayload,
    ParamValue,
};
#[cfg(feature = "sqlserver-bcp")]
pub use crate::protocol::{bulk_insert::is_null, BulkColumnData};
pub use crate::versioning::{abi_version::AbiVersion, api_version::ApiVersion};

pub use std::ffi::CStr;
pub use std::os::raw::{c_char, c_int, c_uint};
pub use std::sync::{Arc, Mutex};
pub use std::time::{Duration, Instant};
