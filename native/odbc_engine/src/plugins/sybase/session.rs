use super::SybasePlugin;

use super::super::capabilities::{SessionInitializer, SessionOptions};

impl SessionInitializer for SybasePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "SET QUOTED_IDENTIFIER ON".to_string(),
            "SET CHAINED OFF".to_string(),
        ];
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}
