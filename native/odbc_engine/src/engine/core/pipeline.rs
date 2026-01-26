use super::execution_engine::ExecutionEngine;
use crate::error::{OdbcError, Result};
use crate::protocol::ParamValue;
use odbc_api::Connection;
use std::sync::Arc;

pub struct QueryPlan {
    sql: String,
    use_cache: bool,
}

impl QueryPlan {
    pub fn new(sql: String) -> Self {
        Self {
            sql,
            use_cache: true,
        }
    }

    pub fn sql(&self) -> &str {
        &self.sql
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

    pub fn parse_sql(&self, sql: &str) -> Result<QueryPlan> {
        if sql.trim().is_empty() {
            return Err(OdbcError::ValidationError(
                "SQL query cannot be empty".to_string(),
            ));
        }
        Ok(QueryPlan::new(sql.to_string()))
    }

    pub fn execute(&self, conn: &Connection<'static>, plan: QueryPlan) -> Result<Vec<u8>> {
        self.execution_engine.execute_query(conn, plan.sql())
    }

    pub fn execute_direct(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        let plan = self.parse_sql(sql)?;
        self.execute(conn, plan)
    }

    pub fn execute_with_params(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        self.parse_sql(sql)?;
        self.execution_engine
            .execute_query_with_params(conn, sql, params)
    }

    pub fn execute_with_params_and_timeout(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        params: &[ParamValue],
        timeout_sec: Option<usize>,
    ) -> Result<Vec<u8>> {
        self.parse_sql(sql)?;
        self.execution_engine
            .execute_query_with_params_and_timeout(conn, sql, params, timeout_sec)
    }

    pub fn execute_multi(&self, conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        self.parse_sql(sql)?;
        self.execution_engine.execute_multi_result(conn, sql)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_plan_new() {
        let plan = QueryPlan::new("SELECT 1".to_string());
        assert_eq!(plan.sql(), "SELECT 1");
        assert!(plan.use_cache());
    }

    #[test]
    fn test_query_plan_sql() {
        let plan = QueryPlan::new("SELECT * FROM users".to_string());
        assert_eq!(plan.sql(), "SELECT * FROM users");
    }

    #[test]
    fn test_query_plan_use_cache() {
        let plan = QueryPlan::new("SELECT 1".to_string());
        assert!(plan.use_cache());
    }

    #[test]
    fn test_query_pipeline_new() {
        let pipeline = QueryPipeline::new(100);
        let plan = pipeline.parse_sql("SELECT 1").unwrap();
        assert_eq!(plan.sql(), "SELECT 1");
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
}
