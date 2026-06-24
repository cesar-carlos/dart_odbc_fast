mod multi_result_collect;
mod param_binding;
pub(crate) mod result_encoding;

use super::prepared_cache::PreparedStatementCache;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;
use crate::observability::{Metrics, SpanGuard, StructuredLogger, Tracer};
use crate::plugins::{DriverPlugin, PluginRegistry};
use crate::protocol::bound_param::BoundParam;
use crate::protocol::{
    param_values_to_input_params, param_values_to_input_params_with_descriptions, try_encode_multi,
    MultiResultItem, ParamValue, RowBuffer, RowBufferEncoder,
};
use crate::security::AuditLogger;
use log::Level;
use odbc_api::Connection;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

#[cfg(test)]
use multi_result_collect::is_no_more_results;
use multi_result_collect::{bound_params_first_multi_item, odbc_row_count_i64};
use param_binding::{
    ensure_ref_cursor_oracle_only, plan_query_param_binding, require_inference_input_params,
    QueryParamBindingPlan,
};
#[cfg(test)]
use param_binding::{plan_multi_result_param_binding, MultiResultParamBindingPlan};
use result_encoding::encode_query_result_payload;

pub struct ExecutionEngine {
    prepared_cache: Arc<PreparedStatementCache>,
    use_columnar: bool,
    use_compression: bool,
    plugin_registry: Option<Arc<PluginRegistry>>,
    /// Per-query reads dominate writes (writes only happen on
    /// `set_connection_string`, reads on every execute). An `RwLock`
    /// lets concurrent queries observe the active plugin without
    /// serialising on a `Mutex` (sprint 1 follow-up B7).
    active_plugin: Arc<RwLock<Option<Arc<dyn DriverPlugin>>>>,
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
            active_plugin: Arc::new(RwLock::new(None)),
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
            active_plugin: Arc::new(RwLock::new(None)),
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
            active_plugin: Arc::new(RwLock::new(None)),
            metrics,
            tracer: Arc::new(Tracer::new()),
            logger: Arc::new(StructuredLogger::default()),
            audit_logger: Arc::new(AuditLogger::default()),
        }
    }

    pub fn set_connection_string(&self, connection_string: &str) {
        if let Some(ref registry) = self.plugin_registry {
            if let Some(plugin) = registry.get_for_connection(connection_string) {
                if let Ok(mut active) = self.active_plugin.write() {
                    *active = Some(plugin);
                }
            }
        }
    }

    /// Starts a tracing span and emits a `log_query` event **only when the
    /// structured logger would actually record it** at `Level::Info`.
    ///
    /// This is the hot path entry hook. The previous implementation always
    /// allocated `sql.to_string()`, locked the tracer mutex twice (start
    /// plus drop), built a `HashMap<String, String>` and inserted the span
    /// id per query, even when no observer was consuming the events.
    ///
    /// Returning `Option<SpanGuard>` keeps the RAII semantics: when logging
    /// is enabled the guard is bound by the caller via `let _span = ...`
    /// and `Drop` cleans up; when disabled, we return `None` and skip every
    /// allocation.
    fn log_query_start(&self, sql: &str) -> Option<SpanGuard> {
        if !self.logger.is_enabled(Level::Info) {
            return None;
        }
        let span = SpanGuard::new(Arc::clone(&self.tracer), sql.to_string());
        let mut metadata = HashMap::with_capacity(1);
        metadata.insert("span_id".to_string(), span.span_id().to_string());
        self.logger.log_query(Level::Info, sql, &metadata);
        Some(span)
    }

    pub fn execute_query(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        use std::time::Instant;
        let start_time = Instant::now();
        let _span = self.log_query_start(sql);

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
        let _span = self.log_query_start(sql);

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
        let _span = self.log_query_start(sql);

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
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        use std::time::Instant;

        use super::output_aware_params::bound_to_slots;
        let start_time = Instant::now();
        let _span = self.log_query_start(sql);

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
                    let cursor = crate::engine::fetch::fetch_cursor_into_row_buffer(
                        cursor,
                        &column_types,
                        &mut row_buffer,
                        crate::engine::core::execution::result_encoding::resolve_batch_size(
                            fetch_size,
                        ),
                        None,
                    )?;
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
                // Fast path: single result set â€” preserve the original wire format.
                let body = encode_query_result_payload(
                    row_buffer,
                    self.use_columnar,
                    self.use_compression,
                )?;
                RowBufferEncoder::append_output_footer_result(body, &out_vals)
            } else {
                // Multi-result path: wrap every item in a MULT envelope, then append OUT1.
                let first_body = encode_query_result_payload(
                    row_buffer,
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
                let multi_body = try_encode_multi(&all_items)?;
                RowBufferEncoder::append_output_footer_result(multi_body, &out_vals)
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
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        let plugin = self.current_plugin();
        match plan_query_param_binding(params)? {
            QueryParamBindingPlan::DirectNoParams => {
                let cursor = conn
                    .execute(sql, (), timeout_sec)
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor_with_fetch_size(cursor, plugin.as_deref(), fetch_size)
            }
            QueryParamBindingPlan::InferenceExecute => {
                let parameters = require_inference_input_params(params)?;
                let cursor = conn
                    .execute(sql, parameters.as_slice(), timeout_sec)
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor_with_fetch_size(cursor, plugin.as_deref(), fetch_size)
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
                self.encode_optional_cursor_with_fetch_size(cursor, plugin.as_deref(), fetch_size)
            }
            QueryParamBindingPlan::PreparedStandard => {
                let parameters = param_values_to_input_params(params)?;
                let cursor = conn
                    .execute(sql, parameters.as_slice(), timeout_sec)
                    .map_err(OdbcError::from)?;
                self.encode_optional_cursor_with_fetch_size(cursor, plugin.as_deref(), fetch_size)
            }
        }

        // FOR JSON normalisation â€” see execute_query_inner above (closes #2).
    }

    pub fn execute_multi_result(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let _span = self.log_query_start(sql);

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
        let _span = self.log_query_start(sql);

        let result = self.execute_multi_result_with_params_inner(conn, sql, params);

        self.metrics.record_query(start_time.elapsed());

        if let Err(ref e) = result {
            self.metrics.record_error();
            self.audit_logger.log_error(None, &e.to_string());
        }

        result
    }

    fn is_oracle_plugin_active(&self) -> bool {
        self.active_plugin
            .read()
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
            encode_query_result_payload(main_buffer, self.use_columnar, self.use_compression)?;
        let body = RowBufferEncoder::append_output_footer_result(main_body, &out_vals)?;
        RowBufferEncoder::append_ref_cursor_footer_result(body, &ref_blobs)
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

    pub(super) fn current_plugin(&self) -> Option<Arc<dyn DriverPlugin>> {
        self.active_plugin
            .read()
            .ok()
            .and_then(|guard| guard.clone())
    }

    fn optimize_sql_with_plugin(&self, sql: &str, plugin: Option<&dyn DriverPlugin>) -> String {
        plugin
            .map(|active| active.optimize_query(sql))
            .unwrap_or_else(|| sql.to_string())
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
    ) -> crate::protocol::OdbcType {
        plugin
            .map(|active| active.map_type(code))
            .unwrap_or_else(|| crate::protocol::OdbcType::from_odbc_sql_type(code))
    }

    pub(crate) fn test_is_oracle_plugin_active(&self) -> bool {
        self.is_oracle_plugin_active()
    }
}

#[cfg(test)]
mod tests;
