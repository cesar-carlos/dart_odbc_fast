use super::PostgresPlugin;
use crate::engine::identifier::quote_identifier_default;

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for PostgresPlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(name) = opts.application_name.as_deref() {
            // PG accepts SET application_name with single-quoted literals.
            out.push(format!(
                "SET application_name = '{}'",
                name.replace('\'', "''")
            ));
        }
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!("SET TIME ZONE '{}'", tz.replace('\'', "''")));
        }
        if let Some(schema) = opts.schema.as_deref() {
            // Validate schema as identifier; quote with double quotes.
            if let Ok(quoted) = quote_identifier_default(schema) {
                out.push(format!("SET search_path TO {quoted}"));
            }
        }
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
