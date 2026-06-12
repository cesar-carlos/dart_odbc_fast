use super::Db2Plugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

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
