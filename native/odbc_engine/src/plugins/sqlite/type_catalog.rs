use super::SqlitePlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for SqlitePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            // SQLite's "type affinity" — five storage classes derive from
            // declared types.
            let lower = name.trim().to_ascii_lowercase();
            if lower.contains("int") {
                return OdbcType::Integer;
            }
            if lower.contains("char") || lower.contains("text") || lower.contains("clob") {
                return OdbcType::Varchar;
            }
            if lower.contains("blob") {
                return OdbcType::Binary;
            }
            if lower.contains("real") || lower.contains("floa") || lower.contains("doub") {
                return OdbcType::Double;
            }
            if lower == "boolean" || lower == "bool" {
                return OdbcType::Boolean;
            }
            // Numeric / decimal affinity defaults to Decimal.
            return OdbcType::Decimal;
        }
        self.map_type(sql_type)
    }
}
