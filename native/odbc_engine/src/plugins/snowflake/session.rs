use super::SnowflakePlugin;
use crate::engine::identifier::quote_identifier_default;

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for SnowflakePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!(
                "ALTER SESSION SET TIMEZONE = '{}'",
                tz.replace('\'', "''")
            ));
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier_default(schema) {
                out.push(format!("USE SCHEMA {q}"));
            }
        }
        if let Some(name) = opts.application_name.as_deref() {
            out.push(format!(
                "ALTER SESSION SET QUERY_TAG = '{}'",
                name.replace('\'', "''")
            ));
        }
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
