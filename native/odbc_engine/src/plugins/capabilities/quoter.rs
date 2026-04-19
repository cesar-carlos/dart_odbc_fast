//! Driver-specific identifier quoting.

use crate::engine::identifier::{quote_identifier, IdentifierQuoting};
use crate::error::Result;

/// Capability trait for engines with a non-default quoting style.
///
/// Default style is `DoubleQuote` (SQL-92 / ANSI). Override for SQL Server
/// (`Brackets`), MySQL/MariaDB (`Backtick`).
pub trait IdentifierQuoter: Send + Sync {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::DoubleQuote
    }

    /// Quote a single identifier in the engine's preferred style.
    /// Validation rules from `engine::identifier::validate_identifier` apply.
    fn quote(&self, identifier: &str) -> Result<String> {
        quote_identifier(identifier, self.quoting_style())
    }

    /// True when the identifier MUST be quoted on the wire because the engine
    /// would otherwise lower-case (PG, SQLite) or upper-case (Oracle) it.
    /// Default impl: always quote (safe).
    fn needs_quoting(&self, identifier: &str) -> bool {
        let _ = identifier;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Default;
    impl IdentifierQuoter for Default {}

    struct Bracketed;
    impl IdentifierQuoter for Bracketed {
        fn quoting_style(&self) -> IdentifierQuoting {
            IdentifierQuoting::Brackets
        }
    }

    #[test]
    fn default_uses_double_quote() {
        assert_eq!(Default.quote("table").unwrap(), "\"table\"");
    }

    #[test]
    fn bracketed_uses_brackets() {
        assert_eq!(Bracketed.quote("table").unwrap(), "[table]");
    }

    #[test]
    fn quoter_rejects_invalid_identifier() {
        assert!(Default.quote("table; DROP").is_err());
    }
}
