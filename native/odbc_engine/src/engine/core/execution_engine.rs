use super::prepared_cache::PreparedStatementCache;
use crate::engine::cell_reader::read_cell_bytes;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;
use crate::observability::{Metrics, SpanGuard, StructuredLogger, Tracer};
use crate::plugins::{DriverPlugin, PluginRegistry};
use crate::protocol::bound_param::BoundParam;
use crate::protocol::{
    encode_multi, row_buffer_to_columnar, ColumnarEncoder, MultiResultItem, OdbcType, ParamValue,
    RowBuffer, RowBufferEncoder,
};
use crate::security::AuditLogger;
use log::Level;
use odbc_api::handles::{AsStatementRef, SqlResult, Statement};
use odbc_api::{Connection, Cursor, CursorImpl, IntoParameter, ResultSetMetadata};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Returns true when the underlying ODBC error means "no more result sets",
/// i.e. SQLSTATE 02000 ("no data") which corresponds to the SQL_NO_DATA return code.
///
/// Replaces the previous `e.to_string().contains("SQL_NO_DATA")` heuristic (A13).
fn is_no_more_results(err: &OdbcError) -> bool {
    let s = err.sqlstate();
    // SQLSTATE 02000 = "no data" (SQL_NO_DATA)
    s == [b'0', b'2', b'0', b'0', b'0']
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
        let optimized_sql = if let Ok(active) = self.active_plugin.lock() {
            if let Some(ref plugin) = *active {
                plugin.optimize_query(sql)
            } else {
                sql.to_string()
            }
        } else {
            sql.to_string()
        };

        self.prepared_cache.get_or_insert(&optimized_sql);

        let mut stmt = conn.prepare(&optimized_sql).map_err(OdbcError::from)?;

        let cursor = stmt.execute(()).map_err(OdbcError::from)?;

        let mut row_buffer = RowBuffer::new();

        if let Some(mut cursor) = cursor {
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
                let odbc_type = if let Ok(active) = self.active_plugin.lock() {
                    if let Some(ref plugin) = *active {
                        plugin.map_type(sql_type_code)
                    } else {
                        OdbcType::from_odbc_sql_type(sql_type_code)
                    }
                } else {
                    OdbcType::from_odbc_sql_type(sql_type_code)
                };
                row_buffer.add_column(col_name.to_string(), odbc_type);
                column_types.push(odbc_type);
            }

            while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                let mut row_data = Vec::new();

                for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                    let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column number".to_string())
                    })?;

                    let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;

                    row_data.push(cell_data);
                }

                row_buffer.add_row(row_data);
            }
        }

        // Reassemble SQL Server FOR JSON multi-row chunks into a single
        // logical cell. No-op for any other result shape. See
        // `engine::sqlserver_json` for the rationale (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        if self.use_columnar {
            let columnar_buffer = row_buffer_to_columnar(&row_buffer);
            ColumnarEncoder::encode(&columnar_buffer, self.use_compression)
        } else {
            Ok(RowBufferEncoder::encode(&row_buffer))
        }
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

        let optimized_sql = if let Ok(active) = self.active_plugin.lock() {
            if let Some(ref plugin) = *active {
                plugin.optimize_query(sql)
            } else {
                sql.to_string()
            }
        } else {
            sql.to_string()
        };

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

            if bound_has_ref_cursor(bound) {
                if !self.is_oracle_plugin_active() {
                    return Err(OdbcError::ValidationError(
                        "DIRECTED_PARAM|ref_cursor_out_oracle_only: ParamValue::RefCursorOut is \
                         only supported with the Oracle ODBC driver; see \
                         doc/notes/REF_CURSOR_ORACLE_ROADMAP.md"
                            .to_string(),
                    ));
                }
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
            // Keep the cursor binding adjacent to the `if let` that consumes it. Any `let` in
            // between (e.g. `row_buffer`) can extend the borrow in NLL to the end of the outer
            // closure, blocking `row_count` / `more_results` on the same `Preallocated` handle.
            let had_initial_cursor = {
                let initial_cursor = prealloc
                    .execute(sql, &mut odbc_params)
                    .map_err(OdbcError::from)?;
                if let Some(mut cursor) = initial_cursor {
                    let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
                    let cols_u16: u16 = cols_i16.try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column count".to_string())
                    })?;
                    let cols_usize: usize = cols_u16.into();

                    let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

                    for col_idx in 1..=cols_u16 {
                        let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
                        let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
                        let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
                        let odbc_type = if let Ok(active) = self.active_plugin.lock() {
                            if let Some(ref plugin) = *active {
                                plugin.map_type(sql_type_code)
                            } else {
                                OdbcType::from_odbc_sql_type(sql_type_code)
                            }
                        } else {
                            OdbcType::from_odbc_sql_type(sql_type_code)
                        };
                        row_buffer.add_column(col_name.to_string(), odbc_type);
                        column_types.push(odbc_type);
                    }

                    while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                        let mut row_data = Vec::new();

                        for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                            let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                                OdbcError::InternalError("Invalid column number".to_string())
                            })?;

                            let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;

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
                Some(
                    prealloc
                        .row_count()
                        .map_err(OdbcError::from)?
                        .map(|n| n as i64)
                        .unwrap_or(0),
                )
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
                let body = if self.use_columnar {
                    let columnar_buffer = row_buffer_to_columnar(&row_buffer);
                    ColumnarEncoder::encode(&columnar_buffer, self.use_compression)?
                } else {
                    RowBufferEncoder::encode(&row_buffer)
                };
                Ok(RowBufferEncoder::append_output_footer(body, &out_vals))
            } else {
                // Multi-result path: wrap every item in a MULT envelope, then append OUT1.
                // The first logical item is a RowCount when the initial execute returned no
                // cursor, or a ResultSet when it did.
                let first_item = if let Some(rc) = initial_rc {
                    MultiResultItem::RowCount(rc)
                } else {
                    let first_body = if self.use_columnar {
                        let columnar_buffer = row_buffer_to_columnar(&row_buffer);
                        ColumnarEncoder::encode(&columnar_buffer, self.use_compression)?
                    } else {
                        RowBufferEncoder::encode(&row_buffer)
                    };
                    MultiResultItem::ResultSet(first_body)
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
        let optional_strings = crate::protocol::param_values_to_strings(params)?;

        let cursor = match optional_strings.len() {
            0 => conn
                .execute(sql, (), timeout_sec)
                .map_err(OdbcError::from)?,
            1 => {
                let p0 = optional_strings[0].as_deref().into_parameter();
                conn.execute(sql, (&p0,), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            2 => {
                let p0 = optional_strings[0].as_deref().into_parameter();
                let p1 = optional_strings[1].as_deref().into_parameter();
                conn.execute(sql, (&p0, &p1), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            3 => {
                let p0 = optional_strings[0].as_deref().into_parameter();
                let p1 = optional_strings[1].as_deref().into_parameter();
                let p2 = optional_strings[2].as_deref().into_parameter();
                conn.execute(sql, (&p0, &p1, &p2), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            4 => {
                let p0 = optional_strings[0].as_deref().into_parameter();
                let p1 = optional_strings[1].as_deref().into_parameter();
                let p2 = optional_strings[2].as_deref().into_parameter();
                let p3 = optional_strings[3].as_deref().into_parameter();
                conn.execute(sql, (&p0, &p1, &p2, &p3), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            5 => {
                let p0 = optional_strings[0].as_deref().into_parameter();
                let p1 = optional_strings[1].as_deref().into_parameter();
                let p2 = optional_strings[2].as_deref().into_parameter();
                let p3 = optional_strings[3].as_deref().into_parameter();
                let p4 = optional_strings[4].as_deref().into_parameter();
                conn.execute(sql, (&p0, &p1, &p2, &p3, &p4), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            n => {
                return Err(OdbcError::ValidationError(format!(
                    "At most 5 parameters supported, got {}. \
                    For more parameters or proper NULL handling, \
                    use bulk insert operations or direct prepared statements.",
                    n
                )))
            }
        };

        let mut row_buffer = RowBuffer::new();

        if let Some(mut cursor) = cursor {
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
                let odbc_type = if let Ok(active) = self.active_plugin.lock() {
                    if let Some(ref plugin) = *active {
                        plugin.map_type(sql_type_code)
                    } else {
                        OdbcType::from_odbc_sql_type(sql_type_code)
                    }
                } else {
                    OdbcType::from_odbc_sql_type(sql_type_code)
                };
                row_buffer.add_column(col_name.to_string(), odbc_type);
                column_types.push(odbc_type);
            }

            while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                let mut row_data = Vec::new();

                for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                    let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column number".to_string())
                    })?;

                    let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;

                    row_data.push(cell_data);
                }

                row_buffer.add_row(row_data);
            }
        }

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        if self.use_columnar {
            let columnar_buffer = row_buffer_to_columnar(&row_buffer);
            ColumnarEncoder::encode(&columnar_buffer, self.use_compression)
        } else {
            Ok(RowBufferEncoder::encode(&row_buffer))
        }
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
    /// Same wire format as [`execute_multi_result`]; supports up to 5 params
    /// (M5 in v3.2.0).
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
            let rc = stmt
                .row_count()
                .map_err(OdbcError::from)?
                .map(|n| n as i64)
                .unwrap_or(0);
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
        let optional_strings = crate::protocol::param_values_to_strings(params)?;
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let mut all_items: Vec<MultiResultItem> = Vec::new();

        let had_initial_cursor = {
            let initial_cursor = match optional_strings.len() {
                0 => stmt.execute(()).map_err(OdbcError::from)?,
                1 => {
                    let p0 = optional_strings[0].as_deref().into_parameter();
                    stmt.execute((&p0,)).map_err(OdbcError::from)?
                }
                2 => {
                    let p0 = optional_strings[0].as_deref().into_parameter();
                    let p1 = optional_strings[1].as_deref().into_parameter();
                    stmt.execute((&p0, &p1)).map_err(OdbcError::from)?
                }
                3 => {
                    let p0 = optional_strings[0].as_deref().into_parameter();
                    let p1 = optional_strings[1].as_deref().into_parameter();
                    let p2 = optional_strings[2].as_deref().into_parameter();
                    stmt.execute((&p0, &p1, &p2)).map_err(OdbcError::from)?
                }
                4 => {
                    let p0 = optional_strings[0].as_deref().into_parameter();
                    let p1 = optional_strings[1].as_deref().into_parameter();
                    let p2 = optional_strings[2].as_deref().into_parameter();
                    let p3 = optional_strings[3].as_deref().into_parameter();
                    stmt.execute((&p0, &p1, &p2, &p3))
                        .map_err(OdbcError::from)?
                }
                5 => {
                    let p0 = optional_strings[0].as_deref().into_parameter();
                    let p1 = optional_strings[1].as_deref().into_parameter();
                    let p2 = optional_strings[2].as_deref().into_parameter();
                    let p3 = optional_strings[3].as_deref().into_parameter();
                    let p4 = optional_strings[4].as_deref().into_parameter();
                    stmt.execute((&p0, &p1, &p2, &p3, &p4))
                        .map_err(OdbcError::from)?
                }
                n => {
                    return Err(OdbcError::ValidationError(format!(
                        "At most 5 parameters supported in execute_multi_result_with_params, \
                         got {}",
                        n
                    )))
                }
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
            let rc = stmt
                .row_count()
                .map_err(OdbcError::from)?
                .map(|n| n as i64)
                .unwrap_or(0);
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
        let main_body = if self.use_columnar {
            let columnar_buffer = row_buffer_to_columnar(&main_buffer);
            ColumnarEncoder::encode(&columnar_buffer, self.use_compression)?
        } else {
            RowBufferEncoder::encode(&main_buffer)
        };
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
        let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_u16 as usize);
        for col_idx in 1..=cols_u16 {
            let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = if let Ok(active) = self.active_plugin.lock() {
                if let Some(ref plugin) = *active {
                    plugin.map_type(sql_type_code)
                } else {
                    OdbcType::from_odbc_sql_type(sql_type_code)
                }
            } else {
                OdbcType::from_odbc_sql_type(sql_type_code)
            };
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::new();
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                row_data.push(read_cell_bytes(&mut row, col_number, odbc_type)?);
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
            let odbc_type = if let Ok(active) = self.active_plugin.lock() {
                if let Some(ref plugin) = *active {
                    plugin.map_type(sql_type_code)
                } else {
                    OdbcType::from_odbc_sql_type(sql_type_code)
                }
            } else {
                OdbcType::from_odbc_sql_type(sql_type_code)
            };
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::new();
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;
                row_data.push(cell_data);
            }
            row_buffer.add_row(row_data);
        }

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        if self.use_columnar {
            let columnar_buffer = row_buffer_to_columnar(&row_buffer);
            ColumnarEncoder::encode(&columnar_buffer, self.use_compression)
        } else {
            Ok(RowBufferEncoder::encode(&row_buffer))
        }
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugins::PluginRegistry;

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
}
