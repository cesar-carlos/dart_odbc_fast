use super::param_binding::{
    plan_multi_result_param_binding, require_inference_input_params, MultiResultParamBindingPlan,
};
use super::ExecutionEngine;
use crate::error::{OdbcError, Result};
use crate::protocol::{
    param_values_to_input_params, param_values_to_input_params_with_descriptions, try_encode_multi,
    MultiResultItem, ParamValue,
};
use odbc_api::handles::{AsStatementRef, SqlResult, Statement};
use odbc_api::{Connection, CursorImpl};

/// Returns true when the underlying ODBC error means "no more result sets",
/// i.e. SQLSTATE 02000 ("no data") which corresponds to the SQL_NO_DATA return code.
///
/// Replaces the previous `e.to_string().contains("SQL_NO_DATA")` heuristic (A13).
pub(super) fn is_no_more_results(err: &OdbcError) -> bool {
    let s = err.sqlstate();
    // SQLSTATE 02000 = "no data" (SQL_NO_DATA)
    s == [b'0', b'2', b'0', b'0', b'0']
}

/// Normalizes ODBC `row_count()` (`None` → 0) for wire encoding.
pub(super) fn odbc_row_count_i64(count: Option<usize>) -> i64 {
    count.map(|n| n as i64).unwrap_or(0)
}

/// First MULT item after execute when the bound-params path may have read rows.
pub(super) fn bound_params_first_multi_item(
    had_initial_cursor: bool,
    row_count_when_no_cursor: i64,
    result_set_body: Vec<u8>,
) -> MultiResultItem {
    if had_initial_cursor {
        MultiResultItem::ResultSet(result_set_body)
    } else {
        MultiResultItem::RowCount(row_count_when_no_cursor)
    }
}

impl ExecutionEngine {
    pub(super) fn execute_multi_result_inner(
        &self,
        conn: &Connection<'static>,
        sql: &str,
    ) -> Result<Vec<u8>> {
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let mut all_items: Vec<MultiResultItem> = Vec::new();

        // Encode the initial result inside a scope that bounds the cursor's
        // borrow on `stmt`. We use `cursor.into_stmt()` to drop the cursor
        // *without* calling `SQLCloseCursor` -- which is essential, because
        // `SQLCloseCursor` discards the pending result sets that follow it.
        let had_initial_cursor = {
            let initial_cursor = stmt.execute(()).map_err(OdbcError::from)?;
            if let Some(mut cursor) = initial_cursor {
                let encoded = self.encode_cursor(&mut cursor)?;
                all_items.push(MultiResultItem::ResultSet(encoded));
                // Consume cursor *without* close_cursor (preserves pending
                // result sets for SQLMoreResults below).
                let _stmt_ref = cursor.into_stmt();
                true
            } else {
                false
            }
        };

        if !had_initial_cursor {
            let rc = odbc_row_count_i64(stmt.row_count().map_err(OdbcError::from)?);
            all_items.push(MultiResultItem::RowCount(rc));
        }

        self.drive_more_results(&mut stmt, &mut all_items)?;
        try_encode_multi(&all_items)
    }

    pub(super) fn execute_multi_result_with_params_inner(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        if matches!(
            plan_multi_result_param_binding(params)?,
            MultiResultParamBindingPlan::InferencePrealloc
        ) {
            let parameters = require_inference_input_params(params)?;
            let mut prealloc = conn.preallocate().map_err(OdbcError::from)?;
            let mut all_items: Vec<MultiResultItem> = Vec::new();

            let had_initial_cursor = {
                let initial_cursor = if parameters.is_empty() {
                    prealloc.execute(sql, ()).map_err(OdbcError::from)?
                } else {
                    prealloc
                        .execute(sql, parameters.as_slice())
                        .map_err(OdbcError::from)?
                };

                if let Some(mut cursor) = initial_cursor {
                    let encoded = self.encode_cursor(&mut cursor)?;
                    all_items.push(MultiResultItem::ResultSet(encoded));
                    let _stmt_ref = cursor.into_stmt();
                    true
                } else {
                    false
                }
            };

            if !had_initial_cursor {
                let rc = odbc_row_count_i64(prealloc.row_count().map_err(OdbcError::from)?);
                all_items.push(MultiResultItem::RowCount(rc));
            }

            self.drive_more_results(&mut prealloc, &mut all_items)?;
            return try_encode_multi(&all_items);
        }

        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let parameters = match plan_multi_result_param_binding(params)? {
            MultiResultParamBindingPlan::InferencePrealloc => {
                unreachable!("inference path handled above")
            }
            MultiResultParamBindingPlan::PreparedStandard if params.is_empty() => Vec::new(),
            MultiResultParamBindingPlan::PreparedNullAware => {
                let descriptions = stmt
                    .parameter_descriptions()
                    .map_err(OdbcError::from)?
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(OdbcError::from)?;
                param_values_to_input_params_with_descriptions(params, &descriptions)?
            }
            MultiResultParamBindingPlan::PreparedStandard => param_values_to_input_params(params)?,
        };
        let mut all_items: Vec<MultiResultItem> = Vec::new();

        let had_initial_cursor = {
            let initial_cursor = if parameters.is_empty() {
                stmt.execute(()).map_err(OdbcError::from)?
            } else {
                stmt.execute(parameters.as_slice())
                    .map_err(OdbcError::from)?
            };

            if let Some(mut cursor) = initial_cursor {
                let encoded = self.encode_cursor(&mut cursor)?;
                all_items.push(MultiResultItem::ResultSet(encoded));
                // Same SQLCloseCursor avoidance as in `execute_multi_result_inner`.
                let _stmt_ref = cursor.into_stmt();
                true
            } else {
                false
            }
        };

        if !had_initial_cursor {
            let rc = odbc_row_count_i64(stmt.row_count().map_err(OdbcError::from)?);
            all_items.push(MultiResultItem::RowCount(rc));
        }

        self.drive_more_results(&mut stmt, &mut all_items)?;
        try_encode_multi(&all_items)
    }

    /// Walk every additional result set produced by `stmt` after the first
    /// one was encoded by the caller. Drives `Statement::more_results` (raw
    /// `SQLMoreResults`) so we keep advancing regardless of whether each
    /// step yields a cursor or a row-count.
    ///
    /// **M1 fix (v3.2.0)** — closes the long-standing gap where the previous
    /// implementation silently dropped result sets following a row-count-only
    /// first statement:
    ///
    /// 1. cursor → cursor → cursor                  (already worked)
    /// 2. row-count → row-count → row-count         (now collects all)
    /// 3. row-count → cursor                        ← was broken
    /// 4. cursor → row-count                        ← was broken
    pub(super) fn drive_more_results<S>(
        &self,
        stmt: &mut S,
        all_items: &mut Vec<MultiResultItem>,
    ) -> Result<()>
    where
        S: AsStatementRef,
    {
        loop {
            // SAFETY: caller guarantees no live cursor borrow on `stmt`.
            // `Statement::more_results` is `unsafe` precisely because it
            // would invalidate any outstanding cursor; `encode_cursor` always
            // consumes the cursor it receives, so this contract holds.
            let advance = unsafe { stmt.as_stmt_ref().more_results() };
            match advance {
                SqlResult::NoData => return Ok(()),
                SqlResult::Success(()) | SqlResult::SuccessWithInfo(()) => { /* continue */ }
                SqlResult::Error { .. } => {
                    let err = advance
                        .into_result(&stmt.as_stmt_ref())
                        .err()
                        .map(OdbcError::from)
                        .unwrap_or_else(|| OdbcError::OdbcApi("SQLMoreResults failed".to_string()));
                    if is_no_more_results(&err) {
                        return Ok(());
                    }
                    return Err(err);
                }
                SqlResult::NeedData => {
                    return Err(OdbcError::OdbcApi(
                        "Unexpected SQLMoreResults state: NeedData".to_string(),
                    ));
                }
                SqlResult::StillExecuting => {
                    return Err(OdbcError::OdbcApi(
                        "Unexpected SQLMoreResults state: StillExecuting".to_string(),
                    ));
                }
            }

            // Disambiguate cursor-vs-rowcount via num_result_cols().
            let cols = stmt
                .as_stmt_ref()
                .num_result_cols()
                .into_result(&stmt.as_stmt_ref())
                .map_err(OdbcError::from)?;
            if cols > 0 {
                // SAFETY: we just observed `num_result_cols > 0` after a
                // successful `SQLMoreResults`, so the statement currently
                // exposes a cursor; we hold no other live borrow of `stmt`.
                // We take care to consume the cursor via `into_stmt()` so the
                // pending result sets after this one are not discarded by
                // `SQLCloseCursor`.
                let mut cursor = unsafe { CursorImpl::new(stmt.as_stmt_ref()) };
                let encoded = self.encode_cursor(&mut cursor)?;
                all_items.push(MultiResultItem::ResultSet(encoded));
                let _stmt_ref = cursor.into_stmt();
            } else {
                let rc = stmt
                    .as_stmt_ref()
                    .row_count()
                    .into_result(&stmt.as_stmt_ref())
                    .map_err(OdbcError::from)?;
                all_items.push(MultiResultItem::RowCount(rc as i64));
            }
        }
    }

    /// Like [`Self::drive_more_results`], but only collects cursor result
    /// sets, encoded as v1 (for the `RC1\0` trailer), skipping row-count-only
    /// steps while still advancing.
    pub(super) fn drive_more_ref_cursor_blobs<S>(
        &self,
        stmt: &mut S,
        out: &mut Vec<Vec<u8>>,
    ) -> Result<()>
    where
        S: AsStatementRef,
    {
        loop {
            let advance = unsafe { stmt.as_stmt_ref().more_results() };
            match advance {
                SqlResult::NoData => return Ok(()),
                SqlResult::Success(()) | SqlResult::SuccessWithInfo(()) => {}
                SqlResult::Error { .. } => {
                    let err = advance
                        .into_result(&stmt.as_stmt_ref())
                        .err()
                        .map(OdbcError::from)
                        .unwrap_or_else(|| {
                            OdbcError::OdbcApi("SQLMoreResults failed (ref cursor)".to_string())
                        });
                    if is_no_more_results(&err) {
                        return Ok(());
                    }
                    return Err(err);
                }
                SqlResult::NeedData => {
                    return Err(OdbcError::OdbcApi(
                        "Unexpected SQLMoreResults state: NeedData (ref cursor)".to_string(),
                    ));
                }
                SqlResult::StillExecuting => {
                    return Err(OdbcError::OdbcApi(
                        "Unexpected SQLMoreResults state: StillExecuting (ref cursor)".to_string(),
                    ));
                }
            }
            let cols = stmt
                .as_stmt_ref()
                .num_result_cols()
                .into_result(&stmt.as_stmt_ref())
                .map_err(OdbcError::from)?;
            if cols > 0 {
                let mut cursor = unsafe { CursorImpl::new(stmt.as_stmt_ref()) };
                out.push(self.encode_cursor_v1(&mut cursor)?);
                let _ = cursor.into_stmt();
            } else {
                let _ = stmt
                    .as_stmt_ref()
                    .row_count()
                    .into_result(&stmt.as_stmt_ref())
                    .map_err(OdbcError::from)?;
            }
        }
    }
}
