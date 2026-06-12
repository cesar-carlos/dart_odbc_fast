use super::execution::ExecutionEngine;
use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;
use crate::observability::Metrics;
use crate::protocol::ParamValue;
use odbc_api::Connection;
use std::sync::{Arc, OnceLock};

/// Default prepared-statement cache size for process-wide pipeline singletons.
pub const SHARED_PIPELINE_CACHE_SIZE: usize = 100;

/// Borrowed query plan — describes a validated SQL string without owning
/// it. Avoids one `String::from(sql)` per query in the hot path; the
/// borrowed `&str` is always the same one the caller already owns.
#[derive(Debug)]
pub struct QueryPlan<'a> {
    sql: &'a str,
    use_cache: bool,
}

impl<'a> QueryPlan<'a> {
    pub fn new(sql: &'a str) -> Self {
        Self {
            sql,
            use_cache: true,
        }
    }

    pub fn sql(&self) -> &str {
        self.sql
    }

    pub fn use_cache(&self) -> bool {
        self.use_cache
    }
}

pub struct QueryPipeline {
    execution_engine: Arc<ExecutionEngine>,
}

impl QueryPipeline {
    pub fn new(cache_size: usize) -> Self {
        Self {
            execution_engine: Arc::new(ExecutionEngine::new(cache_size)),
        }
    }

    pub fn with_columnar(cache_size: usize, use_compression: bool) -> Self {
        Self {
            execution_engine: Arc::new(ExecutionEngine::with_columnar(cache_size, use_compression)),
        }
    }

    pub fn parse_sql<'a>(&self, sql: &'a str) -> Result<QueryPlan<'a>> {
        validate_sql_not_empty(sql)?;
        Ok(QueryPlan::new(sql))
    }

    pub fn execute(&self, conn: &Connection<'static>, plan: QueryPlan<'_>) -> Result<Vec<u8>> {
        self.execution_engine.execute_query(conn, plan.sql())
    }

    pub fn execute_direct(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        let plan = self.parse_sql(sql)?;
        self.execute(conn, plan)
    }

    /// Execute SQL using cached connection (enables prepared-statement reuse when feature on).
    pub fn execute_direct_cached(
        &self,
        cached: &mut CachedConnection,
        sql: &str,
    ) -> Result<Vec<u8>> {
        validate_sql_not_empty(sql)?;
        self.execution_engine.execute_query_cached(cached, sql)
    }

    pub fn execute_with_params(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        validate_sql_not_empty(sql)?;
        self.execution_engine
            .execute_query_with_params(conn, sql, params)
    }

    pub fn execute_with_params_and_timeout(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
        timeout_sec: Option<usize>,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        validate_sql_not_empty(sql)?;
        self.execution_engine.execute_query_with_params_and_timeout(
            conn,
            sql,
            params,
            timeout_sec,
            fetch_size,
        )
    }

    pub fn execute_with_bound_params_and_timeout(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        bound: &[crate::protocol::bound_param::BoundParam],
        timeout_sec: Option<usize>,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        validate_sql_not_empty(sql)?;
        self.execution_engine
            .execute_query_with_bound_params_and_timeout(conn, sql, bound, timeout_sec, fetch_size)
    }

    pub fn execute_multi(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        validate_sql_not_empty(sql)?;
        self.execution_engine.execute_multi_result(conn, sql)
    }

    pub fn execute_multi_with_params(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[crate::protocol::ParamValue],
    ) -> Result<Vec<u8>> {
        validate_sql_not_empty(sql)?;
        self.execution_engine
            .execute_multi_result_with_params(conn, sql, params)
    }

    pub fn get_metrics(&self) -> Arc<Metrics> {
        self.execution_engine.get_metrics()
    }
}

/// Shared row-major [`QueryPipeline`] used by catalog and query entry points.
pub fn shared_row_major_pipeline() -> Arc<QueryPipeline> {
    static PIPELINE: OnceLock<Arc<QueryPipeline>> = OnceLock::new();
    Arc::clone(PIPELINE.get_or_init(|| Arc::new(QueryPipeline::new(SHARED_PIPELINE_CACHE_SIZE))))
}

/// Shared columnar pipeline (no compression).
pub fn shared_columnar_pipeline() -> Arc<QueryPipeline> {
    static PIPELINE: OnceLock<Arc<QueryPipeline>> = OnceLock::new();
    Arc::clone(PIPELINE.get_or_init(|| {
        Arc::new(QueryPipeline::with_columnar(
            SHARED_PIPELINE_CACHE_SIZE,
            false,
        ))
    }))
}

/// Shared columnar pipeline with compression enabled.
pub fn shared_columnar_compressed_pipeline() -> Arc<QueryPipeline> {
    static PIPELINE: OnceLock<Arc<QueryPipeline>> = OnceLock::new();
    Arc::clone(PIPELINE.get_or_init(|| {
        Arc::new(QueryPipeline::with_columnar(
            SHARED_PIPELINE_CACHE_SIZE,
            true,
        ))
    }))
}

fn validate_sql_not_empty(sql: &str) -> Result<()> {
    if sql.trim().is_empty() {
        return Err(OdbcError::ValidationError(
            "SQL query cannot be empty".to_string(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_plan_new() {
        let plan = QueryPlan::new("SELECT 1");
        assert_eq!(plan.sql(), "SELECT 1");
        assert!(plan.use_cache());
    }

    #[test]
    fn test_query_plan_sql() {
        let plan = QueryPlan::new("SELECT * FROM users");
        assert_eq!(plan.sql(), "SELECT * FROM users");
    }

    #[test]
    fn test_query_plan_use_cache() {
        let plan = QueryPlan::new("SELECT 1");
        assert!(plan.use_cache());
    }

    #[test]
    fn test_query_pipeline_new() {
        let pipeline = QueryPipeline::new(100);
        let plan = pipeline.parse_sql("SELECT 1").unwrap();
        assert_eq!(plan.sql(), "SELECT 1");
    }

    #[test]
    fn test_query_pipeline_get_metrics() {
        let pipeline = QueryPipeline::new(50);
        let metrics = pipeline.get_metrics();
        assert!(std::sync::Arc::strong_count(&metrics) >= 1);
    }

    #[test]
    fn test_query_pipeline_with_columnar() {
        let pipeline = QueryPipeline::with_columnar(50, true);
        let plan = pipeline.parse_sql("SELECT 1").unwrap();
        assert_eq!(plan.sql(), "SELECT 1");
    }

    #[test]
    fn test_query_pipeline_with_columnar_no_compression() {
        let pipeline = QueryPipeline::with_columnar(50, false);
        let plan = pipeline.parse_sql("SELECT 1").unwrap();
        assert_eq!(plan.sql(), "SELECT 1");
    }

    #[test]
    fn test_parse_sql_valid() {
        let pipeline = QueryPipeline::new(100);
        let plan = pipeline.parse_sql("SELECT 1").unwrap();
        assert_eq!(plan.sql(), "SELECT 1");
    }

    #[test]
    fn test_parse_sql_with_whitespace() {
        let pipeline = QueryPipeline::new(100);
        let plan = pipeline.parse_sql("  SELECT 1  ").unwrap();
        assert_eq!(plan.sql(), "  SELECT 1  ");
    }

    #[test]
    fn test_parse_sql_empty_string() {
        let pipeline = QueryPipeline::new(100);
        let result = pipeline.parse_sql("");
        assert!(result.is_err());
        if let Err(crate::error::OdbcError::ValidationError(msg)) = result {
            assert!(msg.contains("SQL query cannot be empty"));
        } else {
            panic!("Expected ValidationError");
        }
    }

    #[test]
    fn test_parse_sql_whitespace_only() {
        let pipeline = QueryPipeline::new(100);
        let result = pipeline.parse_sql("   ");
        assert!(result.is_err());
        if let Err(crate::error::OdbcError::ValidationError(msg)) = result {
            assert!(msg.contains("SQL query cannot be empty"));
        } else {
            panic!("Expected ValidationError");
        }
    }

    #[test]
    fn test_parse_sql_complex_query() {
        let pipeline = QueryPipeline::new(100);
        let sql = "SELECT u.id, u.name FROM users u WHERE u.active = 1";
        let plan = pipeline.parse_sql(sql).unwrap();
        assert_eq!(plan.sql(), sql);
    }

    #[test]
    fn should_reject_tab_only_sql_when_parsing() {
        let pipeline = QueryPipeline::new(100);
        let err = pipeline
            .parse_sql("\t\n")
            .expect_err("tab/newline-only SQL should be rejected");
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[test]
    fn should_parse_sql_preserving_unicode_identifiers() {
        let pipeline = QueryPipeline::new(100);
        let sql = "SELECT naïve FROM t";
        let plan = pipeline.parse_sql(sql).unwrap();
        assert_eq!(plan.sql(), sql);
    }

    #[test]
    fn shared_row_major_pipeline_returns_same_arc_instance() {
        let a = shared_row_major_pipeline();
        let b = shared_row_major_pipeline();
        assert!(Arc::ptr_eq(&a, &b));
    }

    #[test]
    fn shared_columnar_pipelines_are_distinct_singletons() {
        let row = shared_row_major_pipeline();
        let col = shared_columnar_pipeline();
        let compressed = shared_columnar_compressed_pipeline();
        assert!(!Arc::ptr_eq(&row, &col));
        assert!(!Arc::ptr_eq(&col, &compressed));
        assert!(Arc::ptr_eq(
            &shared_columnar_pipeline(),
            &shared_columnar_pipeline()
        ));
    }

    #[test]
    fn query_plan_debug_includes_sql_fragment() {
        let plan = QueryPlan::new("SELECT 1");
        let debug = format!("{plan:?}");
        assert!(debug.contains("SELECT 1"));
    }
}
