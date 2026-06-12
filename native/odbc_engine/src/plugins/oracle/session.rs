use super::OraclePlugin;
use crate::engine::identifier::quote_identifier_default;

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for OraclePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'".to_string(),
            "ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS.FF'".to_string(),
            "ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,'".to_string(),
        ];
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!(
                "ALTER SESSION SET TIME_ZONE='{}'",
                tz.replace('\'', "''")
            ));
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier_default(schema) {
                out.push(format!("ALTER SESSION SET CURRENT_SCHEMA = {q}"));
            }
        }
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
