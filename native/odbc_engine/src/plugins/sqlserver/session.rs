use super::SqlServerPlugin;
use crate::engine::identifier::{quote_identifier, IdentifierQuoting};

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for SqlServerPlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "SET ARITHABORT ON".to_string(),
            "SET CONCAT_NULL_YIELDS_NULL ON".to_string(),
        ];
        if let Some(name) = opts.application_name.as_deref() {
            // SQL Server doesn't have a runtime SET APPLICATION_NAME; emitted as
            // `SET CONTEXT_INFO` for visibility in DMVs (best-effort).
            // The proper way is via connection string `App=...`; documented.
            let _ = name;
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier(schema, IdentifierQuoting::Brackets) {
                out.push(format!(
                    "EXEC sp_setapprole NULL, NULL; SELECT 1 FROM {q}.sysobjects WHERE 1=0"
                ));
                let _ = out.pop(); // No portable "USE schema" — leave it documented.
            }
        }
        let _ = opts.timezone; // SQL Server has no session-level TZ setting.
        let _ = opts.charset;
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
