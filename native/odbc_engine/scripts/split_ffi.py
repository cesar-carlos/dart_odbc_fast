#!/usr/bin/env python3
"""Split ffi/mod.rs into cohesive submodules (one-time refactor helper)."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "ffi" / "mod.rs"
OUT = ROOT / "src" / "ffi"

# 1-based inclusive line ranges -> module name (helpers stay with their domain).
RANGES: list[tuple[str, int, int]] = [
    ("global", 61, 1102),
    ("init", 1104, 1295),
    ("connection", 1250, 1522),  # includes validate_connection_string_format + connect/disconnect
    ("transaction", 1524, 1914),
    ("xa", 1916, 2442),
    ("diagnostics", 2444, 2722),
    ("capabilities", 2724, 3330),
    ("query", 3331, 4284),
    ("catalog", 4285, 4561),
    ("statement", 4563, 4847),
    ("stream", 4849, 5546),
    ("pool", 5548, 6174),
    ("bulk", 6176, 6545),
]

# Deduplicate connection overlap: init gets 1104-1248, connection gets 1250-1522
RANGES = [
    ("global", 61, 1102),
    ("init", 1104, 1248),
    ("connection", 1250, 1522),
    ("transaction", 1524, 1914),
    ("xa", 1916, 2442),
    ("diagnostics", 2444, 2722),
    ("capabilities", 2724, 3330),
    ("query", 3331, 4284),
    ("catalog", 4285, 4561),
    ("statement", 4563, 4847),
    ("stream", 4849, 5546),
    ("pool", 5548, 6174),
    ("bulk", 6176, 6545),
]

COMMON_HEADER = """// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use crate::ffi::state;
"""

MOD_RS = """// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod columnar_decompress;
pub mod guard;
pub mod state;

mod bulk;
mod capabilities;
mod catalog;
mod connection;
mod diagnostics;
mod global;
mod init;
mod pool;
mod query;
mod statement;
mod stream;
mod transaction;
mod xa;

#[cfg(test)]
mod tests;

pub use bulk::*;
pub use capabilities::*;
pub use catalog::*;
pub use connection::*;
pub use diagnostics::*;
pub use init::*;
pub use pool::*;
pub use query::*;
pub use statement::*;
pub use stream::*;
pub use transaction::*;
pub use xa::*;

/// Default rows per batch when caller passes 0 to odbc_stream_start_batched.
pub use global::{DEFAULT_CHUNK_SIZE, DEFAULT_FETCH_SIZE};
"""


def slice_lines(lines: list[str], start: int, end: int) -> list[str]:
    return lines[start - 1 : end]


def main() -> None:
    lines = SRC.read_text(encoding="utf-8").splitlines(keepends=True)
    test_start = None
    for i, line in enumerate(lines):
        if line.startswith("#[cfg(test)]") and i > 6000:
            test_start = i
            break
    if test_start is None:
        raise SystemExit("test block not found")

    # global module gets extra imports prepended
    global_imports = """use crate::async_bridge;
#[cfg(not(feature = "sqlserver-bcp"))]
use crate::engine::ArrayBinding;
#[cfg(feature = "sqlserver-bcp")]
use crate::engine::BulkCopyExecutor;
use crate::engine::{
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
use crate::error::StructuredError;
use crate::error::{OdbcError, Result};
use crate::handles::SharedConnection;
use crate::plugins::PluginRegistry;
use crate::pool::{ConnectionPool, SharedPooledConnection};
use crate::protocol::bound_param::ParamDirection;
use crate::protocol::{
    bound_param::ParamList, deserialize_param_buffer, parse_bulk_insert_payload, BulkInsertPayload,
    ParamValue,
};
#[cfg(feature = "sqlserver-bcp")]
use crate::protocol::{bulk_insert::is_null, BulkColumnData};
use crate::versioning::{abi_version::AbiVersion, api_version::ApiVersion};
use log::LevelFilter;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, UNIX_EPOCH};
use tokio::task::JoinHandle;

use super::state;

pub(crate) const DEFAULT_FETCH_SIZE: c_uint = 100;
pub(crate) const DEFAULT_CHUNK_SIZE: c_uint = 1024;
const DEFAULT_METADATA_CACHE_SIZE: usize = 100;
const DEFAULT_METADATA_CACHE_TTL_SECS: u64 = 300;

"""

    for name, start, end in RANGES:
        body = slice_lines(lines, start, end)
        if name == "global":
            content = global_imports + "".join(body)
            # Make key items pub(crate) for cross-module access
            content = content.replace("struct GlobalState", "pub(crate) struct GlobalState")
            content = content.replace(
                "fn try_lock_global_state()",
                "pub(crate) fn try_lock_global_state()",
            )
            content = content.replace(
                "fn lock_async_requests()",
                "pub(crate) fn lock_async_requests()",
            )
            content = content.replace("fn set_connection_error(", "pub(crate) fn set_connection_error(")
            content = content.replace(
                "fn set_connection_structured_error(",
                "pub(crate) fn set_connection_structured_error(",
            )
            content = content.replace("fn set_error(", "pub(crate) fn set_error(")
            content = content.replace("fn set_structured_error(", "pub(crate) fn set_structured_error(")
            content = content.replace("fn get_connection_error(", "pub(crate) fn get_connection_error(")
            content = content.replace(
                "fn get_connection_structured_error(",
                "pub(crate) fn get_connection_structured_error(",
            )
            content = content.replace("fn set_out_written_zero(", "pub(crate) fn set_out_written_zero(")
            content = content.replace("fn set_out_written_needed(", "pub(crate) fn set_out_written_needed(")
            content = content.replace("fn write_ffi_output_buffer(", "pub(crate) fn write_ffi_output_buffer(")
            content = content.replace(
                "fn write_connection_output_buffer(",
                "pub(crate) fn write_connection_output_buffer(",
            )
            content = content.replace("fn run_buffered_connection_call", "pub(crate) fn run_buffered_connection_call")
            content = content.replace("fn take_runnable_connection(", "pub(crate) fn take_runnable_connection(")
            content = content.replace("fn restore_pooled_connection(", "pub(crate) fn restore_pooled_connection(")
            content = content.replace("fn build_catalog_cache_key(", "pub(crate) fn build_catalog_cache_key(")
            content = content.replace("fn validate_param_buffer_shape(", "pub(crate) fn validate_param_buffer_shape(")
            content = content.replace("fn with_optional_param_buffer", "pub(crate) fn with_optional_param_buffer")
            content = content.replace("fn read_param_buffer_owned(", "pub(crate) fn read_param_buffer_owned(")
            content = content.replace("fn try_cached_legacy_params(", "pub(crate) fn try_cached_legacy_params(")
            content = content.replace("fn ffi_plugin_registry()", "pub(crate) fn ffi_plugin_registry()")
            content = content.replace("fn allocate_stream_id(", "pub(crate) fn allocate_stream_id(")
            content = content.replace("fn reserve_stream_start(", "pub(crate) fn reserve_stream_start(")
            content = content.replace("fn insert_stream(", "pub(crate) fn insert_stream(")
            content = content.replace("fn has_active_transaction_for_connection(", "pub(crate) fn has_active_transaction_for_connection(")
            content = content.replace("fn take_transactions_for_connection(", "pub(crate) fn take_transactions_for_connection(")
            content = content.replace("fn rollback_transactions_best_effort(", "pub(crate) fn rollback_transactions_best_effort(")
            content = content.replace("fn pool_has_begin_in_progress(", "pub(crate) fn pool_has_begin_in_progress(")
            content = content.replace("fn pool_create_inner(", "pub(crate) fn pool_create_inner(")
            content = content.replace("fn ptr_to_opt_str(", "pub(crate) fn ptr_to_opt_str(")
            content = content.replace("fn serialize_audit_events(", "pub(crate) fn serialize_audit_events(")
            content = content.replace("fn serialize_audit_status(", "pub(crate) fn serialize_audit_status(")
            content = content.replace("enum StreamKind", "pub(crate) enum StreamKind")
            content = content.replace("enum AsyncRequestOutcome", "pub(crate) enum AsyncRequestOutcome")
            content = content.replace("struct AsyncRequestSlot", "pub(crate) struct AsyncRequestSlot")
            content = content.replace("struct AsyncRequestManager", "pub(crate) struct AsyncRequestManager")
            content = content.replace("struct PooledConnectionState", "pub(crate) struct PooledConnectionState")
            content = content.replace("enum RunnableConnection", "pub(crate) enum RunnableConnection")
            content = content.replace("enum StreamStartTarget", "pub(crate) enum StreamStartTarget")
            content = content.replace("struct StreamReservation", "pub(crate) struct StreamReservation")
            content = content.replace("const FFI_OK:", "pub(crate) const FFI_OK:")
            content = content.replace("const FFI_ERR:", "pub(crate) const FFI_ERR:")
            content = content.replace("const FFI_ERR_BUFFER_TOO_SMALL:", "pub(crate) const FFI_ERR_BUFFER_TOO_SMALL:")
            content = content.replace("const MAX_ID_ALLOC_ATTEMPTS:", "pub(crate) const MAX_ID_ALLOC_ATTEMPTS:")
            content = content.replace("const CANCEL_UNSUPPORTED_NATIVE_CODE:", "pub(crate) const CANCEL_UNSUPPORTED_NATIVE_CODE:")
            content = content.replace("const STREAM_ASYNC_STATUS_", "pub(crate) const STREAM_ASYNC_STATUS_")
            content = content.replace("const ASYNC_STATUS_", "pub(crate) const ASYNC_STATUS_")
            content = content.replace("fn run_async_query(", "pub(crate) fn run_async_query(")
            content = content.replace("fn bulk_insert_parallel_with_pool(", "pub(crate) fn bulk_insert_parallel_with_pool(")
            content = content.replace("fn bulk_insert_payload(", "pub(crate) fn bulk_insert_payload(")
            content = content.replace("fn bulk_insert_payload_range(", "pub(crate) fn bulk_insert_payload_range(")
            content = content.replace("fn row_chunk_ranges(", "pub(crate) fn row_chunk_ranges(")
            content = content.replace("fn slice_null_bitmap(", "pub(crate) fn slice_null_bitmap(")
            content = content.replace("fn slice_payload_rows(", "pub(crate) fn slice_payload_rows(")
            content = content.replace("fn pooled_stream_completion(", "pub(crate) fn pooled_stream_completion(")
            content = content.replace("fn release_pooled_stream_reservation(", "pub(crate) fn release_pooled_stream_reservation(")
            content = content.replace("fn decrement_pooled_busy_counts(", "pub(crate) fn decrement_pooled_busy_counts(")
            content = content.replace("fn set_invalid_param_buffer_error(", "pub(crate) fn set_invalid_param_buffer_error(")
        else:
            content = COMMON_HEADER + "".join(body)
            if name == "connection":
                content = content.replace(
                    "fn validate_connection_string_format(",
                    "pub(crate) fn validate_connection_string_format(",
                )
            if name == "init":
                content = content.replace(
                    "use super::global::*;\n",
                    "use super::connection::validate_connection_string_format;\nuse super::global::*;\n",
                )
            if name == "transaction":
                content = content.replace(
                    "fn savepoint_dispatch",
                    "pub(crate) fn savepoint_dispatch",
                )
        out_path = OUT / f"{name}.rs"
        out_path.write_text(content, encoding="utf-8")
        print(f"wrote {out_path.name}: {end - start + 1} lines")

    # mod.rs
    (OUT / "mod.rs").write_text(MOD_RS, encoding="utf-8")
    print("wrote mod.rs")

    # tests -> src/ffi/tests.rs (in-crate; no Cargo.toml [[test]] entry needed)
    test_lines = lines[test_start:]
    test_content = """//! FFI unit tests (moved from the former monolithic `ffi/mod.rs`).

use super::connection::validate_connection_string_format;
use super::global::{
    lock_async_requests, try_lock_global_state, AsyncRequestManager, AsyncRequestOutcome,
    AsyncRequestSlot, GlobalState,
};
use super::state;
use super::*;
use crate::protocol::{
    serialize_bulk_insert_payload, serialize_bulk_insert_payload_v2, serialize_params,
    BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload, ParamValue,
};
use crate::versioning::{abi_version::AbiVersion, api_version::ApiVersion};
use crate::StructuredError;
use serde_json::Value;
use serial_test::serial;
use std::ffi::CString;
use std::os::raw::{c_char, c_uint};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Barrier, Mutex, OnceLock};
use std::time::Duration;

""" + "".join(test_lines[2:])  # skip #[cfg(test)] mod tests {

    (OUT / "tests.rs").write_text(test_content, encoding="utf-8")
    print("wrote tests.rs")


if __name__ == "__main__":
    main()
