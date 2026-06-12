use super::Db2Plugin;
use crate::engine::identifier::quote_identifier_default;

use super::super::capabilities::{SessionInitializer, SessionOptions};

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
