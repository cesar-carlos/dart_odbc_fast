use super::prepared_cache::PreparedStatementCache;
use crate::engine::cell_reader::read_cell_bytes;
use crate::error::{OdbcError, Result};
use crate::observability::{Metrics, StructuredLogger, Tracer};
use crate::plugins::{DriverPlugin, PluginRegistry};
use crate::protocol::{
    encode_multi, row_buffer_to_columnar, ColumnarEncoder, MultiResultItem, OdbcType, ParamValue,
    RowBuffer, RowBufferEncoder,
};
use crate::security::AuditLogger;
use log::Level;
use odbc_api::{Connection, Cursor, IntoParameter, ResultSetMetadata};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

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
        Self {
            prepared_cache: Arc::new(PreparedStatementCache::new(cache_size)),
            use_columnar: false,
            use_compression: false,
            plugin_registry: Some(Arc::new(PluginRegistry::default())),
            active_plugin: Arc::new(Mutex::new(None)),
            metrics: Arc::new(Metrics::new()),
            tracer: Arc::new(Tracer::new()),
            logger: Arc::new(StructuredLogger::default()),
            audit_logger: Arc::new(AuditLogger::default()),
        }
    }

    pub fn with_columnar(cache_size: usize, use_compression: bool) -> Self {
        Self {
            prepared_cache: Arc::new(PreparedStatementCache::new(cache_size)),
            use_columnar: true,
            use_compression,
            plugin_registry: Some(Arc::new(PluginRegistry::default())),
            active_plugin: Arc::new(Mutex::new(None)),
            metrics: Arc::new(Metrics::new()),
            tracer: Arc::new(Tracer::new()),
            logger: Arc::new(StructuredLogger::default()),
            audit_logger: Arc::new(AuditLogger::default()),
        }
    }

    pub fn with_plugin_registry(cache_size: usize, registry: Arc<PluginRegistry>) -> Self {
        Self {
            prepared_cache: Arc::new(PreparedStatementCache::new(cache_size)),
            use_columnar: false,
            use_compression: false,
            plugin_registry: Some(registry),
            active_plugin: Arc::new(Mutex::new(None)),
            metrics: Arc::new(Metrics::new()),
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
        let span_id = self.tracer.start_span(sql.to_string());
        let mut metadata = HashMap::new();
        metadata.insert("span_id".to_string(), span_id.to_string());
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

        let result = if self.use_columnar {
            let columnar_buffer = row_buffer_to_columnar(&row_buffer);
            ColumnarEncoder::encode(&columnar_buffer, self.use_compression)
        } else {
            Ok(RowBufferEncoder::encode(&row_buffer))
        };

        let latency = start_time.elapsed();
        self.metrics.record_query(latency);

        if let Some(span) = self.tracer.finish_span(span_id) {
            if let Some(duration) = span.duration() {
                log::debug!("Query completed in {}ms", duration.as_millis());
            }
        }

        if result.is_err() {
            self.metrics.record_error();
            if let Err(ref e) = result {
                self.audit_logger.log_error(None, &e.to_string());
            }
        }

        result
    }

    pub fn execute_query_with_params(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        self.execute_query_with_params_and_timeout(conn, sql, params, None)
    }

    pub fn execute_query_with_params_and_timeout(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
        timeout_sec: Option<usize>,
    ) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let span_id = self.tracer.start_span(sql.to_string());
        let mut metadata = std::collections::HashMap::new();
        metadata.insert("span_id".to_string(), span_id.to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let strings = crate::protocol::param_values_to_strings(params)?;

        let cursor = match strings.len() {
            0 => conn
                .execute(sql, (), timeout_sec)
                .map_err(OdbcError::from)?,
            1 => {
                let p0 = strings[0].as_str().into_parameter();
                conn.execute(sql, (&p0,), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            2 => {
                let p0 = strings[0].as_str().into_parameter();
                let p1 = strings[1].as_str().into_parameter();
                conn.execute(sql, (&p0, &p1), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            3 => {
                let p0 = strings[0].as_str().into_parameter();
                let p1 = strings[1].as_str().into_parameter();
                let p2 = strings[2].as_str().into_parameter();
                conn.execute(sql, (&p0, &p1, &p2), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            4 => {
                let p0 = strings[0].as_str().into_parameter();
                let p1 = strings[1].as_str().into_parameter();
                let p2 = strings[2].as_str().into_parameter();
                let p3 = strings[3].as_str().into_parameter();
                conn.execute(sql, (&p0, &p1, &p2, &p3), timeout_sec)
                    .map_err(OdbcError::from)?
            }
            5 => {
                let p0 = strings[0].as_str().into_parameter();
                let p1 = strings[1].as_str().into_parameter();
                let p2 = strings[2].as_str().into_parameter();
                let p3 = strings[3].as_str().into_parameter();
                let p4 = strings[4].as_str().into_parameter();
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

        let result = if self.use_columnar {
            let columnar_buffer = row_buffer_to_columnar(&row_buffer);
            ColumnarEncoder::encode(&columnar_buffer, self.use_compression)
        } else {
            Ok(RowBufferEncoder::encode(&row_buffer))
        };

        self.metrics.record_query(start_time.elapsed());

        if let Some(span) = self.tracer.finish_span(span_id) {
            if let Some(duration) = span.duration() {
                log::debug!("Query with params completed in {}ms", duration.as_millis());
            }
        }

        if result.is_err() {
            self.metrics.record_error();
            if let Err(ref e) = result {
                self.audit_logger.log_error(None, &e.to_string());
            }
        }

        result
    }

    pub fn execute_multi_result(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        use std::time::Instant;

        let start_time = Instant::now();
        let span_id = self.tracer.start_span(sql.to_string());
        let mut metadata = HashMap::new();
        metadata.insert("span_id".to_string(), span_id.to_string());
        self.logger.log_query(Level::Info, sql, &metadata);

        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;

        // Collect all result sets using SQLMoreResults
        let mut all_items = Vec::new();

        // Execute first result set
        let mut cursor_opt = stmt.execute(()).map_err(OdbcError::from)?;

        // Process each result set (cursor or row count)
        loop {
            use crate::protocol::{ColumnarEncoder, RowBuffer, RowBufferEncoder};

            let item = if let Some(ref mut c) = cursor_opt {
                // Has cursor - process as ResultSet
                let mut row_buffer = RowBuffer::new();
                let cols_i16 = c.num_result_cols().map_err(OdbcError::from)?;
                let cols_u16: u16 = cols_i16
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
                let cols_usize: usize = cols_u16.into();
                let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

                for col_idx in 1..=cols_u16 {
                    let col_name = c.col_name(col_idx).map_err(OdbcError::from)?;
                    let col_type = c.col_data_type(col_idx).map_err(OdbcError::from)?;
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

                while let Some(mut row) = c.next_row().map_err(OdbcError::from)? {
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

                let encoded = if self.use_columnar {
                    let columnar_buffer = crate::protocol::row_buffer_to_columnar(&row_buffer);
                    ColumnarEncoder::encode(&columnar_buffer, self.use_compression)?
                } else {
                    RowBufferEncoder::encode(&row_buffer)
                };
                MultiResultItem::ResultSet(encoded)
            } else {
                // No cursor - this was INSERT/UPDATE/DDL, get row count
                // We can't call stmt.row_count() here as stmt is already borrowed
                // For operations without result sets, return RowCount(0) as placeholder
                // The actual row count is already tracked by ODBC internally
                MultiResultItem::RowCount(0)
            };

            all_items.push(item);

            // Try to get next result set using SQLMoreResults
            match cursor_opt {
                Some(cursor) => {
                    match cursor.more_results() {
                        Ok(Some(next)) => {
                            cursor_opt = Some(next);
                        }
                        Ok(None) => {
                            // No more results
                            break;
                        }
                        Err(e) => {
                            // Error or SQL_NO_DATA (common when no more results)
                            let odbc_err = OdbcError::from(e);
                            if odbc_err.to_string().contains("SQL_NO_DATA")
                                || odbc_err.to_string().contains("No data")
                            {
                                break;
                            }
                            return Err(odbc_err);
                        }
                    }
                }
                None => {
                    // First result was row count (no cursor), so no more results
                    break;
                }
            }
        }

        self.metrics.record_query(start_time.elapsed());
        if let Some(span) = self.tracer.finish_span(span_id) {
            if let Some(duration) = span.duration() {
                log::debug!(
                    "Multi-result batch completed with {} result(s) in {}ms",
                    all_items.len(),
                    duration.as_millis()
                );
            }
        }

        Ok(encode_multi(&all_items))
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
