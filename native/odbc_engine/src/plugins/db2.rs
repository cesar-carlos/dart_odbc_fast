//! IBM Db2 plugin (NEW in v3.0).
//!
//! - `FETCH FIRST n ROWS ONLY` (Db2 syntax).
//! - `MERGE INTO` for UPSERT.
//! - `SELECT ... FROM FINAL TABLE (INSERT ...)` for RETURNING-equivalent.

use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::DmlVerb;
use super::capabilities::upsert::{effective_update_columns, validate_upsert_inputs, Upsertable};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::identifier::{quote_identifier_default, quote_qualified_default};
use crate::error::{OdbcError, Result};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

pub struct Db2Plugin;

impl Default for Db2Plugin {
    fn default() -> Self {
        Self::new()
    }
}

impl Db2Plugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for Db2Plugin {
    fn name(&self) -> &str {
        "db2"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 2000,
            driver_name: "IBM Db2".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        OdbcType::from_odbc_sql_type(odbc_type)
    }

    fn optimize_query(&self, sql: &str) -> String {
        let mut optimized = sql.to_string();
        if optimized.contains("SELECT") && !optimized.to_uppercase().contains("FETCH FIRST") {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " FETCH FIRST 1000 ROWS ONLY");
            } else if !optimized.to_uppercase().contains(" WHERE")
                && !optimized.to_uppercase().contains(" ORDER BY")
            {
                optimized.push_str(" FETCH FIRST 1000 ROWS ONLY");
            }
        }
        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 2000 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl Upsertable for Db2Plugin {
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        validate_upsert_inputs(table, columns, conflict_columns, update_columns)?;
        let qtable = quote_qualified_default(table)?;

        // Db2 MERGE: USING (VALUES (?, ?)) AS s(a, b) ON ...
        let placeholders = std::iter::repeat_n("?", columns.len())
            .collect::<Vec<_>>()
            .join(", ");
        let alias_cols = columns
            .iter()
            .map(|c| quote_identifier_default(c))
            .collect::<Result<Vec<_>>>()?
            .join(", ");
        let on_clause = conflict_columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier_default(c)?;
                Ok(format!("t.{q} = s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(" AND ");

        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let when_matched = if updates.is_empty() {
            String::new()
        } else {
            let set = updates
                .iter()
                .map(|c| -> Result<String> {
                    let q = quote_identifier_default(c)?;
                    Ok(format!("{q} = s.{q}"))
                })
                .collect::<Result<Vec<_>>>()?
                .join(", ");
            format!(" WHEN MATCHED THEN UPDATE SET {set}")
        };

        let insert_cols = alias_cols.clone();
        let insert_vals = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier_default(c)?;
                Ok(format!("s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        Ok(format!(
            "MERGE INTO {qtable} t \
             USING (VALUES ({placeholders})) AS s({alias_cols}) \
             ON {on_clause}\
             {when_matched} \
             WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals})"
        ))
    }
}

impl Returnable for Db2Plugin {
    fn supports_returning(&self) -> bool {
        true
    }

    /// Db2 uses `SELECT ... FROM FINAL TABLE (INSERT ...)` instead of RETURNING.
    fn append_returning_clause(
        &self,
        sql: &str,
        verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        if !matches!(verb, DmlVerb::Insert | DmlVerb::Update) {
            return Err(OdbcError::UnsupportedFeature(
                "Db2 FROM FINAL TABLE works for INSERT and UPDATE only".to_string(),
            ));
        }
        let proj = columns
            .iter()
            .map(|c| quote_identifier_default(c))
            .collect::<Result<Vec<_>>>()?
            .join(", ");
        let trimmed = sql.trim_end_matches(';');
        Ok(format!("SELECT {proj} FROM FINAL TABLE ({trimmed})"))
    }
}

impl IdentifierQuoter for Db2Plugin {}

impl TypeCatalog for Db2Plugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "graphic" | "vargraphic" | "long vargraphic" => return OdbcType::NVarchar,
                "clob" | "dbclob" => return OdbcType::Varchar,
                "blob" => return OdbcType::Binary,
                "xml" => return OdbcType::Json,
                "real" => return OdbcType::Float,
                "double" | "double precision" => return OdbcType::Double,
                "smallint" => return OdbcType::SmallInt,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

impl CatalogProvider for Db2Plugin {
    fn list_tables_sql(
        &self,
        _catalog: Option<&str>,
        schema: Option<&str>,
    ) -> Result<CatalogQuery> {
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT NULL AS TABLE_CATALOG, TABSCHEMA AS TABLE_SCHEMA, \
                        TABNAME AS TABLE_NAME, \
                        CASE TYPE WHEN 'T' THEN 'BASE TABLE' WHEN 'V' THEN 'VIEW' \
                                  ELSE 'OTHER' END AS TABLE_TYPE \
                 FROM SYSCAT.TABLES WHERE TABSCHEMA = UPPER(?) ORDER BY TABNAME",
                vec![ParamValue::String(s.trim().to_string())],
            )),
            _ => Ok(CatalogQuery::no_params(
                "SELECT NULL AS TABLE_CATALOG, TABSCHEMA AS TABLE_SCHEMA, \
                        TABNAME AS TABLE_NAME, \
                        CASE TYPE WHEN 'T' THEN 'BASE TABLE' WHEN 'V' THEN 'VIEW' \
                                  ELSE 'OTHER' END AS TABLE_TYPE \
                 FROM SYSCAT.TABLES WHERE TABSCHEMA NOT LIKE 'SYS%' \
                 ORDER BY TABSCHEMA, TABNAME",
            )),
        }
    }

    fn list_columns_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT NULL AS TABLE_CATALOG, TABSCHEMA AS TABLE_SCHEMA, TABNAME AS TABLE_NAME, \
                        COLNAME AS COLUMN_NAME, COLNO + 1 AS ORDINAL_POSITION, \
                        TYPENAME AS DATA_TYPE, NULLS AS IS_NULLABLE, DEFAULT AS COLUMN_DEFAULT \
                 FROM SYSCAT.COLUMNS \
                 WHERE TABNAME = UPPER(?) AND TABSCHEMA = UPPER(?) \
                 ORDER BY COLNO",
                vec![
                    ParamValue::String(table),
                    ParamValue::String(s.trim().to_string()),
                ],
            )),
            _ => Ok(CatalogQuery::new(
                "SELECT NULL AS TABLE_CATALOG, TABSCHEMA AS TABLE_SCHEMA, TABNAME AS TABLE_NAME, \
                        COLNAME AS COLUMN_NAME, COLNO + 1 AS ORDINAL_POSITION, \
                        TYPENAME AS DATA_TYPE, NULLS AS IS_NULLABLE, DEFAULT AS COLUMN_DEFAULT \
                 FROM SYSCAT.COLUMNS WHERE TABNAME = UPPER(?) ORDER BY COLNO",
                vec![ParamValue::String(table)],
            )),
        }
    }

    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT TABSCHEMA AS TABLE_SCHEMA, TABNAME AS TABLE_NAME, COLNAME AS COLUMN_NAME, \
                    COLSEQ AS POSITION \
             FROM SYSCAT.KEYCOLUSE WHERE CONSTNAME IN (\
                SELECT CONSTNAME FROM SYSCAT.TABCONST WHERE TYPE='P' AND TABNAME=UPPER(?)\
             ) ORDER BY COLSEQ",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT r.TABSCHEMA AS TABLE_SCHEMA, r.TABNAME AS TABLE_NAME, k.COLNAME AS COLUMN_NAME, \
                    r.REFTABSCHEMA AS REFERENCED_SCHEMA, r.REFTABNAME AS REFERENCED_TABLE, \
                    pk.COLNAME AS REFERENCED_COLUMN, k.COLSEQ AS POSITION \
             FROM SYSCAT.REFERENCES r \
             JOIN SYSCAT.KEYCOLUSE k ON r.CONSTNAME = k.CONSTNAME AND r.TABNAME = k.TABNAME \
             JOIN SYSCAT.KEYCOLUSE pk ON r.REFKEYNAME = pk.CONSTNAME AND k.COLSEQ = pk.COLSEQ \
             WHERE r.TABNAME = UPPER(?) ORDER BY k.COLSEQ",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT i.TABSCHEMA AS TABLE_SCHEMA, i.TABNAME AS TABLE_NAME, i.INDNAME AS INDEX_NAME, \
                    c.COLNAME AS COLUMN_NAME, c.COLSEQ AS COLUMN_POSITION, \
                    CASE i.UNIQUERULE WHEN 'U' THEN 'UNIQUE' ELSE 'NON-UNIQUE' END AS DESCEND \
             FROM SYSCAT.INDEXES i \
             JOIN SYSCAT.INDEXCOLUSE c ON i.INDNAME = c.INDNAME \
             WHERE i.TABNAME = UPPER(?) ORDER BY i.INDNAME, c.COLSEQ",
            vec![ParamValue::String(table.to_string())],
        ))
    }
}

impl SessionInitializer for Db2Plugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier_default(schema) {
                out.push(format!("SET CURRENT SCHEMA = {q}"));
            }
        }
        if let Some(name) = opts.application_name.as_deref() {
            out.push(format!(
                "CALL SYSPROC.WLM_SET_CLIENT_INFO('{}', NULL, NULL, NULL, NULL)",
                name.replace('\'', "''")
            ));
        }
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_is_db2() {
        assert_eq!(Db2Plugin::new().name(), "db2");
    }

    #[test]
    fn optimize_query_adds_fetch_first() {
        let p = Db2Plugin::new();
        assert_eq!(
            p.optimize_query("SELECT * FROM t"),
            "SELECT * FROM t FETCH FIRST 1000 ROWS ONLY"
        );
    }

    #[test]
    fn optimize_query_skips_when_already_present() {
        let p = Db2Plugin::new();
        let s = "SELECT * FROM t FETCH FIRST 50 ROWS ONLY";
        assert_eq!(p.optimize_query(s), s);
    }

    #[test]
    fn upsert_uses_merge_with_values_alias() {
        let p = Db2Plugin::new();
        let sql = p
            .build_upsert_sql("u", &["id", "name"], &["id"], None)
            .unwrap();
        assert!(sql.starts_with("MERGE INTO \"u\" t"));
        assert!(sql.contains("USING (VALUES (?, ?))"));
        assert!(sql.contains("WHEN MATCHED THEN UPDATE SET"));
        assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
    }

    #[test]
    fn returning_uses_final_table() {
        let p = Db2Plugin::new();
        let r = p
            .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
            .unwrap();
        assert_eq!(
            r,
            "SELECT \"id\" FROM FINAL TABLE (INSERT INTO t (a) VALUES (?))"
        );
    }

    #[test]
    fn returning_for_delete_is_unsupported() {
        let p = Db2Plugin::new();
        let r = p.append_returning_clause("DELETE FROM t WHERE id=?", DmlVerb::Delete, &["id"]);
        assert!(matches!(r, Err(OdbcError::UnsupportedFeature(_))));
    }

    #[test]
    fn type_catalog_recognises_db2_specific_types() {
        let p = Db2Plugin::new();
        assert_eq!(p.map_type_extended(1, Some("GRAPHIC")), OdbcType::NVarchar);
        assert_eq!(p.map_type_extended(1, Some("XML")), OdbcType::Json);
        assert_eq!(p.map_type_extended(1, Some("BLOB")), OdbcType::Binary);
    }

    #[test]
    fn session_init_emits_set_current_schema() {
        let p = Db2Plugin::new();
        let opts = SessionOptions::new().with_schema("MYAPP");
        let stmts = p.initialization_sql(&opts);
        assert!(stmts.iter().any(|s| s.contains("SET CURRENT SCHEMA")));
    }
}
