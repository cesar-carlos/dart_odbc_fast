use super::SqlitePlugin;

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for SqlitePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "PRAGMA foreign_keys = ON".to_string(),
            "PRAGMA journal_mode = WAL".to_string(),
            "PRAGMA synchronous = NORMAL".to_string(),
        ];
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
