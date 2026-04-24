//! Regression tests for audit findings.
//!
//! Each module corresponds to a specific finding documented in the v2.0.0 plan
//! (`bench_baselines/v1.2.1.txt` and the audit report).
//!
//! Tests are organised by severity:
//! - C* = critical
//! - A* = high
//! - M* = medium
//!
//! Tests requiring a live ODBC database are gated behind `#[ignore]` and only
//! run when `ODBC_TEST_DSN` is set.

pub mod a1_ffi_savepoint_injection;
pub mod d1_drt1_multi_result_wire;
pub mod a1_savepoint_injection;
pub mod a2_array_binding_injection;
pub mod a3_span_lifecycle;
pub mod c10_integer_binary_decode;
pub mod c1_ffi_panic_safety;
pub mod c6_multi_result_loop;
pub mod c9_bitmap_truncation;
pub mod m1_multi_result_batch_shapes;
pub mod m8_streaming_multi_result;
pub mod v21_dbms_detection;
pub mod v30_capabilities;
pub mod v30_returning_dialects;
pub mod v30_session_init;
pub mod v30_upsert_dialects;

// MSDTC + SQL Server XA (Windows, `--features xa-dtc`); see `xa_dtc_test.rs`.
#[cfg(all(target_os = "windows", feature = "xa-dtc"))]
pub mod xa_dtc_test;
