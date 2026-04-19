//! Driver-specific extended type mapping.
//!
//! The default `DriverPlugin::map_type(i16)` only sees the ODBC standard SQL
//! type code — it cannot tell `JSON` from `VARCHAR` or `UUID` from `BINARY`
//! because the Driver Manager often reports them as their wider parent type.
//! `TypeCatalog::map_type_extended(sql_type, type_name)` accepts the
//! driver-reported `TYPE_NAME` (from `SQLDescribeCol`/`SQLColAttribute`) so
//! the plugin can refine the mapping.

use crate::protocol::types::OdbcType;

/// Capability trait for engines that expose extended type metadata.
pub trait TypeCatalog: Send + Sync {
    /// Map an ODBC SQL type **plus** the driver-reported `TYPE_NAME` (when
    /// available) to the richer [`OdbcType`] family.
    ///
    /// The default fallback uses [`OdbcType::from_odbc_sql_type`] (ignores
    /// `type_name`). Override per-driver to recognise driver-specific
    /// variants (`uuid`, `jsonb`, `nvarchar`, `timestamptz`, ...).
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        let _ = type_name;
        OdbcType::from_odbc_sql_type(sql_type)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Default;
    impl TypeCatalog for Default {}

    #[test]
    fn default_falls_back_to_standard_mapping() {
        let d = Default;
        assert_eq!(d.map_type_extended(1, None), OdbcType::Varchar);
        assert_eq!(d.map_type_extended(4, Some("integer")), OdbcType::Integer);
        assert_eq!(d.map_type_extended(-5, None), OdbcType::BigInt);
    }
}
