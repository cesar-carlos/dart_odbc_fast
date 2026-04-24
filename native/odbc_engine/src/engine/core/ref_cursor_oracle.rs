//! Oracle `SYS_REFCURSOR` / directed `ParamValue::RefCursorOut` (OR-only).
//!
//! The Oracle Database ODBC driver does not bind `OUT SYS_REFCURSOR` the way SQL
//! Server binds output parameters. Instead, *reference-cursor* parameters are
//! **omitted** from the `{ CALL ... ( ... ) }` text, and result sets are read
//! from the same statement using `SQLMoreResults` in cursor order. See
//! *Oracle Database ODBC — Enabling Result Sets* (local note:
//! `doc/notes/REF_CURSOR_ORACLE_ROADMAP.md`).

use crate::error::{OdbcError, Result};
use crate::protocol::bound_param::{BoundParam, ParamDirection};
use crate::protocol::param_value::ParamValue;

const ERR_PREFIX: &str = "DIRECTED_PARAM|";

fn validation_directed(msg: impl Into<String>) -> OdbcError {
    OdbcError::ValidationError(format!("{ERR_PREFIX}{}", msg.into()))
}

/// True when the bound list uses an Oracle `SYS_REFCURSOR` marker.
pub(crate) fn bound_has_ref_cursor(bound: &[BoundParam]) -> bool {
    bound
        .iter()
        .any(|b| matches!(b.value, ParamValue::RefCursorOut))
}

/// `?` that are not [ParamValue::RefCursorOut] (same order as remaining placeholders).
pub(crate) fn filter_non_ref_cursor_params(bound: &[BoundParam]) -> Vec<BoundParam> {
    bound
        .iter()
        .filter(|b| !matches!(b.value, ParamValue::RefCursorOut))
        .cloned()
        .collect()
}

/// Number of `?` characters in `sql` (ODBC placeholder scan — does not ignore string literals).
pub(crate) fn count_placeholders(sql: &str) -> usize {
    sql.chars().filter(|&c| c == '?').count()
}

/// Remove `?` for each [ParamValue::RefCursorOut] in lock-step with the `?` stream.
///
/// [count_placeholders] and `bound.len()` must match. Uses a scan over `?` so
/// commas between removed placeholders are not left behind.
pub(crate) fn strip_ref_cursor_placeholders(sql: &str, bound: &[BoundParam]) -> Result<String> {
    let nq = count_placeholders(sql);
    if nq != bound.len() {
        return Err(validation_directed(format!(
            "ref_cursor_oracle_sql_param_count: SQL has {nq} '?' but bound list has {} params",
            bound.len()
        )));
    }
    let mut out = String::with_capacity(sql.len());
    let mut rest = sql;
    for (i, bp) in bound.iter().enumerate() {
        let Some(pos) = rest.find('?') else {
            return Err(validation_directed(format!(
                "ref_cursor_oracle_internal: missing '?' for bound parameter {i}"
            )));
        };
        if pos > 0
            && matches!(&bp.value, ParamValue::RefCursorOut)
            && rest.as_bytes().get(pos - 1) == Some(&b',')
        {
            // Drop the list separator in front of a removed `?` (e.g. `,?)`
            // in `{call p(?,? , ?)}` when the last `?` is a ref-cursor).
            out.push_str(&rest[..pos - 1]);
        } else {
            out.push_str(&rest[..pos]);
        }
        if matches!(
            (bp.direction, &bp.value),
            (ParamDirection::Input, ParamValue::RefCursorOut)
        ) {
            return Err(validation_directed(
                "ref_cursor_out_invalid_direction: ParamValue::RefCursorOut is only \
                 valid for ParamDirection::output (or in/out on Oracle)",
            ));
        }
        if !matches!(&bp.value, ParamValue::RefCursorOut) {
            out.push('?');
        }
        rest = &rest[pos + 1..];
        // A skipped ref-cursor placeholder often left a comma as the first
        // character in `rest` (e.g. `?,?,?)` after the first `?`). Remove it
        // so we do not emit `p(,? ,)`.
        if matches!(&bp.value, ParamValue::RefCursorOut) && rest.starts_with(',') {
            rest = &rest[1..];
        }
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::bound_param::ParamDirection;
    use crate::protocol::param_value::ParamValue;

    fn bp(dir: ParamDirection, v: ParamValue) -> BoundParam {
        BoundParam {
            direction: dir,
            value: v,
        }
    }

    #[test]
    fn strip_keeps_only_scalar_placeholders() {
        let sql = "call p(?,?,?)";
        let b = [
            bp(ParamDirection::Output, ParamValue::RefCursorOut),
            bp(ParamDirection::Input, ParamValue::Integer(0)),
            bp(ParamDirection::Output, ParamValue::RefCursorOut),
        ];
        assert_eq!(
            strip_ref_cursor_placeholders(sql, &b).expect("strip"),
            "call p(?)".to_string()
        );
    }

    #[test]
    fn count_mismatch_errors() {
        let sql = "select ?";
        let b = [
            bp(ParamDirection::Input, ParamValue::Integer(1)),
            bp(ParamDirection::Input, ParamValue::Integer(2)),
        ];
        assert!(strip_ref_cursor_placeholders(sql, &b).is_err());
    }
}
