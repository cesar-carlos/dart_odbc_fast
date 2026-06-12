use super::MariaDbPlugin;
use crate::engine::identifier::{quote_identifier, IdentifierQuoting};

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for MariaDbPlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = Vec::new();
        let charset = opts.charset.as_deref().unwrap_or("utf8mb4");
        out.push(format!("SET NAMES {}", charset.replace('\'', "")));
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!("SET time_zone = '{}'", tz.replace('\'', "''")));
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier(schema, IdentifierQuoting::Backtick) {
                out.push(format!("USE {q}"));
            }
        }
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
