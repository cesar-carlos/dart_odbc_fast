use crate::protocol::ParamValue;

/// INFORMATION_SCHEMA fallback for [`super::list_tables`] when no dialect plugin matches.
pub(crate) fn information_schema_list_tables_query(
    catalog: Option<&str>,
    schema: Option<&str>,
) -> (String, Vec<ParamValue>) {
    let cat = catalog.unwrap_or("").trim();
    let sch = schema.unwrap_or("").trim();

    if cat.is_empty() && sch.is_empty() {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') \
             ORDER BY TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME"
                .to_string(),
            vec![],
        )
    } else if !cat.is_empty() && sch.is_empty() {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') AND TABLE_CATALOG = ? \
             ORDER BY TABLE_SCHEMA, TABLE_NAME"
                .to_string(),
            vec![ParamValue::String(cat.to_string())],
        )
    } else if cat.is_empty() && !sch.is_empty() {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') AND TABLE_SCHEMA = ? \
             ORDER BY TABLE_NAME"
                .to_string(),
            vec![ParamValue::String(sch.to_string())],
        )
    } else {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') \
             AND TABLE_CATALOG = ? AND TABLE_SCHEMA = ? \
             ORDER BY TABLE_NAME"
                .to_string(),
            vec![
                ParamValue::String(cat.to_string()),
                ParamValue::String(sch.to_string()),
            ],
        )
    }
}

/// INFORMATION_SCHEMA fallback for [`super::list_columns`].
pub(crate) fn information_schema_list_columns_query(
    table_name: &str,
    schema: Option<&str>,
) -> (String, Vec<ParamValue>) {
    if let Some(sch) = schema {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, \
             ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE \
             FROM INFORMATION_SCHEMA.COLUMNS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? \
             ORDER BY ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name.to_string()),
            ],
        )
    } else {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, \
             ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE \
             FROM INFORMATION_SCHEMA.COLUMNS \
             WHERE TABLE_NAME = ? \
             ORDER BY TABLE_SCHEMA, ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name.to_string())],
        )
    }
}

/// INFORMATION_SCHEMA SQL for [`super::get_type_info`].
pub(crate) fn information_schema_type_info_sql() -> &'static str {
    "SELECT DISTINCT DATA_TYPE AS type_name \
     FROM INFORMATION_SCHEMA.COLUMNS \
     ORDER BY type_name"
}

/// INFORMATION_SCHEMA fallback for [`super::list_primary_keys`].
pub(crate) fn information_schema_list_primary_keys_query(
    table_name: &str,
    schema: Option<&str>,
) -> (String, Vec<ParamValue>) {
    if let Some(sch) = schema {
        (
            "SELECT \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                kcu.ORDINAL_POSITION, \
                tc.CONSTRAINT_NAME \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' \
                AND tc.TABLE_SCHEMA = ? \
                AND tc.TABLE_NAME = ? \
             ORDER BY kcu.ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name.to_string()),
            ],
        )
    } else {
        (
            "SELECT \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                kcu.ORDINAL_POSITION, \
                tc.CONSTRAINT_NAME \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' \
                AND tc.TABLE_NAME = ? \
             ORDER BY kcu.ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name.to_string())],
        )
    }
}

/// INFORMATION_SCHEMA fallback for [`super::list_foreign_keys`].
pub(crate) fn information_schema_list_foreign_keys_query(
    table_name: &str,
    schema: Option<&str>,
) -> (String, Vec<ParamValue>) {
    if let Some(sch) = schema {
        (
            "SELECT \
                rc.CONSTRAINT_NAME, \
                kcu1.TABLE_NAME AS FROM_TABLE, \
                kcu1.COLUMN_NAME AS FROM_COLUMN, \
                kcu2.TABLE_NAME AS TO_TABLE, \
                kcu2.COLUMN_NAME AS TO_COLUMN, \
                rc.UPDATE_RULE, \
                rc.DELETE_RULE \
             FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu1 \
                ON rc.CONSTRAINT_NAME = kcu1.CONSTRAINT_NAME \
                AND rc.CONSTRAINT_SCHEMA = kcu1.CONSTRAINT_SCHEMA \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu2 \
                ON rc.UNIQUE_CONSTRAINT_NAME = kcu2.CONSTRAINT_NAME \
                AND rc.UNIQUE_CONSTRAINT_SCHEMA = kcu2.CONSTRAINT_SCHEMA \
                AND kcu1.ORDINAL_POSITION = kcu2.ORDINAL_POSITION \
             WHERE kcu1.TABLE_SCHEMA = ? \
                AND kcu1.TABLE_NAME = ? \
             ORDER BY rc.CONSTRAINT_NAME, kcu1.ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name.to_string()),
            ],
        )
    } else {
        (
            "SELECT \
                rc.CONSTRAINT_NAME, \
                kcu1.TABLE_NAME AS FROM_TABLE, \
                kcu1.COLUMN_NAME AS FROM_COLUMN, \
                kcu2.TABLE_NAME AS TO_TABLE, \
                kcu2.COLUMN_NAME AS TO_COLUMN, \
                rc.UPDATE_RULE, \
                rc.DELETE_RULE \
             FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu1 \
                ON rc.CONSTRAINT_NAME = kcu1.CONSTRAINT_NAME \
                AND rc.CONSTRAINT_SCHEMA = kcu1.CONSTRAINT_SCHEMA \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu2 \
                ON rc.UNIQUE_CONSTRAINT_NAME = kcu2.CONSTRAINT_NAME \
                AND rc.UNIQUE_CONSTRAINT_SCHEMA = kcu2.CONSTRAINT_SCHEMA \
                AND kcu1.ORDINAL_POSITION = kcu2.ORDINAL_POSITION \
             WHERE kcu1.TABLE_NAME = ? \
             ORDER BY rc.CONSTRAINT_NAME, kcu1.ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name.to_string())],
        )
    }
}

/// INFORMATION_SCHEMA fallback for [`super::list_indexes`].
pub(crate) fn information_schema_list_indexes_query(
    table_name: &str,
    schema: Option<&str>,
) -> (String, Vec<ParamValue>) {
    if let Some(sch) = schema {
        (
            "SELECT \
                tc.CONSTRAINT_NAME AS INDEX_NAME, \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'UNIQUE' THEN 1 ELSE 0 END AS IS_UNIQUE, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 1 ELSE 0 END AS IS_PRIMARY, \
                kcu.ORDINAL_POSITION \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE (tc.CONSTRAINT_TYPE = 'PRIMARY KEY' OR tc.CONSTRAINT_TYPE = 'UNIQUE') \
                AND tc.TABLE_SCHEMA = ? \
                AND tc.TABLE_NAME = ? \
             ORDER BY tc.CONSTRAINT_NAME, kcu.ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name.to_string()),
            ],
        )
    } else {
        (
            "SELECT \
                tc.CONSTRAINT_NAME AS INDEX_NAME, \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'UNIQUE' THEN 1 ELSE 0 END AS IS_UNIQUE, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 1 ELSE 0 END AS IS_PRIMARY, \
                kcu.ORDINAL_POSITION \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE (tc.CONSTRAINT_TYPE = 'PRIMARY KEY' OR tc.CONSTRAINT_TYPE = 'UNIQUE') \
                AND tc.TABLE_NAME = ? \
             ORDER BY tc.CONSTRAINT_NAME, kcu.ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name.to_string())],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ParamValue;

    fn assert_string_param(value: &ParamValue, expected: &str) {
        match value {
            ParamValue::String(s) => assert_eq!(s, expected),
            other => panic!("expected String param, got {other:?}"),
        }
    }

    #[test]
    fn information_schema_list_tables_query_unfiltered_has_no_params() {
        let (sql, params) = information_schema_list_tables_query(None, None);
        assert!(sql.contains("INFORMATION_SCHEMA.TABLES"));
        assert!(sql.contains("TABLE_TYPE IN ('BASE TABLE','VIEW')"));
        assert!(params.is_empty());
    }

    #[test]
    fn information_schema_list_tables_query_catalog_only() {
        let (sql, params) = information_schema_list_tables_query(Some("mydb"), None);
        assert!(sql.contains("TABLE_CATALOG = ?"));
        assert_eq!(params.len(), 1);
        assert_string_param(&params[0], "mydb");
    }

    #[test]
    fn information_schema_list_tables_query_schema_only() {
        let (sql, params) = information_schema_list_tables_query(None, Some("dbo"));
        assert!(sql.contains("TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 1);
        assert_string_param(&params[0], "dbo");
    }

    #[test]
    fn information_schema_list_tables_query_catalog_and_schema() {
        let (sql, params) = information_schema_list_tables_query(Some("mydb"), Some("dbo"));
        assert!(sql.contains("TABLE_CATALOG = ?"));
        assert!(sql.contains("TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "mydb");
        assert_string_param(&params[1], "dbo");
    }

    #[test]
    fn information_schema_list_tables_query_trims_whitespace_filters() {
        let (sql, params) = information_schema_list_tables_query(Some("  mydb  "), Some("  dbo  "));
        assert!(sql.contains("TABLE_CATALOG = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "mydb");
        assert_string_param(&params[1], "dbo");
    }

    #[test]
    fn information_schema_list_tables_query_empty_strings_are_unfiltered() {
        let (sql, params) = information_schema_list_tables_query(Some(""), Some("   "));
        assert!(!sql.contains("TABLE_CATALOG = ?"));
        assert!(!sql.contains("TABLE_SCHEMA = ?"));
        assert!(params.is_empty());
    }

    #[test]
    fn information_schema_list_columns_query_without_schema() {
        let (sql, params) = information_schema_list_columns_query("users", None);
        assert!(sql.contains("INFORMATION_SCHEMA.COLUMNS"));
        assert!(sql.contains("WHERE TABLE_NAME = ?"));
        assert_eq!(params.len(), 1);
        assert_string_param(&params[0], "users");
    }

    #[test]
    fn information_schema_list_columns_query_with_schema() {
        let (sql, params) = information_schema_list_columns_query("users", Some("dbo"));
        assert!(sql.contains("TABLE_SCHEMA = ?"));
        assert!(sql.contains("TABLE_NAME = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "dbo");
        assert_string_param(&params[1], "users");
    }

    #[test]
    fn information_schema_type_info_sql_selects_distinct_types() {
        let sql = information_schema_type_info_sql();
        assert!(sql.contains("SELECT DISTINCT DATA_TYPE"));
        assert!(sql.contains("ORDER BY type_name"));
    }

    #[test]
    fn information_schema_list_primary_keys_query_without_schema() {
        let (sql, params) = information_schema_list_primary_keys_query("orders", None);
        assert!(sql.contains("CONSTRAINT_TYPE = 'PRIMARY KEY'"));
        assert!(sql.contains("tc.TABLE_NAME = ?"));
        assert_eq!(params.len(), 1);
        assert_string_param(&params[0], "orders");
    }

    #[test]
    fn information_schema_list_primary_keys_query_with_schema() {
        let (sql, params) = information_schema_list_primary_keys_query("orders", Some("sales"));
        assert!(sql.contains("tc.TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[1], "orders");
    }

    #[test]
    fn information_schema_list_foreign_keys_query_without_schema() {
        let (sql, params) = information_schema_list_foreign_keys_query("child", None);
        assert!(sql.contains("REFERENTIAL_CONSTRAINTS"));
        assert!(sql.contains("WHERE kcu1.TABLE_NAME = ?"));
        assert_eq!(params.len(), 1);
        assert_string_param(&params[0], "child");
    }

    #[test]
    fn information_schema_list_foreign_keys_query_with_schema() {
        let (sql, params) = information_schema_list_foreign_keys_query("child", Some("dbo"));
        assert!(sql.contains("kcu1.TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "dbo");
    }

    #[test]
    fn information_schema_list_indexes_query_without_schema() {
        let (sql, params) = information_schema_list_indexes_query("items", None);
        assert!(sql.contains("CONSTRAINT_TYPE = 'PRIMARY KEY' OR tc.CONSTRAINT_TYPE = 'UNIQUE'"));
        assert_eq!(params.len(), 1);
        assert_string_param(&params[0], "items");
    }

    #[test]
    fn information_schema_list_indexes_query_with_schema() {
        let (sql, params) = information_schema_list_indexes_query("items", Some("inv"));
        assert!(sql.contains("tc.TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[1], "items");
    }

    #[test]
    fn information_schema_list_columns_query_with_empty_schema_uses_schema_branch() {
        let (sql, params) = information_schema_list_columns_query("users", Some(""));
        assert!(sql.contains("TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "");
        assert_string_param(&params[1], "users");
    }

    #[test]
    fn information_schema_list_foreign_keys_query_binds_schema_when_provided() {
        let (sql, params) = information_schema_list_foreign_keys_query("child", Some("dbo"));
        assert!(sql.contains("kcu1.TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "dbo");
        assert_string_param(&params[1], "child");
    }

    #[test]
    fn information_schema_list_primary_keys_query_empty_schema_still_binds() {
        let (sql, params) = information_schema_list_primary_keys_query("t", Some(""));
        assert!(sql.contains("TABLE_SCHEMA = ?"));
        assert_eq!(params.len(), 2);
        assert_string_param(&params[0], "");
    }
}
