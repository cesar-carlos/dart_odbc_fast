use crate::engine::identifier::validate_identifier;
use crate::error::{OdbcError, Result};

/// Parses `schema.table` or bare `table` for catalog ODBC calls.
///
/// Structural validation only (non-empty segments after trim). Catalog SQL
/// binds the returned strings as parameters; callers must not interpolate
/// untrusted values into identifier positions.
pub fn parse_catalog_table_ref(table: &str) -> Result<(Option<String>, String)> {
    validate_and_parse_table(table)
}

pub(crate) fn validate_and_parse_table(table: &str) -> Result<(Option<String>, String)> {
    let table = table.trim();
    if table.is_empty() {
        return Err(OdbcError::ValidationError(
            "Table name cannot be empty".to_string(),
        ));
    }
    let (schema, table_name) = if let Some(dot) = table.rfind('.') {
        let s = table[..dot].trim().to_string();
        let t = table[dot + 1..].trim();
        if t.is_empty() {
            return Err(OdbcError::ValidationError(
                "Invalid table name (empty after schema)".to_string(),
            ));
        }
        (Some(s), t.to_string())
    } else {
        (None, table.to_string())
    };
    validate_table_identifiers(schema.as_deref(), &table_name)?;
    Ok((schema, table_name))
}

fn validate_table_identifiers(schema: Option<&str>, table_name: &str) -> Result<()> {
    validate_identifier(table_name)?;
    if let Some(s) = schema {
        for segment in s.split('.') {
            let segment = segment.trim();
            if segment.is_empty() {
                return Err(OdbcError::ValidationError(
                    "Invalid schema (empty segment)".to_string(),
                ));
            }
            validate_identifier(segment)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::OdbcError;

    #[test]
    fn test_validate_and_parse_table_empty() {
        let r = validate_and_parse_table("");
        assert!(r.is_err());
        let r = validate_and_parse_table("   ");
        assert!(r.is_err());
    }

    #[test]
    fn test_validate_and_parse_table_name_only() {
        let (schema, name) = validate_and_parse_table("mytable").unwrap();
        assert!(schema.is_none());
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_schema_dot_table() {
        let (schema, name) = validate_and_parse_table("dbo.mytable").unwrap();
        assert_eq!(schema.as_deref(), Some("dbo"));
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_empty_after_dot() {
        let r = validate_and_parse_table("dbo.");
        assert!(r.is_err());
    }

    #[test]
    fn test_validate_and_parse_table_trimmed_schema_and_table() {
        let (schema, name) = validate_and_parse_table("  dbo  .  mytable  ").unwrap();
        assert_eq!(schema.as_deref(), Some("dbo"));
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_multiple_dots_uses_last_as_separator() {
        let (schema, name) = validate_and_parse_table("cat.schema.mytable").unwrap();
        assert_eq!(schema.as_deref(), Some("cat.schema"));
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_single_char_table() {
        let (schema, name) = validate_and_parse_table("x").unwrap();
        assert!(schema.is_none());
        assert_eq!(name, "x");
    }

    #[test]
    fn validate_and_parse_table_preserves_ascii_table_name_bytes() {
        let (schema, name) = validate_and_parse_table("dbo.Users_Table1").unwrap();
        assert_eq!(schema.as_deref(), Some("dbo"));
        assert_eq!(name, "Users_Table1");
    }

    #[test]
    fn should_reject_validate_and_parse_table_when_name_is_only_whitespace() {
        let err = validate_and_parse_table("   ").unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[test]
    fn should_reject_validate_and_parse_table_when_segment_after_dot_is_blank() {
        let err = validate_and_parse_table("dbo.   ").unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[test]
    fn should_reject_validate_and_parse_table_when_table_has_sql_injection_chars() {
        let err = validate_and_parse_table("dbo;drop--").unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[test]
    fn should_reject_validate_and_parse_table_when_schema_segment_is_invalid() {
        let err = validate_and_parse_table("bad-name.mytable").unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[test]
    fn should_validate_each_schema_segment_when_qualified_name_has_multiple_dots() {
        let (schema, name) = validate_and_parse_table("cat.schema.mytable").unwrap();
        assert_eq!(schema.as_deref(), Some("cat.schema"));
        assert_eq!(name, "mytable");
    }

    #[test]
    fn should_reject_validate_and_parse_table_when_any_schema_segment_is_invalid() {
        let err = validate_and_parse_table("good.bad-name.mytable").unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }
}
