use super::prepared_cache::PreparedStatementCache;
use crate::engine::cell_reader::CellReader;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;
use crate::observability::{Metrics, SpanGuard, StructuredLogger, Tracer};
use crate::plugins::{DriverPlugin, PluginRegistry};
use crate::protocol::bound_param::BoundParam;
use crate::protocol::{
    encode_multi, has_null_param, param_values_to_input_params,
    param_values_to_input_params_with_descriptions, param_values_to_input_params_with_inference,
    row_buffer_to_columnar, ColumnarEncoder, MultiResultItem, OdbcType, ParamValue, RowBuffer,
    RowBufferEncoder,
};
use crate::security::AuditLogger;
use log::Level;
use odbc_api::handles::{AsStatementRef, SqlResult, Statement};
use odbc_api::{Connection, Cursor, CursorImpl, ResultSetMetadata};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Returns true when the underlying ODBC error means "no more result sets",
/// i.e. SQLSTATE 02000 ("no data") which corresponds to the SQL_NO_DATA return code.
///
/// Replaces the previous `e.to_string().contains("SQL_NO_DATA")` heuristic (A13).
pub(super) fn is_no_more_results(err: &OdbcError) -> bool {
    let s = err.sqlstate();
    // SQLSTATE 02000 = "no data" (SQL_NO_DATA)
    s == [b'0', b'2', b'0', b'0', b'0']
}

/// Gate for Oracle-only ref-cursor binds before any connection I/O.
/// How [`ExecutionEngine::execute_query_with_params_inner`] routes positional params (no ODBC).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum QueryParamBindingPlan {
    DirectNoParams,
    InferenceExecute,
    PreparedNullAware,
    PreparedStandard,
}

pub(super) fn plan_query_param_binding(params: &[ParamValue]) -> Result<QueryParamBindingPlan> {
    if params.is_empty() {
        return Ok(QueryParamBindingPlan::DirectNoParams);
    }
    if has_null_param(params) {
        if param_values_to_input_params_with_inference(params)?.is_some() {
            return Ok(QueryParamBindingPlan::InferenceExecute);
        }
        return Ok(QueryParamBindingPlan::PreparedNullAware);
    }
    Ok(QueryParamBindingPlan::PreparedStandard)
}

/// How [`ExecutionEngine::execute_multi_result_with_params_inner`] routes params (no ODBC).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum MultiResultParamBindingPlan {
    InferencePrealloc,
    PreparedStandard,
    PreparedNullAware,
}

pub(super) fn plan_multi_result_param_binding(
    params: &[ParamValue],
) -> Result<MultiResultParamBindingPlan> {
    if param_values_to_input_params_with_inference(params)?.is_some() {
        return Ok(MultiResultParamBindingPlan::InferencePrealloc);
    }
    if has_null_param(params) {
        return Ok(MultiResultParamBindingPlan::PreparedNullAware);
    }
    Ok(MultiResultParamBindingPlan::PreparedStandard)
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

/// Encodes a row buffer for query / optional-cursor paths (row-major or columnar).
pub(super) fn encode_query_result_payload(
    row_buffer: &RowBuffer,
    use_columnar: bool,
    use_compression: bool,
) -> Result<Vec<u8>> {
    if use_columnar {
        let columnar_buffer = row_buffer_to_columnar(row_buffer);
        ColumnarEncoder::encode(&columnar_buffer, use_compression)
    } else {
        Ok(RowBufferEncoder::encode(row_buffer))
    }
}

pub(super) fn ensure_ref_cursor_oracle_only(
    bound: &[BoundParam],
    oracle_active: bool,
) -> Result<()> {
    use super::ref_cursor_oracle::bound_has_ref_cursor;

    if bound_has_ref_cursor(bound) && !oracle_active {
        return Err(OdbcError::ValidationError(
            "DIRECTED_PARAM|ref_cursor_out_oracle_only: ParamValue::RefCursorOut is \
             only supported with the Oracle ODBC driver; see \
             doc/notes/REF_CURSOR_ORACLE_ROADMAP.md"
                .to_string(),
        ));
    }
    Ok(())
}

pub struct ExecutionEngine {
    prepared_cache: Arc<PreparedStatementCache>,
    use_columnar: bool,
    use_compression: bool,
    plugin_registry: Option<Arc<PluginRegistry>>,
    active_plugin: Arc<Mutex<Option<Arc<dyn DriverPlugin>>>>,
    metrics: Arc<Metrics>,
    tracer: Arc<Tracer>,
    logger: Arc<StructuredLogger>,
    audit_logger: Arc<AuditLogger>,
}

impl ExecutionEngine {
    pub fn new(cache_size: usize) -> Self {
        let prepared_cache = Arc::new(PreparedStatementCache::new(cache_size));
        let metrics = Arc::new(Metrics::new());
        metrics.set_prepared_cache(Arc::clone(&prepared_cache));
        Self {
            prepared_cache,
            use_columnar: false,
            use_compression: false,
            plugin_registry: Some(Arc::new(PluginRegistry::default())),
            active_plugin: Arc::new(Mutex::new(None)),
            metrics,
            tracer: Arc::new(Tracer::new()),
            logger: Arc::new(StructuredLogger::default()),
            audit_logger: Arc::new(AuditLogger::default()),
        }
    }

    pub fn with_columnar(cache_size: usize, use_compression: bool) -> Self {
        let prepared_cache = Arc::new(PreparedStatementCache::new(cache_size));
        let metrics = Arc::new(Metrics::new());
        metrics.set_prepared_cache(Arc::clone(&prepared_cache));
        Self {
            prepared_cache,
            use_columnar: true,
            use_compression,
            plugin_registry: Some(Arc::new(PluginRegistry::default())),
            active_plugin: Arc::new(Mutex::new(None)),
            metrics,
            tracer: Arc::new(Tracer::new()),
            logger: Arc::new(StructuredLogger::default()),
            audit_logger: Arc::new(AuditLogger::default()),
        }
    }

    pub fn with_plugin_registry(cache_size: usize, registry: Arc<PluginRegistry>) -> Self {
        let prepared_cache = Arc::new(PreparedStatementCache::new(cache_size));
        let metrics = Arc::new(Metrics::new());
        metrics.set_prepared_cache(Arc::clone(&prepared_cache));
        Self {
            prepared_cache,
            use_columnar: false,
            use_compression: false,
            plugin_registry: Some(registry),
            active_plugin: Arc::new(Mutex::new(None)),
            metrics,
            tracer: Arc::new(Tracer::new()),
            logger: Arc::new(StructuredLogger::default()),
            audit_logger: Arc::new(AuditLogger::default()),
        }
    }

    pub fn set_connection_string(&self, connection_string: &str) {
        if let Some(ref registry) = self.plugin_registry {
            if let Some(plugin) = registry.get_for_connection(connection_string) {
                if let Ok(mut active) = self.active_plugin.lock() {
                    *active = Some(plugin);
                }
            }
        }
    }

    pub fn execute_query(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        use std::time::Instant;
        let start_time = Instant::now();
        let _span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = HashMap::new();
        metadata.insert("span_id".to_string(), _span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let result = self.execute_query_inner(conn, sql);

        let latency = start_time.elapsed();
        self.metrics.record_query(latency);

        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }

        result
    }

    fn execute_query_inner(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        let plugin = self.current_plugin();
        let optimized_sql = self.optimize_sql_with_plugin(sql, plugin.as_deref());

        self.prepared_cache.get_or_insert(&optimized_sql);

        let mut stmt = conn.prepare(&optimized_sql).map_err(OdbcError::from)?;

        let cursor = stmt.execute(()).map_err(OdbcError::from)?;
        self.encode_optional_cursor(cursor, plugin.as_deref())
    }

    /// Execute query using cached connection (reuses prepared statements when feature enabled).
    pub fn execute_query_cached(
        &self,
        cached: &mut CachedConnection,
        sql: &str,
    ) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let _span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = HashMap::new();
        metadata.insert("span_id".to_string(), _span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let plugin = self.current_plugin();
        let optimized_sql = self.optimize_sql_with_plugin(sql, plugin.as_deref());

        self.prepared_cache.get_or_insert(&optimized_sql);

        let result = cached.execute_query_no_params(&optimized_sql);

        let latency = start_time.elapsed();
        self.metrics.record_query(latency);

        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }

        result
    }

    pub fn execute_query_with_params(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        self.execute_query_with_params_and_timeout(conn, sql, params, None, None)
    }

    pub fn execute_query_with_params_and_timeout(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
        timeout_sec: Option<usize>,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let _span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = std::collections::HashMap::new();
        metadata.insert("span_id".to_string(), _span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let result =
            self.execute_query_with_params_inner(conn, sql, params, timeout_sec, fetch_size);

        self.metrics.record_query(start_time.elapsed());

        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }

        result
    }

    /// Positional `?` with `INPUT` / `OUTPUT` / `INOUT` (DRT1 wire from Dart). Integer/BigInt OUT only (MVP).
    pub fn execute_query_with_bound_params_and_timeout(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        bound: &[BoundParam],
        timeout_sec: Option<usize>,
        _fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        use std::time::Instant;

        use super::output_aware_params::bound_to_slots;
        let start_time = Instant::now();
        let _span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = std::collections::HashMap::new();
        metadata.insert("span_id".to_string(), _span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let result: Result<Vec<u8>> = (|| {
            use super::ref_cursor_oracle::bound_has_ref_cursor;

            ensure_ref_cursor_oracle_only(bound, self.is_oracle_plugin_active())?;
            if bound_has_ref_cursor(bound) {
                return self.execute_oracle_ref_cursor_path(conn, sql, bound, timeout_sec);
            }

            let mut odbc_params = bound_to_slots(bound)?;
            // SQL Server (and other drivers) may only populate `OUTPUT` bind buffers after every
            // sp batch result set has been advanced with `SQLMoreResults`, mirroring
            // `execute_multi_result_inner` and `execute_oracle_ref_cursor_path` (which both call
            // `more_results` before reading `out_vals`). We also:
            // - Use a connection `Preallocated` + `Preallocated::execute` (same as
            //   `Connection::execute` / `SQLExecDirect`) for T-SQL/ODBC `{CALL ?}`; `SQLPrepare` on
            //   some drivers mishandles the ODBC procedure escape or multi-statement batches.
            // - Use `Cursor::into_stmt()` when dropping the first cursor so we do *not* call
            //   `SQLCloseCursor` in a way that discards the pending `SQLMoreResults` chain.
            let mut prealloc = conn.preallocate().map_err(OdbcError::from)?;
            if let Some(s) = timeout_sec {
                prealloc.set_query_timeout_sec(s).map_err(OdbcError::from)?;
            }
            let mut row_buffer = RowBuffer::new();
            let plugin = self.current_plugin();
            // Keep the cursor binding adjacent to the `if let` that consumes it. Any `let` in
            // between (e.g. `row_buffer`) can extend the borrow in NLL to the end of the outer
            // closure, blocking `row_count` / `more_results` on the same `Preallocated` handle.
            let had_initial_cursor = {
                let initial_cursor = prealloc
                    .execute(sql, &mut odbc_params)
                    .map_err(OdbcError::from)?;
                if let Some(mut cursor) = initial_cursor {
                    let column_types =
                        self.describe_columns(&mut cursor, &mut row_buffer, plugin.as_deref())?;

                    let mut cell_reader = CellReader::new();
                    while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                        let mut row_data = Vec::with_capacity(column_types.len());

                        for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                            let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                                OdbcError::InternalError("Invalid column number".to_string())
                            })?;

                            let cell_data =
                                cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;

                            row_data.push(cell_data);
                        }

                        row_buffer.add_row(row_data);
                    }
                    let _stmt_ref = cursor.into_stmt();
                    true
                } else {
                    false
                }
            };

            // When the execute returned no cursor, capture the affected-row count so
            // we can materialise it as a `RowCount` item when the drain is non-empty.
            // Previously the value was discarded (`let _rc = ...`), which caused the
            // multi-result path to emit a spurious empty `ResultSet` as the first MULT
            // item instead of the real row-count.
            let initial_rc: Option<i64> = if !had_initial_cursor {
                Some(odbc_row_count_i64(
                    prealloc.row_count().map_err(OdbcError::from)?,
                ))
            } else {
                None
            };

            // Drain remaining batches so drivers that defer `OUTPUT` values until
            // `SQLMoreResults` is exhausted (notably SQL Server) expose bound OUT buffers.
            //
            // When the drain is empty (typical single-RS procedure) the wire format is
            // unchanged: `[single ODBC/columnar payload][optional OUT1]`.
            //
            // When additional result sets or row-counts are present (e.g. a stored
            // procedure that executes DML *and* returns SELECT result sets before its
            // `OUTPUT` parameters are populated), we emit a `MULT` envelope containing
            // every item (first + drain) followed by the `OUT1` trailer. The Dart
            // `_parseBufferToQueryResult` detects the leading `MULT` magic and routes
            // accordingly so existing callers that only use the first result set keep
            // working without change.
            let mut drain: Vec<MultiResultItem> = Vec::new();
            self.drive_more_results(&mut prealloc, &mut drain)?;

            coalesce_for_json_rows(&mut row_buffer);

            let out_vals = odbc_params.output_footer_values();

            if drain.is_empty() {
                // Fast path: single result set — preserve the original wire format.
                let body = encode_query_result_payload(
                    &row_buffer,
                    self.use_columnar,
                    self.use_compression,
                )?;
                Ok(RowBufferEncoder::append_output_footer(body, &out_vals))
            } else {
                // Multi-result path: wrap every item in a MULT envelope, then append OUT1.
                let first_body = encode_query_result_payload(
                    &row_buffer,
                    self.use_columnar,
                    self.use_compression,
                )?;
                let first_item = match initial_rc {
                    Some(rc) => bound_params_first_multi_item(false, rc, first_body),
                    None => bound_params_first_multi_item(true, 0, first_body),
                };
                let mut all_items = Vec::with_capacity(1 + drain.len());
                all_items.push(first_item);
                all_items.extend(drain);
                let multi_body = encode_multi(&all_items);
                Ok(RowBufferEncoder::append_output_footer(
                    multi_body, &out_vals,
                ))
            }
        })();

        self.metrics.record_query(start_time.elapsed());
        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }
        result
    }

    fn execute_query_with_params_inner(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
        timeout_sec: Option<usize>,
        _fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        let plugin = self.current_plugin();
        match plan_query_param_binding(params)? {
            QueryParamBindingPlan::DirectNoParams => {
                let cursor = conn
                    .execute(sql, (), timeout_sec)
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor(cursor, plugin.as_deref())
            }
            QueryParamBindingPlan::InferenceExecute => {
                let parameters = param_values_to_input_params_with_inference(params)?
                    .expect("plan_query_param_binding guarantees inference path");
                let cursor = conn
                    .execute(sql, parameters.as_slice(), timeout_sec)
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor(cursor, plugin.as_deref())
            }
            QueryParamBindingPlan::PreparedNullAware => {
                let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
                if let Some(timeout_sec) = timeout_sec {
                    stmt.set_query_timeout_sec(timeout_sec)
                        .map_err(OdbcError::from)?;
                }
                let descriptions = stmt
                    .parameter_descriptions()
                    .map_err(OdbcError::from)?
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(OdbcError::from)?;
                let parameters =
                    param_values_to_input_params_with_descriptions(params, &descriptions)?;
                let cursor = stmt
                    .execute(parameters.as_slice())
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor(cursor, plugin.as_deref())
            }
            QueryParamBindingPlan::PreparedStandard => {
                let parameters = param_values_to_input_params(params)?;
                let cursor = conn
                    .execute(sql, parameters.as_slice(), timeout_sec)
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor(cursor, plugin.as_deref())
            }
        }

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
    }

    fn encode_optional_cursor<C>(
        &self,
        cursor: Option<C>,
        plugin: Option<&dyn DriverPlugin>,
    ) -> Result<Vec<u8>>
    where
        C: Cursor + ResultSetMetadata,
    {
        let mut row_buffer = RowBuffer::new();

        if let Some(mut cursor) = cursor {
            let column_types = self.describe_columns(&mut cursor, &mut row_buffer, plugin)?;

            let mut cell_reader = CellReader::new();
            while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                let mut row_data = Vec::with_capacity(column_types.len());

                for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                    let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column number".to_string())
                    })?;

                    let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;

                    row_data.push(cell_data);
                }

                row_buffer.add_row(row_data);
            }
        }

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        encode_query_result_payload(&row_buffer, self.use_columnar, self.use_compression)
    }

    pub fn execute_multi_result(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let _span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = HashMap::new();
        metadata.insert("span_id".to_string(), _span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let result = self.execute_multi_result_inner(conn, sql);

        self.metrics.record_query(start_time.elapsed());

        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }

        result
    }

    /// Execute a multi-result batch with `?` positional parameters.
    /// Same wire format as [`execute_multi_result`].
    pub fn execute_multi_result_with_params(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let _span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = HashMap::new();
        metadata.insert("span_id".to_string(), _span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let result = self.execute_multi_result_with_params_inner(conn, sql, params);

        self.metrics.record_query(start_time.elapsed());

        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }

        result
    }

    fn execute_multi_result_inner(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
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
        Ok(encode_multi(&all_items))
    }

    fn execute_multi_result_with_params_inner(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        if matches!(
            plan_multi_result_param_binding(params)?,
            MultiResultParamBindingPlan::InferencePrealloc
        ) {
            let parameters = param_values_to_input_params_with_inference(params)?
                .expect("plan_multi_result_param_binding guarantees inference path");
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
            return Ok(encode_multi(&all_items));
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
        Ok(encode_multi(&all_items))
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
    fn drive_more_results<S>(
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

    fn is_oracle_plugin_active(&self) -> bool {
        self.active_plugin
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|p| p.name() == "oracle"))
            .unwrap_or(false)
    }

    /// Oracle ODBC: ref-cursor `?` are stripped, remaining binds executed;
    /// each `SYS_REFCURSOR` is a separate result set (first from `execute`,
    /// rest from `SQLMoreResults`). The primary row payload is left empty; all
    /// cursors are encoded as v1 and appended in `RC1\0` order.
    fn execute_oracle_ref_cursor_path(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        bound: &[BoundParam],
        timeout_sec: Option<usize>,
    ) -> Result<Vec<u8>> {
        use super::output_aware_params::bound_to_slots;
        use super::ref_cursor_oracle::{
            filter_non_ref_cursor_params, strip_ref_cursor_placeholders,
        };

        let ref_count = bound
            .iter()
            .filter(|b| matches!(b.value, ParamValue::RefCursorOut))
            .count();
        let stripped = strip_ref_cursor_placeholders(sql, bound)?;
        let filtered = filter_non_ref_cursor_params(bound);
        let mut odbc_params = bound_to_slots(&filtered)?;

        let mut prep = conn.prepare(&stripped).map_err(OdbcError::from)?;
        if let Some(s) = timeout_sec {
            prep.set_query_timeout_sec(s).map_err(OdbcError::from)?;
        }
        let mut ref_blobs: Vec<Vec<u8>> = Vec::new();
        {
            // Consume the initial cursor (if any) before any other use of
            // `prep`, because `Option<CursorImpl<StatementRef>>` borrows
            // the underlying statement.
            let first = prep.execute(&mut odbc_params).map_err(OdbcError::from)?;
            if let Some(mut c) = first {
                ref_blobs.push(self.encode_cursor_v1(&mut c)?);
                let _ = c.into_stmt();
            }
        }
        self.drive_more_ref_cursor_blobs(&mut prep, &mut ref_blobs)?;

        if ref_blobs.len() != ref_count {
            return Err(OdbcError::ValidationError(format!(
                "DIRECTED_PARAM|ref_cursor_oracle_resultset_count: expected {ref_count} \
                 SYS_REFCURSOR result set(s) from the Oracle driver, found {}",
                ref_blobs.len()
            )));
        }

        let out_vals = odbc_params.output_footer_values();
        let mut main_buffer = RowBuffer::new();
        coalesce_for_json_rows(&mut main_buffer);
        let main_body =
            encode_query_result_payload(&main_buffer, self.use_columnar, self.use_compression)?;
        let body = RowBufferEncoder::append_output_footer(main_body, &out_vals);
        Ok(RowBufferEncoder::append_ref_cursor_footer(body, &ref_blobs))
    }

    /// Like [`Self::drive_more_results`], but only collects cursor result
    /// sets, encoded as v1 (for the `RC1\0` trailer), skipping row-count-only
    /// steps while still advancing.
    fn drive_more_ref_cursor_blobs<S>(&self, stmt: &mut S, out: &mut Vec<Vec<u8>>) -> Result<()>
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

    /// Same as [`Self::encode_cursor`], but always row-major v1 (required
    /// for `RC1\0` embedded messages on the wire).
    fn encode_cursor_v1<C: Cursor + ResultSetMetadata>(&self, cursor: &mut C) -> Result<Vec<u8>> {
        let mut row_buffer = RowBuffer::new();
        let plugin = self.current_plugin();
        let column_types = self.describe_columns(cursor, &mut row_buffer, plugin.as_deref())?;
        let mut cell_reader = CellReader::new();
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                row_data.push(cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?);
            }
            row_buffer.add_row(row_data);
        }
        coalesce_for_json_rows(&mut row_buffer);
        Ok(RowBufferEncoder::encode(&row_buffer))
    }

    /// Read every row from `cursor`, encode it as a row-buffer (or columnar
    /// buffer when `use_columnar` is on) and return the bytes.
    ///
    /// Takes `&mut C` instead of consuming `C` so the caller can choose
    /// whether to drop the cursor (which calls `SQLCloseCursor` and discards
    /// pending result sets) or to consume it via `cursor.into_stmt()` (which
    /// preserves them for `SQLMoreResults`). The multi-result path uses the
    /// latter.
    fn encode_cursor<C: Cursor + ResultSetMetadata>(&self, cursor: &mut C) -> Result<Vec<u8>> {
        let mut row_buffer = RowBuffer::new();
        let plugin = self.current_plugin();
        let column_types = self.describe_columns(cursor, &mut row_buffer, plugin.as_deref())?;

        let mut cell_reader = CellReader::new();
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
                row_data.push(cell_data);
            }
            row_buffer.add_row(row_data);
        }

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        encode_query_result_payload(&row_buffer, self.use_columnar, self.use_compression)
    }

    pub fn get_metrics(&self) -> Arc<Metrics> {
        self.metrics.clone()
    }

    pub fn get_tracer(&self) -> Arc<Tracer> {
        self.tracer.clone()
    }

    pub fn clear_cache(&self) {
        self.prepared_cache.clear();
    }

    fn current_plugin(&self) -> Option<Arc<dyn DriverPlugin>> {
        self.active_plugin
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
    }

    fn optimize_sql_with_plugin(&self, sql: &str, plugin: Option<&dyn DriverPlugin>) -> String {
        plugin
            .map(|active| active.optimize_query(sql))
            .unwrap_or_else(|| sql.to_string())
    }

    fn map_sql_type(&self, sql_type_code: i16, plugin: Option<&dyn DriverPlugin>) -> OdbcType {
        plugin
            .map(|active| active.map_type(sql_type_code))
            .unwrap_or_else(|| OdbcType::from_odbc_sql_type(sql_type_code))
    }

    fn describe_columns<C: ResultSetMetadata>(
        &self,
        cursor: &mut C,
        row_buffer: &mut RowBuffer,
        plugin: Option<&dyn DriverPlugin>,
    ) -> Result<Vec<OdbcType>> {
        let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

        for col_idx in 1..=cols_u16 {
            let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = self.map_sql_type(sql_type_code, plugin);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        Ok(column_types)
    }
}

#[cfg(test)]
impl ExecutionEngine {
    pub(crate) fn test_optimize_sql(&self, sql: &str, plugin: Option<&dyn DriverPlugin>) -> String {
        self.optimize_sql_with_plugin(sql, plugin)
    }

    pub(crate) fn test_map_sql_type(
        &self,
        code: i16,
        plugin: Option<&dyn DriverPlugin>,
    ) -> OdbcType {
        self.map_sql_type(code, plugin)
    }

    pub(crate) fn test_is_oracle_plugin_active(&self) -> bool {
        self.is_oracle_plugin_active()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugins::{
        mariadb::MariaDbPlugin, postgres::PostgresPlugin, sqlserver::SqlServerPlugin,
        PluginRegistry,
    };
    use crate::protocol::bound_param::{BoundParam, ParamDirection};
    use crate::protocol::ParamValue;

    #[test]
    fn test_execution_engine_new() {
        let engine = ExecutionEngine::new(100);
        assert_eq!(engine.prepared_cache.max_size(), 100);
        assert!(!engine.use_columnar);
        assert!(!engine.use_compression);
        assert!(engine.plugin_registry.is_some());
    }

    #[test]
    fn test_execution_engine_with_columnar() {
        let engine = ExecutionEngine::with_columnar(50, true);
        assert_eq!(engine.prepared_cache.max_size(), 50);
        assert!(engine.use_columnar);
        assert!(engine.use_compression);
    }

    #[test]
    fn test_execution_engine_with_columnar_no_compression() {
        let engine = ExecutionEngine::with_columnar(50, false);
        assert_eq!(engine.prepared_cache.max_size(), 50);
        assert!(engine.use_columnar);
        assert!(!engine.use_compression);
    }

    #[test]
    fn test_execution_engine_with_plugin_registry() {
        let registry = Arc::new(PluginRegistry::default());
        let engine = ExecutionEngine::with_plugin_registry(200, registry.clone());
        assert_eq!(engine.prepared_cache.max_size(), 200);
        assert!(!engine.use_columnar);
        assert!(!engine.use_compression);
        assert!(engine.plugin_registry.is_some());
    }

    #[test]
    fn test_set_connection_string() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={SQL Server};Server=localhost;");
        assert!(engine.plugin_registry.is_some());
    }

    #[test]
    fn test_set_connection_string_with_invalid_string() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("invalid connection string");
        assert!(engine.plugin_registry.is_some());
    }

    #[test]
    fn test_clear_cache() {
        let engine = ExecutionEngine::new(100);
        assert!(engine.prepared_cache.is_empty());

        engine.prepared_cache.get_or_insert("SELECT 1");
        assert!(!engine.prepared_cache.is_empty());

        engine.clear_cache();
        assert!(engine.prepared_cache.is_empty());
    }

    #[test]
    fn test_get_metrics() {
        let engine = ExecutionEngine::new(100);
        let metrics = engine.get_metrics();
        assert!(Arc::ptr_eq(&engine.metrics, &metrics));
    }

    #[test]
    fn test_get_tracer() {
        let engine = ExecutionEngine::new(100);
        let tracer = engine.get_tracer();
        assert!(Arc::ptr_eq(&engine.tracer, &tracer));
    }

    #[test]
    fn test_prepared_cache_integration() {
        let engine = ExecutionEngine::new(10);
        assert_eq!(engine.prepared_cache.max_size(), 10);
        assert!(engine.prepared_cache.is_empty());

        engine.prepared_cache.get_or_insert("SELECT 1");
        assert_eq!(engine.prepared_cache.len(), 1);

        engine.prepared_cache.get_or_insert("SELECT 2");
        assert_eq!(engine.prepared_cache.len(), 2);

        engine.clear_cache();
        assert!(engine.prepared_cache.is_empty());
    }

    #[test]
    fn test_set_connection_string_sqlserver() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={SQL Server};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "sqlserver");
        }
    }

    #[test]
    fn test_set_connection_string_postgres() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={PostgreSQL};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "postgres");
        }
    }

    #[test]
    fn test_set_connection_string_oracle() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={Oracle};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "oracle");
        }
    }

    #[test]
    fn test_set_connection_string_sybase() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={Sybase};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "sybase");
        }
    }

    #[test]
    fn test_set_connection_string_mssql_variant() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={MSSQL};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "sqlserver");
        }
    }

    #[test]
    fn test_set_connection_string_postgresql_variant() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={PostgreSQL};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "postgres");
        }
    }

    #[test]
    fn test_set_connection_string_sql_anywhere() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={SQL Anywhere};Server=localhost;Database=test;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "sybase");
        }
    }

    #[test]
    fn test_set_connection_string_unknown_driver() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("Driver={UnknownDriver};Server=localhost;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_none());
    }

    #[test]
    fn test_set_connection_string_empty() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_none());
    }

    #[test]
    fn test_set_connection_string_case_insensitive() {
        let engine = ExecutionEngine::new(100);
        engine.set_connection_string("DRIVER={SQL SERVER};SERVER=localhost;");

        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
        if let Some(ref plugin) = *active_plugin {
            assert_eq!(plugin.name(), "sqlserver");
        }
    }

    #[test]
    fn test_set_connection_string_multiple_times() {
        let engine = ExecutionEngine::new(100);

        engine.set_connection_string("Driver={SQL Server};Server=localhost;");
        let active_plugin1 = engine.active_plugin.lock().unwrap();
        assert!(active_plugin1.is_some());
        if let Some(ref plugin) = *active_plugin1 {
            assert_eq!(plugin.name(), "sqlserver");
        }
        drop(active_plugin1);

        engine.set_connection_string("Driver={PostgreSQL};Server=localhost;");
        let active_plugin2 = engine.active_plugin.lock().unwrap();
        assert!(active_plugin2.is_some());
        if let Some(ref plugin) = *active_plugin2 {
            assert_eq!(plugin.name(), "postgres");
        }
    }

    #[test]
    fn test_metrics_recording() {
        let engine = ExecutionEngine::new(100);
        let metrics = engine.get_metrics();

        let query_metrics = metrics.get_query_metrics();
        let initial_query_count = query_metrics.query_count;
        let initial_error_count = metrics.get_error_count();

        assert_eq!(initial_query_count, 0);
        assert_eq!(initial_error_count, 0);
    }

    #[test]
    fn test_tracer_span_creation() {
        let engine = ExecutionEngine::new(100);
        let tracer = engine.get_tracer();

        let span_id = tracer.start_span("test_query".to_string());
        assert!(span_id > 0);

        let span = tracer.finish_span(span_id);
        assert!(span.is_some());
    }

    #[test]
    fn test_tracer_multiple_spans() {
        let engine = ExecutionEngine::new(100);
        let tracer = engine.get_tracer();

        let span1 = tracer.start_span("query1".to_string());
        let span2 = tracer.start_span("query2".to_string());

        assert_ne!(span1, span2);

        let finished1 = tracer.finish_span(span1);
        let finished2 = tracer.finish_span(span2);

        assert!(finished1.is_some());
        assert!(finished2.is_some());
    }

    #[test]
    fn test_prepared_cache_with_different_sql() {
        let engine = ExecutionEngine::new(5);

        engine.prepared_cache.get_or_insert("SELECT 1");
        engine.prepared_cache.get_or_insert("SELECT 2");
        engine.prepared_cache.get_or_insert("SELECT 3");
        engine.prepared_cache.get_or_insert("SELECT 4");
        engine.prepared_cache.get_or_insert("SELECT 5");

        assert_eq!(engine.prepared_cache.len(), 5);

        engine.prepared_cache.get_or_insert("SELECT 1");
        assert_eq!(engine.prepared_cache.len(), 5);
    }

    #[test]
    fn test_prepared_cache_eviction() {
        let engine = ExecutionEngine::new(2);

        engine.prepared_cache.get_or_insert("SELECT 1");
        engine.prepared_cache.get_or_insert("SELECT 2");
        assert_eq!(engine.prepared_cache.len(), 2);

        engine.prepared_cache.get_or_insert("SELECT 3");
        assert_eq!(engine.prepared_cache.len(), 2);
    }

    #[test]
    fn test_with_plugin_registry_custom() {
        let registry = Arc::new(PluginRegistry::new());
        let engine = ExecutionEngine::with_plugin_registry(150, registry.clone());

        assert_eq!(engine.prepared_cache.max_size(), 150);
        assert!(!engine.use_columnar);
        assert!(!engine.use_compression);
        assert!(engine.plugin_registry.is_some());
    }

    #[test]
    fn test_with_columnar_compression_enabled() {
        let engine = ExecutionEngine::with_columnar(75, true);
        assert_eq!(engine.prepared_cache.max_size(), 75);
        assert!(engine.use_columnar);
        assert!(engine.use_compression);
    }

    #[test]
    fn test_with_columnar_compression_disabled() {
        let engine = ExecutionEngine::with_columnar(75, false);
        assert_eq!(engine.prepared_cache.max_size(), 75);
        assert!(engine.use_columnar);
        assert!(!engine.use_compression);
    }

    #[test]
    fn test_plugin_registry_default_has_plugins() {
        let registry = Arc::new(PluginRegistry::default());
        let engine = ExecutionEngine::with_plugin_registry(100, registry);

        engine.set_connection_string("Driver={SQL Server};Server=localhost;");
        let active_plugin = engine.active_plugin.lock().unwrap();
        assert!(active_plugin.is_some());
    }

    #[test]
    fn test_clear_cache_preserves_config() {
        let engine = ExecutionEngine::with_columnar(50, true);

        engine.prepared_cache.get_or_insert("SELECT 1");
        assert!(!engine.prepared_cache.is_empty());

        engine.clear_cache();
        assert!(engine.prepared_cache.is_empty());
        assert!(engine.use_columnar);
        assert!(engine.use_compression);
    }

    #[test]
    fn test_get_metrics_returns_same_instance() {
        let engine = ExecutionEngine::new(100);
        let metrics1 = engine.get_metrics();
        let metrics2 = engine.get_metrics();

        assert!(Arc::ptr_eq(&metrics1, &metrics2));
    }

    #[test]
    fn test_get_tracer_returns_same_instance() {
        let engine = ExecutionEngine::new(100);
        let tracer1 = engine.get_tracer();
        let tracer2 = engine.get_tracer();

        assert!(Arc::ptr_eq(&tracer1, &tracer2));
    }

    #[test]
    fn should_treat_sqlstate_02000_as_no_more_results() {
        let err = OdbcError::Structured {
            sqlstate: [b'0', b'2', b'0', b'0', b'0'],
            native_code: 0,
            message: "no data".to_string(),
        };
        assert!(is_no_more_results(&err));
    }

    #[test]
    fn should_not_treat_unrelated_errors_as_no_more_results() {
        assert!(!is_no_more_results(&OdbcError::ValidationError(
            "x".to_string()
        )));
        assert!(!is_no_more_results(&OdbcError::OdbcApi("fail".to_string())));
        let err = OdbcError::Structured {
            sqlstate: [b'4', b'2', b'S', b'0', b'2'],
            native_code: 18456,
            message: "login failed".to_string(),
        };
        assert!(!is_no_more_results(&err));
    }

    #[test]
    fn should_leave_sql_unchanged_when_no_plugin_is_active() {
        let engine = ExecutionEngine::new(10);
        assert_eq!(
            engine.test_optimize_sql("SELECT * FROM t", None),
            "SELECT * FROM t"
        );
    }

    #[test]
    fn should_apply_plugin_query_optimization_when_plugin_is_provided() {
        let engine = ExecutionEngine::new(10);
        let plugin = SqlServerPlugin::new();
        let optimized = engine.test_optimize_sql("SELECT * FROM t", Some(&plugin));
        assert!(optimized.contains("TOP 1000"));
    }

    #[test]
    fn should_map_sql_type_via_plugin_when_plugin_is_provided() {
        let engine = ExecutionEngine::new(10);
        let plugin = SqlServerPlugin::new();
        assert_eq!(
            engine.test_map_sql_type(4, Some(&plugin)),
            OdbcType::Integer
        );
        assert_eq!(
            engine.test_map_sql_type(4, None),
            OdbcType::from_odbc_sql_type(4)
        );
    }

    #[test]
    fn should_report_oracle_plugin_active_only_after_oracle_connection_string() {
        let engine = ExecutionEngine::new(10);
        assert!(!engine.test_is_oracle_plugin_active());
        engine.set_connection_string("Driver={Oracle};Server=localhost;");
        assert!(engine.test_is_oracle_plugin_active());
        engine.set_connection_string("Driver={SQL Server};Server=localhost;");
        assert!(!engine.test_is_oracle_plugin_active());
    }

    #[test]
    fn should_reject_ref_cursor_out_when_oracle_plugin_is_not_active() {
        let bound = [BoundParam {
            direction: ParamDirection::Output,
            value: ParamValue::RefCursorOut,
        }];
        let err = ensure_ref_cursor_oracle_only(&bound, false)
            .expect_err("ref cursor without oracle should fail");
        let OdbcError::ValidationError(msg) = err else {
            panic!("expected ValidationError, got {err:?}");
        };
        assert!(msg.contains("ref_cursor_out_oracle_only"), "{msg}");
    }

    #[test]
    fn should_allow_ref_cursor_gate_when_oracle_plugin_is_active() {
        let bound = [BoundParam {
            direction: ParamDirection::Output,
            value: ParamValue::RefCursorOut,
        }];
        ensure_ref_cursor_oracle_only(&bound, true).expect("oracle active should pass gate");
    }

    #[test]
    fn should_skip_ref_cursor_gate_when_no_ref_cursor_markers() {
        let bound = [BoundParam {
            direction: ParamDirection::Input,
            value: ParamValue::Integer(1),
        }];
        ensure_ref_cursor_oracle_only(&bound, false).expect("no ref cursor should pass gate");
    }

    #[test]
    fn should_not_treat_internal_or_odbc_api_errors_as_no_more_results() {
        assert!(!is_no_more_results(&OdbcError::InternalError(
            "x".to_string()
        )));
        assert!(!is_no_more_results(&OdbcError::OdbcApi(
            "SQL_NO_DATA".to_string()
        )));
    }

    #[test]
    fn should_plan_direct_query_when_params_are_empty() {
        assert_eq!(
            plan_query_param_binding(&[]).expect("empty query plan"),
            QueryParamBindingPlan::DirectNoParams
        );
    }

    #[test]
    fn should_plan_standard_query_for_non_null_params() {
        let params = vec![ParamValue::Integer(1), ParamValue::String("x".to_string())];
        assert_eq!(
            plan_query_param_binding(&params).expect("standard query plan"),
            QueryParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_plan_inference_query_for_homogeneous_nullable_integers() {
        let params = vec![ParamValue::Integer(1), ParamValue::Null];
        assert_eq!(
            plan_query_param_binding(&params).expect("inference query plan"),
            QueryParamBindingPlan::InferenceExecute
        );
    }

    #[test]
    fn should_plan_null_aware_query_when_null_types_are_mixed() {
        let params = vec![
            ParamValue::String("a".to_string()),
            ParamValue::Integer(1),
            ParamValue::Null,
        ];
        assert_eq!(
            plan_query_param_binding(&params).expect("null-aware query plan"),
            QueryParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_plan_multi_result_inference_for_homogeneous_integer_params() {
        let params = vec![ParamValue::Integer(1), ParamValue::Integer(2)];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("multi inference plan"),
            MultiResultParamBindingPlan::InferencePrealloc
        );
    }

    #[test]
    fn should_plan_multi_result_standard_for_non_null_mixed_params() {
        let params = vec![ParamValue::String("a".to_string()), ParamValue::Integer(1)];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("multi standard plan"),
            MultiResultParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_plan_multi_result_null_aware_for_null_params_without_inference() {
        let params = vec![
            ParamValue::String("a".to_string()),
            ParamValue::Integer(1),
            ParamValue::Null,
        ];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("multi null-aware plan"),
            MultiResultParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_plan_multi_result_standard_for_empty_params() {
        assert_eq!(
            plan_multi_result_param_binding(&[]).expect("empty multi plan"),
            MultiResultParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_activate_mariadb_plugin_from_connection_string() {
        let engine = ExecutionEngine::new(10);
        engine.set_connection_string("Driver={MariaDB};Server=localhost;Database=test;");
        let active = engine.active_plugin.lock().unwrap();
        assert!(active.is_some());
        assert_eq!(active.as_ref().unwrap().name(), "mariadb");
    }

    #[test]
    fn should_activate_mysql_plugin_from_connection_string() {
        let engine = ExecutionEngine::new(10);
        engine.set_connection_string("Driver={MySQL ODBC 8.0 Driver};Server=localhost;");
        let active = engine.active_plugin.lock().unwrap();
        assert!(active.is_some());
        assert_eq!(active.as_ref().unwrap().name(), "mysql");
    }

    #[test]
    fn should_apply_mariadb_limit_optimization_when_plugin_active() {
        let engine = ExecutionEngine::new(10);
        let plugin = MariaDbPlugin::new();
        let optimized = engine.test_optimize_sql("SELECT * FROM users", Some(&plugin));
        assert!(optimized.contains("LIMIT 1000"), "{optimized}");
    }

    #[test]
    fn should_map_postgres_type_via_plugin() {
        let engine = ExecutionEngine::new(10);
        let plugin = PostgresPlugin::new();
        assert_eq!(
            engine.test_map_sql_type(4, Some(&plugin)),
            OdbcType::Integer
        );
        assert_eq!(
            engine.test_map_sql_type(999, Some(&plugin)),
            OdbcType::Varchar
        );
    }

    #[test]
    fn should_map_odbc_row_count_none_to_zero() {
        assert_eq!(odbc_row_count_i64(None), 0);
        assert_eq!(odbc_row_count_i64(Some(0)), 0);
        assert_eq!(odbc_row_count_i64(Some(42)), 42);
    }

    #[test]
    fn should_build_bound_params_first_item_as_row_count_when_no_cursor() {
        let item = bound_params_first_multi_item(false, 7, vec![1, 2, 3]);
        assert_eq!(item, MultiResultItem::RowCount(7));
    }

    #[test]
    fn should_build_bound_params_first_item_as_result_set_when_cursor_present() {
        let body = vec![9, 8, 7];
        let item = bound_params_first_multi_item(true, 0, body.clone());
        assert_eq!(item, MultiResultItem::ResultSet(body));
    }

    #[test]
    fn should_encode_empty_row_buffer_row_major() {
        let buffer = RowBuffer::new();
        let bytes = encode_query_result_payload(&buffer, false, false).expect("encode");
        assert!(!bytes.is_empty());
    }

    #[test]
    fn should_encode_empty_row_buffer_columnar_with_compression() {
        let buffer = RowBuffer::new();
        let bytes = encode_query_result_payload(&buffer, true, true).expect("encode");
        assert!(!bytes.is_empty());
    }

    #[test]
    fn should_encode_nonempty_row_buffer_row_major() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(1i32.to_le_bytes().to_vec())]);
        let bytes = encode_query_result_payload(&buffer, false, false).expect("encode");
        assert!(!bytes.is_empty());
    }

    #[test]
    fn should_not_treat_no_more_results_variant_as_sqlstate_02000() {
        assert!(!is_no_more_results(&OdbcError::NoMoreResults));
    }

    #[test]
    fn should_not_treat_structured_non_02000_as_no_more_results() {
        let err = OdbcError::Structured {
            sqlstate: [b'0', b'1', b'0', b'0', b'0'],
            native_code: 0,
            message: "general".to_string(),
        };
        assert!(!is_no_more_results(&err));
    }

    #[test]
    fn should_plan_query_standard_for_homogeneous_bigint_params_without_null() {
        let params = vec![ParamValue::BigInt(1), ParamValue::BigInt(2)];
        assert_eq!(
            plan_query_param_binding(&params).expect("bigint query plan"),
            QueryParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_plan_query_standard_for_bigint_and_string_without_null() {
        let params = vec![ParamValue::BigInt(1), ParamValue::String("x".to_string())];
        assert_eq!(
            plan_query_param_binding(&params).expect("mixed query plan"),
            QueryParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_plan_multi_result_inference_for_nullable_bigint_params() {
        let params = vec![ParamValue::BigInt(9), ParamValue::Null];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("nullable bigint multi"),
            MultiResultParamBindingPlan::InferencePrealloc
        );
    }

    #[test]
    fn should_plan_multi_result_inference_for_mixed_integer_and_bigint() {
        let params = vec![ParamValue::Integer(1), ParamValue::BigInt(2)];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("promoted multi"),
            MultiResultParamBindingPlan::InferencePrealloc
        );
    }

    #[test]
    fn should_plan_multi_result_inference_for_string_and_null_same_family() {
        let params = vec![ParamValue::String("a".to_string()), ParamValue::Null];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("string+null multi"),
            MultiResultParamBindingPlan::InferencePrealloc
        );
    }

    #[test]
    fn should_plan_query_inference_for_nullable_bigint_params() {
        let params = vec![ParamValue::BigInt(9), ParamValue::Null];
        assert_eq!(
            plan_query_param_binding(&params).expect("nullable bigint query"),
            QueryParamBindingPlan::InferenceExecute
        );
    }

    #[test]
    fn should_plan_query_null_aware_for_all_null_without_inference_family() {
        let params = vec![ParamValue::Null, ParamValue::Null];
        assert_eq!(
            plan_query_param_binding(&params).expect("all-null query"),
            QueryParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_plan_multi_result_null_aware_for_all_null_without_inference() {
        let params = vec![ParamValue::Null];
        assert_eq!(
            plan_multi_result_param_binding(&params).expect("single null multi"),
            MultiResultParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_map_negative_odbc_row_count_none_to_zero() {
        assert_eq!(odbc_row_count_i64(None), 0);
    }

    #[test]
    fn should_encode_columnar_payload_with_multiple_rows() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("n".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(1i32.to_le_bytes().to_vec())]);
        buffer.add_row(vec![Some(2i32.to_le_bytes().to_vec())]);
        let bytes = encode_query_result_payload(&buffer, true, false).expect("columnar encode");
        assert!(!bytes.is_empty());
        let row_major = encode_query_result_payload(&buffer, false, false).expect("row-major");
        assert_ne!(bytes, row_major);
    }

    #[test]
    fn should_apply_postgres_limit_optimization_when_plugin_provided() {
        let engine = ExecutionEngine::new(10);
        let plugin = PostgresPlugin::new();
        let optimized = engine.test_optimize_sql("SELECT * FROM t", Some(&plugin));
        assert!(optimized.contains("LIMIT"), "{optimized}");
    }

    #[test]
    fn should_reject_ref_cursor_inout_when_oracle_inactive() {
        let bound = [BoundParam {
            direction: ParamDirection::InOut,
            value: ParamValue::RefCursorOut,
        }];
        let err = ensure_ref_cursor_oracle_only(&bound, false).expect_err("inout ref cursor");
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }
}
